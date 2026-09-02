#!/usr/bin/env bash
set -Eeuo pipefail

HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/linkstack"
APP_DIR="$CONNECTOR_ROOT/plugins/linkstack-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-linkstack-connector"
TTY=/dev/tty

fail() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

prompt_ctid() {
  local ctid status
  while true; do
    printf 'CT-ID des bestehenden MCP-LXC: ' > "$TTY"
    read -r ctid < "$TTY"
    [[ "$ctid" =~ ^[0-9]+$ ]] || { note "Bitte eine gültige numerische CT-ID eingeben."; continue; }
    status="$(pct status "$ctid" 2>/dev/null || true)"
    [[ "$status" == "status: running" ]] || { note "CT $ctid existiert nicht oder läuft nicht."; continue; }
    pct exec "$ctid" -- test -r "$HOST_CONFIG" >/dev/null 2>&1 || { note "CT $ctid enthält keine Bratonien-MCP-Konfiguration."; continue; }
    pct exec "$ctid" -- test -r "$HOST_ENV" >/dev/null 2>&1 || { note "CT $ctid enthält keine Bratonien-MCP-Umgebung."; continue; }
    printf '%s' "$ctid"
    return 0
  done
}

run_update() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "In der Proxmox-Shell als root ausführen."
  [[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Proxmox-Konsole erkannt."
  command -v pct >/dev/null 2>&1 || fail "pct wird auf dem Proxmox-Host benötigt."

  local ctid
  ctid="$(prompt_ctid)"
  note "Aktualisiere LinkStack-Connector in CT $ctid."

  pct exec "$ctid" -- bash -s <<'INNER'
set -Eeuo pipefail

HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/linkstack"
APP_DIR="$CONNECTOR_ROOT/plugins/linkstack-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-linkstack-connector"

fail() { echo "FEHLER: $*" >&2; exit 1; }

for cmd in docker curl tar python3 grep mktemp cp rm systemctl sed head; do
  command -v "$cmd" >/dev/null || fail "$cmd wird im MCP-LXC benötigt."
done
[[ -r "$HOST_CONFIG" ]] || fail "Bratonien-MCP-Konfiguration fehlt."
[[ -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Umgebung fehlt."
[[ -d "$APP_DIR" ]] || fail "Installierter LinkStack-Connector fehlt unter $APP_DIR."
[[ -r "$APP_DIR/.env" ]] || fail "Die bestehende LinkStack-Connector-.env fehlt."
grep -Eq '"id"[[:space:]]*:[[:space:]]*"linkstack"' "$HOST_CONFIG" || fail "LinkStack ist am zentralen MCP nicht registriert."
docker ps -a --format '{{.Names}}' | grep -qx 'linkstack-mcp' || fail "Der Container linkstack-mcp existiert nicht."

TMP_ARCHIVE="$(mktemp)"
TMP_ROOT="$(mktemp -d)"
ENV_BACKUP="$(mktemp)"
trap 'rm -f "$TMP_ARCHIVE" "$ENV_BACKUP"; rm -rf "$TMP_ROOT"' EXIT

cp "$APP_DIR/.env" "$ENV_BACKUP"
curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || fail "Connector-Archiv konnte nicht von GitHub geladen werden."
tar -xzf "$TMP_ARCHIVE" -C "$TMP_ROOT" --strip-components=2 --wildcards '*/linkstack/*' || fail "Connector-Archiv konnte nicht entpackt werden."
NEW_APP="$TMP_ROOT/plugins/linkstack-connector"
[[ -f "$NEW_APP/operations.py" && -f "$NEW_APP/management_surface.py" && -f "$NEW_APP/server.py" && -f "$NEW_APP/http_server.py" && -f "$NEW_APP/docker-compose.yml" ]] || fail "Neue Connector-Dateien sind unvollständig."

python3 - "$NEW_APP" <<'PY' || fail "Neue LinkStack-Tooloberfläche ist inkonsistent."
import importlib.util,os,sys
app=sys.argv[1]
sys.path.insert(0,app)
spec=importlib.util.spec_from_file_location('management_surface',os.path.join(app,'management_surface.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
if 'me' in m.OPERATION_BY_NAME or 'me' in m.REQUIRED_MANAGEMENT_TOOLS:
    raise SystemExit('Phantom-Tool me ist noch vorhanden')
missing=m.REQUIRED_MANAGEMENT_TOOLS.difference(set(m.OPERATION_BY_NAME)|{'api_call'})
if missing:
    raise SystemExit('Fehlende Tools: '+', '.join(sorted(missing)))
PY

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$NEW_APP/." "$APP_DIR/"
cp "$ENV_BACKUP" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build
for _ in {1..45}; do
  curl -fsS http://127.0.0.1:8103/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:8103/health >/dev/null || fail "LinkStack-MCP-Dienst wurde nach Update nicht bereit."

INTERNAL_TOKEN="$(sed -n 's/^MCP_HTTP_TOKEN=//p' "$APP_DIR/.env" | head -n1)"
[[ -n "$INTERNAL_TOKEN" ]] || fail "MCP_HTTP_TOKEN fehlt in der bestehenden .env."

LOCAL_RESULT="$(curl -fsS -H "Authorization: Bearer $INTERNAL_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"system_diagnostics","arguments":{}}}' http://127.0.0.1:8103/mcp)" || fail "Lokaler system_diagnostics-Test fehlgeschlagen."
python3 - "$LOCAL_RESULT" <<'PY' || fail "Lokaler system_diagnostics-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY

systemctl restart bratonien-mcp.service
sleep 1
curl -fsS http://127.0.0.1:8000/health >/dev/null || fail "Zentraler MCP-Host ist nach Update nicht bereit."

APP_TOKEN="$(sed -n 's/^MCP_LINKSTACK_HTTP_TOKEN=//p' "$HOST_ENV" | head -n1)"
[[ -n "$APP_TOKEN" ]] || fail "MCP_LINKSTACK_HTTP_TOKEN fehlt in $HOST_ENV."

TOOLS_FILE="$(mktemp)"
trap 'rm -f "$TMP_ARCHIVE" "$ENV_BACKUP" "$TOOLS_FILE"; rm -rf "$TMP_ROOT"' EXIT
curl -fsS -H "Authorization: Bearer $APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp > "$TOOLS_FILE" || fail "tools/list über den zentralen MCP fehlgeschlagen."
python3 - "$TOOLS_FILE" <<'PY' || fail "Zentraler MCP veröffentlicht eine falsche LinkStack-Oberfläche."
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: data=json.load(f)
if data.get('error'): raise SystemExit(1)
names={str(t.get('name','')) for t in ((data.get('result') or {}).get('tools') or [])}
if 'linkstack__me' in names:
    raise SystemExit('linkstack__me ist noch vorhanden')
for required in ('linkstack__status','linkstack__system_status','linkstack__system_capabilities','linkstack__system_diagnostics'):
    if required not in names:
        raise SystemExit('Fehlendes Tool: '+required)
PY

CENTRAL_RESULT="$(curl -fsS -H "Authorization: Bearer $APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"linkstack__system_diagnostics","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Zentraler system_diagnostics-Test fehlgeschlagen."
python3 - "$CENTRAL_RESULT" <<'PY' || fail "Zentraler system_diagnostics-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY

echo
echo "============================================================"
echo " LinkStack-Connector aktualisiert und geprüft"
echo "============================================================"
echo "Container:             linkstack-mcp"
echo "Namespace:             linkstack__"
echo "system_diagnostics:    erfolgreich"
echo "Phantom-Tool me:       nicht vorhanden"
echo "Bestehende .env:       beibehalten"
echo "MCP-Registrierung:     beibehalten"
INNER
}

run_update
