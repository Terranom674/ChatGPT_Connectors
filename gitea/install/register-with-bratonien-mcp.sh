#!/usr/bin/env bash
set -Eeuo pipefail

HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/gitea"
APP_DIR="$CONNECTOR_ROOT/plugins/gitea-connector"
REPO_URL="https://github.com/Terranom674/ChatGPT_Connectors.git"
TTY=/dev/tty

fail() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Als root im Bratonien-MCP-LXC ausführen."
for cmd in git docker python3 openssl curl; do command -v "$cmd" >/dev/null || fail "$cmd wird benötigt."; done
[[ -r "$HOST_CONFIG" ]] || fail "Bratonien-MCP-Konfiguration fehlt: $HOST_CONFIG"
[[ -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Umgebung fehlt: $HOST_ENV"
[[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Konsole erkannt."

echo
echo "============================================================"
echo " Gitea Connector -> Bratonien MCP"
echo "============================================================"
echo "Der Connector wird separat installiert und anschließend beim"
echo "gemeinsamen MCP-Host registriert. Der öffentliche MCP bleibt"
echo "https://mcp.bratonien.de/mcp; Gitea erhält einen eigenen App-Token."

[[ ! -e "$CONNECTOR_ROOT" ]] || fail "Zielpfad $CONNECTOR_ROOT existiert bereits. Es wird nichts überschrieben oder gelöscht."

while true; do
  printf 'Gitea-Basis-URL (z. B. https://git.example.com): ' > "$TTY"
  read -r GITEA_URL < "$TTY"
  GITEA_URL="${GITEA_URL%/}"
  [[ -n "$GITEA_URL" ]] || continue
  [[ "$GITEA_URL" =~ ^https?:// ]] || GITEA_URL="https://$GITEA_URL"
  [[ "$GITEA_URL" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]] && break
  note "Ungültige Gitea-URL."
done

printf 'Gitea-Zugriffstoken: ' > "$TTY"
read -r -s GITEA_TOKEN < "$TTY"; echo > "$TTY"
[[ -n "$GITEA_TOKEN" ]] || fail "Gitea-Zugriffstoken darf nicht leer sein."

PUBLIC_MCP_URL="$(python3 - "$HOST_CONFIG" <<'PY'
import json,sys
with open(sys.argv[1], encoding='utf-8') as f:
    cfg=json.load(f)
print((cfg.get('oauth') or {}).get('resource',''))
PY
)"
[[ -n "$PUBLIC_MCP_URL" ]] || fail "Öffentliche MCP-URL fehlt in $HOST_CONFIG."

INTERNAL_TOKEN="$(openssl rand -hex 32)"
GITEA_APP_TOKEN="$(openssl rand -hex 32)"

echo "Gitea Connector wird installiert..."
TMP_CLONE="$(mktemp -d)"
trap 'rm -rf "$TMP_CLONE"' EXIT
git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TMP_CLONE/repo"
git -C "$TMP_CLONE/repo" sparse-checkout set gitea
mkdir -p "$CONNECTOR_ROOT"
cp -a "$TMP_CLONE/repo/gitea/." "$CONNECTOR_ROOT/"
rm -rf "$TMP_CLONE"
trap - EXIT
[[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Gitea-Connector wurde aus dem Sammel-Repository nicht vollständig übernommen."

cat > "$APP_DIR/.env" <<EOF
GITEA_URL=$GITEA_URL
GITEA_TOKEN=$GITEA_TOKEN
MCP_HTTP_TOKEN=$INTERNAL_TOKEN
MCP_TRUST_FORWARDED_BEARER=1
MCP_OAUTH_ISSUER=
MCP_RESOURCE_URL=
MCP_ALLOWED_ORIGINS=
MCP_PORT=8101
MCP_BIND_ADDRESS=127.0.0.1
EOF
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose up -d --build

for _ in {1..30}; do
  curl -fsS http://127.0.0.1:8101/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:8101/health >/dev/null || fail "Gitea Connector wurde nicht bereit."

python3 - "$HOST_CONFIG" "$GITEA_URL" <<'PY'
import json,sys,tempfile,os
path, issuer = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    cfg=json.load(f)
oauth=cfg.setdefault('oauth', {})
oauth.update({
    'issuer': issuer,
    'authorization_endpoint': issuer + '/login/oauth/authorize',
    'token_endpoint': issuer + '/login/oauth/access_token',
    'userinfo_endpoint': issuer + '/login/oauth/userinfo',
    'validation_url': issuer + '/login/oauth/userinfo',
    'jwks_uri': issuer + '/login/oauth/keys',
    'resource_documentation': 'https://github.com/Terranom674/ChatGPT_Connectors/tree/main/gitea',
    'response_types_supported': ['code'],
    'grant_types_supported': ['authorization_code', 'refresh_token'],
    'token_endpoint_auth_methods_supported': ['client_secret_post'],
    'code_challenge_methods_supported': ['S256'],
    'scopes_supported': [
        'write:repository', 'write:issue', 'read:user',
        'read:organization', 'read:package', 'read:notification'
    ]
})
connectors=[c for c in cfg.get('connectors', []) if c.get('id') != 'gitea']
connectors.append({
    'id': 'gitea',
    'enabled': True,
    'url': 'http://127.0.0.1:8101/mcp',
    'timeout_seconds': 30,
    'auth': {
        'mode': 'forward_bearer',
        'fallback_bearer_env': 'GITEA_CONNECTOR_HTTP_TOKEN'
    }
})
cfg['connectors']=connectors
host=cfg.setdefault('host', {})
access=[x for x in (host.get('access_tokens') or []) if isinstance(x,dict) and x.get('env') not in {'MCP_GITEA_HTTP_TOKEN','MCP_HTTP_TOKEN'}]
access.append({'env':'MCP_GITEA_HTTP_TOKEN','connectors':['gitea']})
access.append({'env':'MCP_HTTP_TOKEN','connectors':['gitea']})
host['access_tokens']=access
fd,tmp=tempfile.mkstemp(prefix='.config-', dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(cfg,f,indent=2)
        f.write('\n')
    os.chmod(tmp,0o600)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

python3 - "$HOST_ENV" "$INTERNAL_TOKEN" "$GITEA_APP_TOKEN" <<'PY'
import sys,os,tempfile
path,internal,app=sys.argv[1:]
replace={
    'GITEA_CONNECTOR_HTTP_TOKEN': internal,
    'MCP_GITEA_HTTP_TOKEN': app,
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
fd,tmp=tempfile.mkstemp(prefix='.hostenv-', dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f: f.writelines(lines)
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

systemctl restart bratonien-mcp.service
sleep 1
curl -fsS http://127.0.0.1:8000/health >/dev/null || fail "MCP-Host ist nach Registrierung nicht bereit."

TOOLS_RESPONSE="$(curl -fsS -H "Authorization: Bearer $GITEA_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp)" || fail "tools/list über den MCP-Host fehlgeschlagen."
python3 - "$TOOLS_RESPONSE" <<'PY' || fail "Gitea-Namespace ist über den MCP-Host nicht korrekt getrennt."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error'): raise SystemExit(1)
tools=((data.get('result') or {}).get('tools') or [])
names=[str(t.get('name','')) for t in tools]
if 'gitea__list_repositories' not in names: raise SystemExit(1)
if any(not name.startswith('gitea__') for name in names): raise SystemExit(1)
PY

READ_RESPONSE="$(curl -fsS -H "Authorization: Bearer $GITEA_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gitea__list_repositories","arguments":{"page":1,"limit":1}}}' http://127.0.0.1:8000/mcp)" || fail "Read-only Gitea-Smoke-Test über den MCP-Host fehlgeschlagen."
python3 - "$READ_RESPONSE" <<'PY' || fail "Read-only Gitea-Smoke-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True: raise SystemExit(1)
PY

CROSS_RESPONSE="$(curl -fsS -H "Authorization: Bearer $GITEA_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"manifold__whoami","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Cross-Namespace-Test konnte nicht ausgeführt werden."
python3 - "$CROSS_RESPONSE" <<'PY' || fail "Gitea-App-Token kann unerwartet auf Manifold zugreifen."
import json,sys
data=json.loads(sys.argv[1])
err=data.get('error') or {}
if err.get('code') != -32602: raise SystemExit(1)
PY

echo
echo "============================================================"
echo " Gitea Connector registriert und geprüft"
echo "============================================================"
echo "Interner Connector: http://127.0.0.1:8101/mcp"
echo "Öffentlicher MCP:   $PUBLIC_MCP_URL"
echo "Namespace:          gitea__"
echo "App-Token-Variable: MCP_GITEA_HTTP_TOKEN"
echo "OAuth-Issuer:       $GITEA_URL"
echo "tools/list:         nur Gitea"
echo "Cross-Namespace:    blockiert"
echo "Read-only API-Test: erfolgreich"
echo
echo "Der eigentliche App-Token steht geschützt in $HOST_ENV."
echo "Für ChatGPT die Variable MCP_GITEA_HTTP_TOKEN verwenden."
