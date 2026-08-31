#!/usr/bin/env bash
set -Eeuo pipefail

SELF_URL="https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/manifold/install/register-with-bratonien-mcp.sh"
HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/manifold"
APP_DIR="$CONNECTOR_ROOT/plugins/manifold-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-manifold-connector"
TTY=/dev/tty

fail() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo "$*" >&2; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

normalize_https_url() {
  local value="${1%/}"
  [[ "$value" =~ ^https:// ]] || value="https://$value"
  [[ "$value" =~ ^https://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]] || return 1
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

prompt_manifold_url() {
  local value
  while true; do
    printf 'Öffentliche Manifold-URL (z. B. chroniken.bratonien.de): ' > "$TTY"
    read -r value < "$TTY"
    MANIFOLD_URL="$(normalize_https_url "$value")" || { note "Bitte eine gültige HTTPS-URL eingeben."; continue; }
    return 0
  done
}

prompt_login() {
  while true; do
    printf 'Manifold-E-Mail: ' > "$TTY"
    read -r MANIFOLD_EMAIL < "$TTY"
    [[ -n "$MANIFOLD_EMAIL" ]] && break
    note "E-Mail darf nicht leer sein."
  done
  while true; do
    printf 'Manifold-Passwort: ' > "$TTY"
    read -r -s MANIFOLD_PASSWORD < "$TTY"; echo > "$TTY"
    [[ -n "$MANIFOLD_PASSWORD" ]] && break
    note "Passwort darf nicht leer sein."
  done
}

inspect_api_schema() {
  local schema_file schema_status
  schema_file="$(mktemp)"
  schema_status="$(curl -sS --max-time 20 -o "$schema_file" -w '%{http_code}' \
    -H 'Accept: application/json' \
    "$MANIFOLD_URL/api/static/docs/v1/swagger.json" || true)"

  if [[ "$schema_status" =~ ^2[0-9][0-9]$ ]]; then
    if grep -Eq '"(/api/v1)?/tokens"[[:space:]]*:' "$schema_file" || \
       { grep -Eq '"basePath"[[:space:]]*:[[:space:]]*"/api/v1"' "$schema_file" && grep -Eq '"/tokens"[[:space:]]*:' "$schema_file"; }; then
      note "Manifold-API-Schema über HTTPS gefunden; Token-Endpunkt ist dokumentiert."
    else
      note "Manifold-API-Schema über HTTPS gefunden; Token-Endpunkt ist darin nicht eindeutig dokumentiert."
    fi
  else
    note "Hinweis: Das Manifold-API-Schema ist über die öffentliche HTTPS-URL nicht abrufbar (HTTP ${schema_status:-keine Verbindung})."
  fi

  rm -f "$schema_file"
}

preflight_credentials() {
  local token_file whoami_file token_status whoami_status auth_token
  token_file="$(mktemp)"
  whoami_file="$(mktemp)"

  [[ "$MANIFOLD_URL" =~ ^https:// ]] || { note "Manifold muss über die öffentliche HTTPS-URL angesprochen werden."; rm -f "$token_file" "$whoami_file"; return 1; }

  token_status="$(curl -sS --max-time 20 -o "$token_file" -w '%{http_code}' \
    -X POST \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    --url-query "email=$MANIFOLD_EMAIL" \
    --url-query "password=$MANIFOLD_PASSWORD" \
    "$MANIFOLD_URL/api/v1/tokens" || true)"

  if [[ "$token_status" == "401" ]]; then
    rm -f "$token_file" "$whoami_file"
    note "E-Mail oder Passwort wurden von Manifold abgelehnt."
    return 1
  fi
  if [[ ! "$token_status" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$token_file" "$whoami_file"
    note "Manifold-Login über $MANIFOLD_URL/api/v1/tokens ist fehlgeschlagen (HTTP ${token_status:-keine Verbindung})."
    return 1
  fi

  auth_token="$(sed -n 's/.*"authToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$token_file" | head -n1)"
  if [[ -z "$auth_token" ]]; then
    rm -f "$token_file" "$whoami_file"
    note "Manifold hat nach erfolgreicher Anmeldung kein Auth-Token geliefert."
    return 1
  fi

  whoami_status="$(curl -sS --max-time 20 -o "$whoami_file" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer $auth_token" \
    "$MANIFOLD_URL/api/v1/users/whoami" || true)"

  rm -f "$token_file" "$whoami_file"

  if [[ ! "$whoami_status" =~ ^2[0-9][0-9]$ ]]; then
    note "Manifold whoami ist nach erfolgreicher Anmeldung fehlgeschlagen (HTTP ${whoami_status:-keine Verbindung})."
    return 1
  fi

  note "Manifold-Zugang über HTTPS erfolgreich geprüft."
  return 0
}

prompt_and_validate_manifold() {
  while true; do
    prompt_manifold_url
    inspect_api_schema
    prompt_login
    if preflight_credentials; then
      return 0
    fi
    note "Die Angaben oder der öffentliche API-Zugriff konnten nicht bestätigt werden. URL, E-Mail und Passwort können erneut eingegeben werden."
    echo > "$TTY"
  done
}

run_from_proxmox() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "In der Proxmox-Shell als root ausführen."
  [[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Proxmox-Konsole erkannt."
  local cmd mcp_ctid tmp_input remote_input rc
  for cmd in pct base64 tr mktemp curl sed head rm grep; do command -v "$cmd" >/dev/null || fail "$cmd wird auf dem Proxmox-Host benötigt."; done

  mcp_ctid="$(prompt_mcp_lxc)"
  note "Verwende MCP-LXC CT $mcp_ctid."
  prompt_and_validate_manifold

  tmp_input="$(mktemp)"
  remote_input="/root/.manifold-connector-install-input"
  trap 'rm -f "$tmp_input"' EXIT
  umask 077
  {
    printf 'MANIFOLD_URL_B64=%s\n' "$(b64 "$MANIFOLD_URL")"
    printf 'MANIFOLD_EMAIL_B64=%s\n' "$(b64 "$MANIFOLD_EMAIL")"
    printf 'MANIFOLD_PASSWORD_B64=%s\n' "$(b64 "$MANIFOLD_PASSWORD")"
  } > "$tmp_input"

  pct push "$mcp_ctid" "$tmp_input" "$remote_input" >/dev/null || fail "Installationsdaten konnten nicht in den MCP-LXC übertragen werden."
  pct exec "$mcp_ctid" -- chmod 600 "$remote_input" >/dev/null

  set +e
  pct exec "$mcp_ctid" -- env MANIFOLD_INSTALL_INPUT="$remote_input" bash -lc "bash <(curl -fsSL '$SELF_URL')"
  rc=$?
  set -e

  pct exec "$mcp_ctid" -- rm -f "$remote_input" >/dev/null 2>&1 || true
  rm -f "$tmp_input"
  trap - EXIT
  return "$rc"
}

read_transferred_credentials() {
  local input="$MANIFOLD_INSTALL_INPUT" value
  [[ -r "$input" ]] || fail "Übertragene Installationsdaten fehlen im MCP-LXC."
  value="$(sed -n 's/^MANIFOLD_URL_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "Manifold-URL fehlt."; MANIFOLD_URL="$(printf '%s' "$value" | base64 -d)"
  value="$(sed -n 's/^MANIFOLD_EMAIL_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "Manifold-E-Mail fehlt."; MANIFOLD_EMAIL="$(printf '%s' "$value" | base64 -d)"
  value="$(sed -n 's/^MANIFOLD_PASSWORD_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "Manifold-Passwort fehlt."; MANIFOLD_PASSWORD="$(printf '%s' "$value" | base64 -d)"
}

prepare_connector_path() {
  local backup_path
  if grep -Eq '"id"[[:space:]]*:[[:space:]]*"manifold"' "$HOST_CONFIG"; then
    fail "Eine Manifold-Connector-Installation ist bereits am zentralen MCP registriert."
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx 'manifold-mcp'; then
    docker rm -f manifold-mcp >/dev/null || fail "Der unvollständige Manifold-Connector-Container konnte nicht entfernt werden."
  fi

  [[ -e "$CONNECTOR_ROOT" ]] || return 0
  backup_path="${CONNECTOR_ROOT}.failed-$(date +%Y%m%d-%H%M%S)"
  mv "$CONNECTOR_ROOT" "$backup_path" || fail "Unvollständige vorherige Installation konnte nicht gesichert werden."
  note "Unvollständiger vorheriger Installationsversuch wurde erhalten unter: $backup_path"
}

if command -v pct >/dev/null 2>&1 && [[ -z "${MANIFOLD_INSTALL_INPUT:-}" ]]; then
  run_from_proxmox
  exit $?
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Als root im Bratonien-MCP-LXC ausführen."
for cmd in docker python3 openssl curl tar base64 sed head grep mv date mktemp rm; do command -v "$cmd" >/dev/null || fail "$cmd wird im MCP-LXC benötigt."; done
[[ -r "$HOST_CONFIG" ]] || fail "Bratonien-MCP-Konfiguration fehlt: $HOST_CONFIG"
[[ -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Umgebung fehlt: $HOST_ENV"

if [[ -n "${MANIFOLD_INSTALL_INPUT:-}" ]]; then
  read_transferred_credentials
  [[ "$MANIFOLD_URL" =~ ^https:// ]] || fail "Die übertragene Manifold-URL ist keine HTTPS-URL."
  preflight_credentials || fail "Die zuvor geprüften Manifold-Daten funktionieren aus dem MCP-LXC nicht über die öffentliche HTTPS-URL."
else
  prompt_and_validate_manifold
fi

prepare_connector_path

INTERNAL_TOKEN="$(openssl rand -hex 32)"
MANIFOLD_APP_TOKEN="$(openssl rand -hex 32)"
TMP_ARCHIVE="$(mktemp)"
trap 'rm -f "$TMP_ARCHIVE"' EXIT
mkdir -p "$CONNECTOR_ROOT"
curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || fail "Connector-Archiv konnte nicht von GitHub geladen werden."
tar -xzf "$TMP_ARCHIVE" -C "$CONNECTOR_ROOT" --strip-components=2 --wildcards '*/manifold/*' || fail "Connector-Archiv konnte nicht entpackt werden."
[[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Connector-Dateien wurden nicht vollständig entpackt."
[[ -f "$APP_DIR/operations.py" && -f "$APP_DIR/management_surface.py" ]] || fail "Manifold-Tool-Oberfläche fehlt im Connector-Archiv."

umask 077
cat > "$APP_DIR/.env" <<EOF
MANIFOLD_URL=$MANIFOLD_URL
MANIFOLD_EMAIL=$MANIFOLD_EMAIL
MANIFOLD_PASSWORD=$MANIFOLD_PASSWORD
MCP_HTTP_TOKEN=$INTERNAL_TOKEN
MCP_BIND_ADDRESS=127.0.0.1
MCP_PORT=8102
MCP_CONTAINER_NAME=manifold-mcp
EOF
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build
for _ in {1..45}; do
  curl -fsS http://127.0.0.1:8102/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:8102/health >/dev/null || fail "Manifold Connector wurde nicht bereit."

WHOAMI="$(curl -fsS -H "Authorization: Bearer $INTERNAL_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami","arguments":{}}}' http://127.0.0.1:8102/mcp)" || fail "Manifold whoami-Test fehlgeschlagen."
python3 - "$WHOAMI" <<'PY' || fail "Manifold whoami-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY

python3 - "$HOST_CONFIG" <<'PY'
import json,sys,tempfile,os
path=sys.argv[1]
with open(path,encoding='utf-8') as f:
    cfg=json.load(f)
connectors=[c for c in cfg.get('connectors',[]) if c.get('id') != 'manifold']
connectors.append({'id':'manifold','enabled':True,'url':'http://127.0.0.1:8102/mcp','timeout_seconds':30,'auth':{'mode':'service_token','bearer_env':'MANIFOLD_CONNECTOR_HTTP_TOKEN'}})
cfg['connectors']=connectors
host=cfg.setdefault('host', {})
access=[x for x in (host.get('access_tokens') or []) if isinstance(x,dict) and x.get('env') != 'MCP_MANIFOLD_HTTP_TOKEN']
access.append({'env':'MCP_MANIFOLD_HTTP_TOKEN','connectors':['manifold']})
host['access_tokens']=access
fd,tmp=tempfile.mkstemp(prefix='.config-',dir=os.path.dirname(path),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(cfg,f,indent=2); f.write('\n')
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

python3 - "$HOST_ENV" "$INTERNAL_TOKEN" "$MANIFOLD_APP_TOKEN" <<'PY'
import sys,os,tempfile
path,internal,app=sys.argv[1:]
replace={
    'MANIFOLD_CONNECTOR_HTTP_TOKEN': internal,
    'MCP_MANIFOLD_HTTP_TOKEN': app,
}
lines=[]
seen=set()
if os.path.exists(path):
    with open(path,encoding='utf-8') as f:
        for line in f:
            if '=' in line and not line.lstrip().startswith('#'):
                key=line.split('=',1)[0].strip()
                if key in replace:
                    if key not in seen:
                        lines.append(key+'='+replace[key]+'\n')
                        seen.add(key)
                    continue
            lines.append(line)
for key,value in replace.items():
    if key not in seen:
        lines.append(key+'='+value+'\n')
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

TOOLS_FILE="$(mktemp)"
trap 'rm -f "$TMP_ARCHIVE" "$TOOLS_FILE"' EXIT
curl -fsS -H "Authorization: Bearer $MANIFOLD_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp > "$TOOLS_FILE" || fail "tools/list über den zentralen Host fehlgeschlagen."
TOOL_COUNT="$(python3 - "$TOOLS_FILE" "$APP_DIR" <<'PY'
import importlib.util,json,os,sys
payload_path,app=sys.argv[1],sys.argv[2]
with open(payload_path,encoding='utf-8') as f:
    data=json.load(f)
if data.get('error'): raise SystemExit(1)
all_names=[str(t.get('name','')) for t in ((data.get('result') or {}).get('tools') or [])]
if any(not name.startswith('manifold__') for name in all_names):
    raise SystemExit(1)
names=set(all_names)
spec=importlib.util.spec_from_file_location('management_surface', os.path.join(app,'management_surface.py'))
mod=importlib.util.module_from_spec(spec)
sys.path.insert(0,app); spec.loader.exec_module(mod)
required={'manifold__'+name for name in mod.REQUIRED_MANAGEMENT_TOOLS}
if not required.issubset(names):
    missing=sorted(required-names)
    print('Fehlende Tools: '+', '.join(missing), file=sys.stderr)
    raise SystemExit(1)
print(len(names))
PY
)" || fail "Manifold-Verwaltungsoberfläche ist über den zentralen Host nicht vollständig oder nicht sauber getrennt sichtbar."
rm -f "$TOOLS_FILE"

READ="$(curl -fsS -H "Authorization: Bearer $MANIFOLD_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"manifold__whoami","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Manifold-Test über den zentralen Host fehlgeschlagen."
python3 - "$READ" <<'PY' || fail "Manifold-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY

CROSS="$(curl -fsS -H "Authorization: Bearer $MANIFOLD_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"gitea__list_repositories","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Cross-Namespace-Test konnte nicht ausgeführt werden."
python3 - "$CROSS" <<'PY' || fail "Manifold-App-Token kann unerwartet auf Gitea zugreifen."
import json,sys
data=json.loads(sys.argv[1])
err=data.get('error') or {}
if err.get('code') != -32602:
    raise SystemExit(1)
PY

echo
echo "============================================================"
echo " Manifold Connector registriert und geprüft"
echo "============================================================"
echo "Manifold API:       $MANIFOLD_URL"
echo "Interner Connector: http://127.0.0.1:8102/mcp"
echo "Namespace:          manifold__"
echo "App-Token-Variable: MCP_MANIFOLD_HTTP_TOKEN"
echo "Manifold-Tools:     $TOOL_COUNT"
echo "whoami:             erfolgreich"
echo "Cross-Namespace:    blockiert"
echo
echo "Der eigentliche App-Token steht geschützt in $HOST_ENV."
echo "Für ChatGPT die Variable MCP_MANIFOLD_HTTP_TOKEN verwenden."
