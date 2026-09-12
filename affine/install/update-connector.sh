#!/usr/bin/env bash
set -Eeuo pipefail

HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/affine"
APP_DIR="$CONNECTOR_ROOT/plugins/affine-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-affine-connector"

fail(){ echo "FEHLER: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Als root im Bratonien-MCP-LXC ausführen."
for cmd in docker python3 curl tar mktemp rm systemctl grep cp mv; do command -v "$cmd" >/dev/null || fail "$cmd wird benötigt."; done
[[ -r "$HOST_CONFIG" && -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Konfiguration fehlt."
[[ -d "$APP_DIR" && -f "$APP_DIR/.env" ]] || fail "Vorhandene AFFiNE-Installation oder .env fehlt."
grep -Eq '"id"[[:space:]]*:[[:space:]]*"affine"' "$HOST_CONFIG" || fail "AFFiNE ist im zentralen MCP nicht registriert."
docker inspect affine-mcp >/dev/null 2>&1 || fail "Container affine-mcp wurde nicht gefunden."

TMP_ARCHIVE="$(mktemp)"; TMP_ROOT="$(mktemp -d)"; trap 'rm -f "$TMP_ARCHIVE"; rm -rf "$TMP_ROOT"' EXIT
curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || fail "Connector-Archiv konnte nicht geladen werden."
tar -xzf "$TMP_ARCHIVE" -C "$TMP_ROOT" --strip-components=2 --wildcards '*/affine/*' || fail "AFFiNE Connector konnte nicht entpackt werden."
NEW_APP="$TMP_ROOT/plugins/affine-connector"
[[ -f "$NEW_APP/docker-compose.yml" && -f "$NEW_APP/server.py" && -f "$NEW_APP/http_server.py" ]] || fail "Neue Connector-Dateien sind unvollständig."
cp "$APP_DIR/.env" "$TMP_ROOT/.env.keep"
rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
mv "$NEW_APP" "$APP_DIR"
mv "$TMP_ROOT/.env.keep" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build --force-recreate
for _ in {1..45}; do curl -fsS http://127.0.0.1:8104/health >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://127.0.0.1:8104/health >/dev/null || fail "AFFiNE Connector wurde nach Update nicht bereit."

systemctl restart bratonien-mcp.service
sleep 1
curl -fsS http://127.0.0.1:8000/health >/dev/null || fail "Zentraler MCP-Host ist nicht bereit."

APP_TOKEN="$(sed -n 's/^MCP_AFFINE_HTTP_TOKEN=//p' "$HOST_ENV" | head -n1)"
[[ -n "$APP_TOKEN" ]] || fail "MCP_AFFINE_HTTP_TOKEN fehlt in host.env."
TOOLS="$(curl -fsS -H "Authorization: Bearer $APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp)" || fail "tools/list über zentralen MCP fehlgeschlagen."
python3 - "$TOOLS" <<'PY' || fail "AFFiNE Tool-Oberfläche ist nach Update unvollständig."
import json,sys
data=json.loads(sys.argv[1]); names={str(t.get('name','')) for t in ((data.get('result') or {}).get('tools') or [])}
required={
    'affine__read_document','affine__doc_search','affine__create_document',
    'affine__update_document','affine__update_document_meta',
    'affine__trash_document','affine__restore_document','affine__delete_document'
}
if data.get('error') or not required.issubset(names) or any(not n.startswith('affine__') for n in names): raise SystemExit(1)
print('AFFiNE Tools:',len(names))
PY

echo "AFFiNE Connector aktualisiert und geprüft."
