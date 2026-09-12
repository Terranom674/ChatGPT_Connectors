#!/usr/bin/env bash
set -Eeuo pipefail

SELF_URL="https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/affine/install/register-with-bratonien-mcp.sh"
HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/affine"
APP_DIR="$CONNECTOR_ROOT/plugins/affine-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-affine-connector"
TTY=/dev/tty

fail(){ echo "FEHLER: $*" >&2; exit 1; }
note(){ echo "$*" >&2; }
b64(){ printf '%s' "$1" | base64 | tr -d '\n'; }

normalize_https_url(){
  local value="${1%/}"
  [[ "$value" =~ ^https:// ]] || value="https://$value"
  [[ "$value" =~ ^https://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]] || return 1
  printf '%s' "$value"
}

prompt_ctid(){
  local label="$1" ctid status
  while true; do
    printf '%s' "$label" > "$TTY"
    read -r ctid < "$TTY"
    [[ "$ctid" =~ ^[0-9]+$ ]] || { note "Bitte eine gültige numerische CT-ID eingeben."; continue; }
    status="$(pct status "$ctid" 2>/dev/null || true)"
    [[ "$status" == "status: running" ]] || { note "CT $ctid existiert nicht oder läuft nicht."; continue; }
    printf '%s' "$ctid"; return 0
  done
}

prompt_mcp_lxc(){
  local ctid
  while true; do
    ctid="$(prompt_ctid 'CT-ID des bestehenden MCP-LXC: ')"
    pct exec "$ctid" -- test -r "$HOST_CONFIG" >/dev/null 2>&1 || { note "CT $ctid enthält keine Bratonien-MCP-Konfiguration."; continue; }
    pct exec "$ctid" -- test -r "$HOST_ENV" >/dev/null 2>&1 || { note "CT $ctid enthält keine Bratonien-MCP-Umgebung."; continue; }
    pct exec "$ctid" -- sh -lc 'command -v docker >/dev/null 2>&1' >/dev/null 2>&1 || { note "In CT $ctid ist Docker nicht verfügbar."; continue; }
    printf '%s' "$ctid"; return 0
  done
}

prompt_affine(){
  local value
  while true; do
    printf 'Öffentliche AFFiNE-URL: ' > "$TTY"; read -r value < "$TTY"
    AFFINE_URL="$(normalize_https_url "$value")" || { note "Bitte eine gültige HTTPS-URL eingeben."; continue; }
    break
  done
  printf 'AFFiNE Workspace-ID: ' > "$TTY"; read -r AFFINE_WORKSPACE_ID < "$TTY"
  [[ -n "$AFFINE_WORKSPACE_ID" ]] || fail "Workspace-ID darf nicht leer sein."
  printf 'AFFiNE MCP-Token (READ_WRITE): ' > "$TTY"; stty -echo < "$TTY"; read -r AFFINE_MCP_TOKEN < "$TTY"; stty echo < "$TTY"; printf '\n' > "$TTY"
  [[ "$AFFINE_MCP_TOKEN" == aff_mcp_v1.*.* ]] || fail "Der AFFiNE-MCP-Token hat nicht das erwartete Format aff_mcp_v1.<id>.<secret>."
}

check_affine(){
  local out status
  out="$(mktemp)"
  status="$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' -X POST "$AFFINE_URL/api/workspaces/$AFFINE_WORKSPACE_ID/mcp/" \
    -H "Authorization: Bearer $AFFINE_MCP_TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' || true)"
  [[ "$status" =~ ^2[0-9][0-9]$ ]] || { cat "$out" >&2 || true; rm -f "$out"; return 1; }
  python3 - "$out" <<'PY'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: data=json.load(f)
if data.get('error'): raise SystemExit(1)
names={str(x.get('name','')) for x in ((data.get('result') or {}).get('tools') or [])}
required={'read_document','doc_search','create_document','update_document','update_document_meta'}
missing=required-names
if missing:
    print('Fehlende AFFiNE MCP Tools: '+', '.join(sorted(missing)),file=sys.stderr)
    raise SystemExit(1)
PY
  local rc=$?; rm -f "$out"; return "$rc"
}

run_from_proxmox(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "In der Proxmox-Shell als root ausführen."
  [[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Proxmox-Konsole erkannt."
  local mcp_ctid tmp remote rc
  for cmd in pct base64 tr mktemp curl python3 rm stty; do command -v "$cmd" >/dev/null || fail "$cmd wird auf dem Proxmox-Host benötigt."; done
  mcp_ctid="$(prompt_mcp_lxc)"; note "Verwende MCP-LXC CT $mcp_ctid."
  pct exec "$mcp_ctid" -- grep -Eq '"id"[[:space:]]*:[[:space:]]*"affine"' "$HOST_CONFIG" && fail "AFFiNE ist bereits am zentralen MCP registriert."
  prompt_affine
  check_affine || fail "AFFiNE MCP ist mit diesem Workspace/Token nicht vollständig als READ_WRITE erreichbar."
  note "AFFiNE MCP mit READ_WRITE erfolgreich geprüft."

  tmp="$(mktemp)"; remote="/root/.affine-mcp-install-input"; trap 'rm -f "$tmp"' EXIT; umask 077
  {
    printf 'AFFINE_URL_B64=%s\n' "$(b64 "$AFFINE_URL")"
    printf 'AFFINE_WORKSPACE_ID_B64=%s\n' "$(b64 "$AFFINE_WORKSPACE_ID")"
    printf 'AFFINE_MCP_TOKEN_B64=%s\n' "$(b64 "$AFFINE_MCP_TOKEN")"
  } > "$tmp"
  pct push "$mcp_ctid" "$tmp" "$remote" >/dev/null || fail "Installationsdaten konnten nicht übertragen werden."
  pct exec "$mcp_ctid" -- chmod 600 "$remote" >/dev/null
  set +e
  pct exec "$mcp_ctid" -- env AFFINE_INSTALL_INPUT="$remote" bash -lc "bash <(curl -fsSL '$SELF_URL')"
  rc=$?
  set -e
  pct exec "$mcp_ctid" -- rm -f "$remote" >/dev/null 2>&1 || true
  rm -f "$tmp"; trap - EXIT
  return "$rc"
}

read_input(){
  local input="$AFFINE_INSTALL_INPUT" value
  [[ -r "$input" ]] || fail "Übertragene Installationsdaten fehlen."
  value="$(sed -n 's/^AFFINE_URL_B64=//p' "$input" | head -n1)"; AFFINE_URL="$(printf '%s' "$value" | base64 -d)"
  value="$(sed -n 's/^AFFINE_WORKSPACE_ID_B64=//p' "$input" | head -n1)"; AFFINE_WORKSPACE_ID="$(printf '%s' "$value" | base64 -d)"
  value="$(sed -n 's/^AFFINE_MCP_TOKEN_B64=//p' "$input" | head -n1)"; AFFINE_MCP_TOKEN="$(printf '%s' "$value" | base64 -d)"
}

if command -v pct >/dev/null 2>&1 && [[ -z "${AFFINE_INSTALL_INPUT:-}" ]]; then run_from_proxmox; exit $?; fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Als root im Bratonien-MCP-LXC ausführen."
for cmd in docker python3 openssl curl tar base64 sed head grep mktemp rm systemctl; do command -v "$cmd" >/dev/null || fail "$cmd wird im MCP-LXC benötigt."; done
[[ -r "$HOST_CONFIG" && -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Konfiguration fehlt."
[[ -n "${AFFINE_INSTALL_INPUT:-}" ]] || fail "Dieser Installer wird aus der Proxmox-Host-Shell gestartet."
read_input
check_affine || fail "AFFiNE MCP ist aus dem MCP-LXC nicht vollständig erreichbar."

[[ ! -e "$CONNECTOR_ROOT" ]] || fail "AFFiNE Connector-Verzeichnis existiert bereits: $CONNECTOR_ROOT"
[[ "$(docker ps -a --format '{{.Names}}' | grep -x affine-mcp || true)" == "" ]] || fail "Container affine-mcp existiert bereits."

INTERNAL_TOKEN="$(openssl rand -hex 32)"
AFFINE_APP_TOKEN="$(openssl rand -hex 32)"
TMP_ARCHIVE="$(mktemp)"; trap 'rm -f "$TMP_ARCHIVE"' EXIT
mkdir -p "$CONNECTOR_ROOT"
curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || fail "Connector-Archiv konnte nicht geladen werden."
tar -xzf "$TMP_ARCHIVE" -C "$CONNECTOR_ROOT" --strip-components=2 --wildcards '*/affine/*' || fail "AFFiNE Connector konnte nicht entpackt werden."
[[ -f "$APP_DIR/docker-compose.yml" && -f "$APP_DIR/server.py" && -f "$APP_DIR/http_server.py" ]] || fail "AFFiNE Connector-Dateien fehlen."

umask 077
cat > "$APP_DIR/.env" <<EOF
AFFINE_URL=$AFFINE_URL
AFFINE_WORKSPACE_ID=$AFFINE_WORKSPACE_ID
AFFINE_MCP_TOKEN=$AFFINE_MCP_TOKEN
MCP_HTTP_TOKEN=$INTERNAL_TOKEN
MCP_BIND_ADDRESS=127.0.0.1
MCP_PORT=8104
MCP_CONTAINER_NAME=affine-mcp
EOF
chmod 600 "$APP_DIR/.env"
cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build
for _ in {1..45}; do curl -fsS http://127.0.0.1:8104/health >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://127.0.0.1:8104/health >/dev/null || fail "AFFiNE-MCP-Dienst wurde nicht bereit."

python3 - "$HOST_CONFIG" <<'PY'
import json,sys,tempfile,os
path=sys.argv[1]
with open(path,encoding='utf-8') as f: cfg=json.load(f)
connectors=[c for c in cfg.get('connectors',[]) if c.get('id')!='affine']
connectors.append({'id':'affine','enabled':True,'url':'http://127.0.0.1:8104/mcp','timeout_seconds':30,'auth':{'mode':'service_token','bearer_env':'AFFINE_CONNECTOR_HTTP_TOKEN'}})
cfg['connectors']=connectors
host=cfg.setdefault('host',{})
access=[x for x in (host.get('access_tokens') or []) if isinstance(x,dict) and x.get('env')!='MCP_AFFINE_HTTP_TOKEN']
access.append({'env':'MCP_AFFINE_HTTP_TOKEN','connectors':['affine']})
host['access_tokens']=access
fd,tmp=tempfile.mkstemp(prefix='.config-',dir=os.path.dirname(path),text=True)
with os.fdopen(fd,'w',encoding='utf-8') as f: json.dump(cfg,f,indent=2); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,path)
PY

python3 - "$HOST_ENV" "$INTERNAL_TOKEN" "$AFFINE_APP_TOKEN" <<'PY'
import sys,os,tempfile
path,internal,app=sys.argv[1:]
replace={'AFFINE_CONNECTOR_HTTP_TOKEN':internal,'MCP_AFFINE_HTTP_TOKEN':app}
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
with os.fdopen(fd,'w',encoding='utf-8') as f: f.writelines(lines)
os.chmod(tmp,0o600); os.replace(tmp,path)
PY

systemctl restart bratonien-mcp.service
sleep 1
curl -fsS http://127.0.0.1:8000/health >/dev/null || fail "Zentraler MCP-Host ist nach Registrierung nicht bereit."

TOOLS="$(curl -fsS -H "Authorization: Bearer $AFFINE_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp)" || fail "tools/list über zentralen MCP fehlgeschlagen."
TOOL_COUNT="$(python3 - "$TOOLS" <<'PY'
import json,sys
data=json.loads(sys.argv[1]);
if data.get('error'): raise SystemExit(1)
names={str(t.get('name','')) for t in ((data.get('result') or {}).get('tools') or [])}
required={'affine__read_document','affine__doc_search','affine__create_document','affine__update_document','affine__update_document_meta'}
if not required.issubset(names):
 print('Fehlende Tools: '+', '.join(sorted(required-names)),file=sys.stderr); raise SystemExit(1)
if any(not x.startswith('affine__') for x in names): raise SystemExit(1)
print(len(names))
PY
)" || fail "AFFiNE Tool-Oberfläche ist über den zentralen MCP nicht vollständig."

CROSS="$(curl -fsS -H "Authorization: Bearer $AFFINE_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"linkstack__system_diagnostics","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Cross-Namespace-Test konnte nicht ausgeführt werden."
python3 - "$CROSS" <<'PY' || fail "AFFiNE-App-Token kann unerwartet auf LinkStack zugreifen."
import json,sys
err=(json.loads(sys.argv[1]).get('error') or {})
if err.get('code') != -32602: raise SystemExit(1)
PY

echo
echo "============================================================"
echo " AFFiNE am MCP-Server registriert und geprüft"
echo "============================================================"
echo "AFFiNE:               $AFFINE_URL"
echo "Workspace:            $AFFINE_WORKSPACE_ID"
echo "AFFiNE-MCP-Dienst:    http://127.0.0.1:8104/mcp"
echo "Namespace:            affine__"
echo "App-Token-Variable:   MCP_AFFINE_HTTP_TOKEN"
echo "AFFiNE-Tools:          $TOOL_COUNT"
echo "READ_WRITE Tools:      vollständig"
echo "Cross-Namespace:       blockiert"
echo
echo "Das AFFiNE-MCP-Credential liegt geschützt in $APP_DIR/.env."
echo "Der MCP-App-Token für ChatGPT steht geschützt in $HOST_ENV."
