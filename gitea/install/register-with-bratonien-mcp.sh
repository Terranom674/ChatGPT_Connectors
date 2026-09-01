#!/usr/bin/env bash
set -Eeuo pipefail

SELF_URL="https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/gitea/install/register-with-bratonien-mcp.sh"
HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/gitea"
APP_DIR="$CONNECTOR_ROOT/plugins/gitea-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-gitea-connector"
TTY=/dev/tty

fail() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo "$*" >&2; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

normalize_url() {
  local value="${1%/}"
  [[ "$value" =~ ^https?:// ]] || value="https://$value"
  [[ "$value" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]] || return 1
  printf '%s' "$value"
}

prompt_ctid() {
  local label="$1" ctid status
  while true; do
    printf '%s' "$label" > "$TTY"
    read -r ctid < "$TTY"
    [[ "$ctid" =~ ^[0-9]+$ ]] || { note "Bitte eine gültige numerische CT-ID eingeben."; continue; }
    status="$(pct status "$ctid" 2>/dev/null || true)"
    [[ "$status" == "status: running" ]] || { note "CT $ctid existiert nicht oder läuft nicht."; continue; }
    printf '%s' "$ctid"
    return 0
  done
}

prompt_mcp_lxc() {
  local ctid
  while true; do
    ctid="$(prompt_ctid 'CT-ID des bestehenden MCP-LXC: ')"
    pct exec "$ctid" -- test -r "$HOST_CONFIG" >/dev/null 2>&1 || { note "CT $ctid enthält keine Bratonien-MCP-Konfiguration."; continue; }
    pct exec "$ctid" -- test -r "$HOST_ENV" >/dev/null 2>&1 || { note "CT $ctid enthält keine Bratonien-MCP-Umgebung."; continue; }
    pct exec "$ctid" -- sh -lc 'command -v docker >/dev/null 2>&1' >/dev/null 2>&1 || { note "In CT $ctid ist Docker nicht verfügbar."; continue; }
    printf '%s' "$ctid"
    return 0
  done
}

prompt_gitea() {
  local value
  while true; do
    printf 'Gitea-Basis-URL (z. B. https://git.example.com): ' > "$TTY"
    read -r value < "$TTY"
    GITEA_URL="$(normalize_url "$value")" || { note "Bitte eine gültige Gitea-URL eingeben."; continue; }
    break
  done
  while true; do
    printf 'Gitea-Zugriffstoken: ' > "$TTY"
    read -r -s GITEA_TOKEN < "$TTY"; echo > "$TTY"
    [[ -n "$GITEA_TOKEN" ]] && break
    note "Gitea-Zugriffstoken darf nicht leer sein."
  done
}

preflight_gitea() {
  local out status
  out="$(mktemp)"
  status="$(curl -sS --max-time 20 -o "$out" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H "Authorization: token $GITEA_TOKEN" \
    "$GITEA_URL/api/v1/user" || true)"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    note "Gitea-Zugriff ist fehlgeschlagen (HTTP ${status:-keine Verbindung})."
    rm -f "$out"
    return 1
  fi
  if ! python3 - "$out" <<'PY'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: data=json.load(f)
if not isinstance(data,dict) or not data.get('login'): raise SystemExit(1)
PY
  then
    note "Gitea hat keine erwartete Benutzerantwort geliefert."
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  note "Gitea-URL und Zugriffstoken erfolgreich geprüft."
}

run_from_proxmox() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "In der Proxmox-Shell als root ausführen."
  [[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Proxmox-Konsole erkannt."
  local cmd mcp_ctid tmp_input remote_input rc
  for cmd in pct base64 tr mktemp curl python3 rm; do command -v "$cmd" >/dev/null || fail "$cmd wird auf dem Proxmox-Host benötigt."; done

  mcp_ctid="$(prompt_mcp_lxc)"
  note "Verwende MCP-LXC CT $mcp_ctid."
  while true; do
    prompt_gitea
    preflight_gitea && break
    note "URL oder Token konnten nicht bestätigt werden. Bitte erneut eingeben."
  done

  tmp_input="$(mktemp)"
  remote_input="/root/.gitea-connector-install-input"
  trap 'rm -f "$tmp_input"' EXIT
  umask 077
  {
    printf 'GITEA_URL_B64=%s\n' "$(b64 "$GITEA_URL")"
    printf 'GITEA_TOKEN_B64=%s\n' "$(b64 "$GITEA_TOKEN")"
  } > "$tmp_input"

  pct push "$mcp_ctid" "$tmp_input" "$remote_input" >/dev/null || fail "Installationsdaten konnten nicht in den MCP-LXC übertragen werden."
  pct exec "$mcp_ctid" -- chmod 600 "$remote_input" >/dev/null

  set +e
  pct exec "$mcp_ctid" -- env GITEA_INSTALL_INPUT="$remote_input" bash -lc "bash <(curl -fsSL '$SELF_URL')"
  rc=$?
  set -e

  pct exec "$mcp_ctid" -- rm -f "$remote_input" >/dev/null 2>&1 || true
  rm -f "$tmp_input"
  trap - EXIT
  return "$rc"
}

read_transferred_credentials() {
  local input="$GITEA_INSTALL_INPUT" value
  [[ -r "$input" ]] || fail "Übertragene Installationsdaten fehlen im MCP-LXC."
  value="$(sed -n 's/^GITEA_URL_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "Gitea-URL fehlt."; GITEA_URL="$(printf '%s' "$value" | base64 -d)"
  value="$(sed -n 's/^GITEA_TOKEN_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "Gitea-Token fehlt."; GITEA_TOKEN="$(printf '%s' "$value" | base64 -d)"
}

prepare_connector_path() {
  local backup_path
  if grep -Eq '"id"[[:space:]]*:[[:space:]]*"gitea"' "$HOST_CONFIG"; then
    fail "Eine Gitea-Connector-Installation ist bereits am zentralen MCP registriert."
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx 'gitea-mcp'; then
    docker rm -f gitea-mcp >/dev/null || fail "Der unvollständige Gitea-Connector-Container konnte nicht entfernt werden."
  fi
  [[ -e "$CONNECTOR_ROOT" ]] || return 0
  backup_path="${CONNECTOR_ROOT}.failed-$(date +%Y%m%d-%H%M%S)"
  mv "$CONNECTOR_ROOT" "$backup_path" || fail "Unvollständige vorherige Installation konnte nicht gesichert werden."
  note "Unvollständiger vorheriger Installationsversuch wurde erhalten unter: $backup_path"
}

if command -v pct >/dev/null 2>&1 && [[ -z "${GITEA_INSTALL_INPUT:-}" ]]; then
  run_from_proxmox
  exit $?
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Als root im Bratonien-MCP-LXC ausführen."
for cmd in docker python3 openssl curl tar base64 sed head grep mv date mktemp rm systemctl; do command -v "$cmd" >/dev/null || fail "$cmd wird im MCP-LXC benötigt."; done
[[ -r "$HOST_CONFIG" ]] || fail "Bratonien-MCP-Konfiguration fehlt: $HOST_CONFIG"
[[ -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Umgebung fehlt: $HOST_ENV"

if [[ -n "${GITEA_INSTALL_INPUT:-}" ]]; then
  read_transferred_credentials
  preflight_gitea || fail "Die zuvor geprüften Gitea-Daten funktionieren aus dem MCP-LXC nicht."
else
  prompt_gitea
  preflight_gitea || fail "Gitea-Zugang konnte nicht bestätigt werden."
fi

prepare_connector_path

INTERNAL_TOKEN="$(openssl rand -hex 32)"
GITEA_APP_TOKEN="$(openssl rand -hex 32)"
TMP_ARCHIVE="$(mktemp)"
trap 'rm -f "$TMP_ARCHIVE"' EXIT
mkdir -p "$CONNECTOR_ROOT"
curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || fail "Connector-Archiv konnte nicht von GitHub geladen werden."
tar -xzf "$TMP_ARCHIVE" -C "$CONNECTOR_ROOT" --strip-components=2 --wildcards '*/gitea/*' || fail "Connector-Archiv konnte nicht entpackt werden."
[[ -f "$APP_DIR/docker-compose.yml" && -f "$APP_DIR/server.py" && -f "$APP_DIR/http_server.py" ]] || fail "Gitea-Connector-Dateien fehlen."

umask 077
cat > "$APP_DIR/.env" <<EOF
GITEA_URL=$GITEA_URL
GITEA_TOKEN=$GITEA_TOKEN
MCP_HTTP_TOKEN=$INTERNAL_TOKEN
MCP_BIND_ADDRESS=127.0.0.1
MCP_PORT=8101
MCP_CONTAINER_NAME=gitea-mcp
EOF
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build
for _ in {1..45}; do
  curl -fsS http://127.0.0.1:8101/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:8101/health >/dev/null || fail "Gitea Connector wurde nicht bereit."

python3 - "$HOST_CONFIG" <<'PY'
import json,sys,tempfile,os
path=sys.argv[1]
with open(path,encoding='utf-8') as f: cfg=json.load(f)
connectors=[c for c in cfg.get('connectors',[]) if c.get('id') != 'gitea']
connectors.append({'id':'gitea','enabled':True,'url':'http://127.0.0.1:8101/mcp','timeout_seconds':30,'auth':{'mode':'service_token','bearer_env':'GITEA_CONNECTOR_HTTP_TOKEN'}})
cfg['connectors']=connectors
host=cfg.setdefault('host', {})
access=[x for x in (host.get('access_tokens') or []) if isinstance(x,dict) and x.get('env') != 'MCP_GITEA_HTTP_TOKEN']
access.append({'env':'MCP_GITEA_HTTP_TOKEN','connectors':['gitea']})
host['access_tokens']=access
fd,tmp=tempfile.mkstemp(prefix='.config-',dir=os.path.dirname(path),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f: json.dump(cfg,f,indent=2); f.write('\n')
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

python3 - "$HOST_ENV" "$INTERNAL_TOKEN" "$GITEA_APP_TOKEN" <<'PY'
import sys,os,tempfile
path,internal,app=sys.argv[1:]
replace={'GITEA_CONNECTOR_HTTP_TOKEN':internal,'MCP_GITEA_HTTP_TOKEN':app}
lines=[]; seen=set()
if os.path.exists(path):
    with open(path,encoding='utf-8') as f:
        for line in f:
            if '=' in line and not line.lstrip().startswith('#'):
                key=line.split('=',1)[0].strip()
                if key in replace:
                    if key not in seen: lines.append(key+'='+replace[key]+'\n'); seen.add(key)
                    continue
            lines.append(line)
for key,value in replace.items():
    if key not in seen: lines.append(key+'='+value+'\n')
fd,tmp=tempfile.mkstemp(prefix='.hostenv-',dir=os.path.dirname(path),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f: f.writelines(lines)
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

systemctl restart bratonien-mcp.service
sleep 1
curl -fsS http://127.0.0.1:8000/health >/dev/null || fail "Zentraler MCP-Host ist nach Registrierung nicht bereit."

TOOLS_RESPONSE="$(curl -fsS -H "Authorization: Bearer $GITEA_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp)" || fail "tools/list über den zentralen Host fehlgeschlagen."
python3 - "$TOOLS_RESPONSE" <<'PY' || fail "Gitea-Namespace ist über den zentralen Host nicht korrekt getrennt."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error'): raise SystemExit(1)
names=[str(t.get('name','')) for t in ((data.get('result') or {}).get('tools') or [])]
if 'gitea__list_repositories' not in names or any(not name.startswith('gitea__') for name in names): raise SystemExit(1)
PY

READ_RESPONSE="$(curl -fsS -H "Authorization: Bearer $GITEA_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gitea__list_repositories","arguments":{"page":1,"limit":1}}}' http://127.0.0.1:8000/mcp)" || fail "Read-only Gitea-Smoke-Test über den zentralen Host fehlgeschlagen."
python3 - "$READ_RESPONSE" <<'PY' || fail "Read-only Gitea-Smoke-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True: raise SystemExit(1)
PY

CROSS_RESPONSE="$(curl -fsS -H "Authorization: Bearer $GITEA_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"manifold__whoami","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Cross-Namespace-Test konnte nicht ausgeführt werden."
python3 - "$CROSS_RESPONSE" <<'PY' || fail "Gitea-App-Token kann unerwartet auf Manifold zugreifen."
import json,sys
data=json.loads(sys.argv[1]); err=data.get('error') or {}
if err.get('code') != -32602: raise SystemExit(1)
PY

echo
echo "============================================================"
echo " Gitea Connector registriert und geprüft"
echo "============================================================"
echo "Gitea API:          $GITEA_URL"
echo "Interner Connector: http://127.0.0.1:8101/mcp"
echo "Namespace:          gitea__"
echo "App-Token-Variable: MCP_GITEA_HTTP_TOKEN"
echo "Read-only API-Test: erfolgreich"
echo "Cross-Namespace:    blockiert"
echo
echo "Der eigentliche App-Token steht geschützt in $HOST_ENV."
