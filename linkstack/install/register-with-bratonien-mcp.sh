#!/usr/bin/env bash
set -Eeuo pipefail

SELF_URL="https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/linkstack/install/register-with-bratonien-mcp.sh"
HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
CONNECTOR_ROOT="/opt/connectors/linkstack"
APP_DIR="$CONNECTOR_ROOT/plugins/linkstack-connector"
ARCHIVE_URL="https://codeload.github.com/Terranom674/ChatGPT_Connectors/tar.gz/refs/heads/main"
COMPOSE_PROJECT="bratonien-linkstack-connector"
LINKSTACK_APP_NAME="Bratonien ChatGPT / LinkStack Connector"
LINKSTACK_TOKEN_NAME="Bratonien MCP Connector"
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

prompt_linkstack_lxc() {
  local ctid
  while true; do
    ctid="$(prompt_ctid 'CT-ID des LinkStack-LXC: ')"
    pct exec "$ctid" -- sh -lc 'command -v docker >/dev/null 2>&1 && docker inspect linkstack >/dev/null 2>&1' >/dev/null 2>&1 || {
      note "CT $ctid enthält keinen LinkStack-Container namens linkstack."
      continue
    }
    pct exec "$ctid" -- docker exec linkstack test -r /htdocs/app/Models/BratonienApiApplication.php >/dev/null 2>&1 || {
      note "Die Bratonien-LinkStack-API ist in CT $ctid nicht installiert oder noch nicht vollständig."
      continue
    }
    printf '%s' "$ctid"
    return 0
  done
}

prompt_linkstack_url() {
  local value
  while true; do
    printf 'Öffentliche LinkStack-URL (z. B. links.bratonien.de): ' > "$TTY"
    read -r value < "$TTY"
    LINKSTACK_URL="$(normalize_https_url "$value")" || { note "Bitte eine gültige HTTPS-URL eingeben."; continue; }
    return 0
  done
}

preflight_public_api() {
  local out status
  out="$(mktemp)"
  status="$(curl -sS --max-time 20 -o "$out" -w '%{http_code}' -H 'Accept: application/json' "$LINKSTACK_URL/api/v1/status" || true)"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$out"
    note "LinkStack API-Status ist über $LINKSTACK_URL fehlgeschlagen (HTTP ${status:-keine Verbindung})."
    return 1
  fi
  python3 - "$out" <<'PY' || { rm -f "$out"; note "LinkStack /api/v1/status liefert nicht den erwarteten Bratonien-API-Status."; return 1; }
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:
    data=json.load(f)
if not isinstance(data,dict) or data.get('module') != 'bratonien-linkstack-api':
    raise SystemExit(1)
PY
  rm -f "$out"
  note "Öffentliche Bratonien-LinkStack-API erfolgreich erkannt."
}

provision_linkstack_token() {
  local ctid="$1" host_php remote_php output token
  host_php="$(mktemp)"
  remote_php="/root/.bratonien-linkstack-connector-provision.php"
  umask 077
  cat > "$host_php" <<'PHP'
<?php
require '/htdocs/vendor/autoload.php';
$app = require '/htdocs/bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

use App\Models\BratonienApiApplication;
use App\Models\BratonienApiPermission;
use App\Models\BratonienApiToken;
use Illuminate\Support\Str;

$name = getenv('BRATONIEN_CONNECTOR_APP_NAME') ?: 'Bratonien ChatGPT / LinkStack Connector';
$tokenName = getenv('BRATONIEN_CONNECTOR_TOKEN_NAME') ?: 'Bratonien MCP Connector';

$application = BratonienApiApplication::where('name', $name)->first();
if (!$application) {
    $application = BratonienApiApplication::create([
        'name' => $name,
        'description' => 'Automatisch provisionierter Zugriff des zentralen Bratonien-MCP auf LinkStack.',
        'active' => true,
        'resource_scope' => 'all',
        'owner_user_id' => null,
    ]);
} else {
    $application->forceFill(['active' => true])->save();
}

$permissions = [
    'system.status' => 'read',
    'system.diagnostics' => 'read',
    'profile.metadata' => 'write',
    'links.links' => 'write',
    'links.ordering' => 'write',
    'links.types' => 'read',
    'links.buttons' => 'read',
    'links.pinning' => 'write',
    'links.styling' => 'write',
    'appearance.theme' => 'write',
    'appearance.assets' => 'write',
    'appearance.social-icons' => 'write',
    'themes.manage' => 'write',
    'analytics.page' => 'read',
    'analytics.links' => 'read',
    'analytics.instance' => 'read',
    'users.users' => 'write',
    'users.status' => 'write',
    'users.roles' => 'write',
    'instance.pages' => 'write',
    'instance.general' => 'write',
    'instance.registration' => 'write',
    'instance.domains' => 'write',
    'instance.mail' => 'write',
    'instance.security' => 'write',
    'instance.features' => 'write',
    'instance.maintenance' => 'write',
    'instance.logging' => 'write',
    'instance.advanced-config' => 'write',
    'instance.import' => 'write',
    'instance.export' => 'write',
    'backups.metadata' => 'read',
    'backups.create' => 'write',
    'backups.restore' => 'write',
    'backups.delete' => 'write',
    'mail.test' => 'write',
    'reports.submit' => 'write',
    'api.applications' => 'write',
    'api.tokens' => 'write',
    'api.audit' => 'read',
];

foreach ($permissions as $permission => $level) {
    BratonienApiPermission::updateOrCreate(
        ['application_id' => $application->id, 'permission' => $permission],
        ['level' => $level]
    );
}

BratonienApiToken::where('application_id', $application->id)
    ->where('name', $tokenName)
    ->whereNull('revoked_at')
    ->update(['revoked_at' => now()]);

$plain = 'ls_' . Str::random(64);
BratonienApiToken::create([
    'application_id' => $application->id,
    'name' => $tokenName,
    'prefix' => substr($plain, 0, 12),
    'token_hash' => hash('sha256', $plain),
]);

echo $plain;
PHP

  pct push "$ctid" "$host_php" "$remote_php" >/dev/null || { rm -f "$host_php"; fail "Provisionierungsskript konnte nicht in den LinkStack-LXC übertragen werden."; }
  pct exec "$ctid" -- chmod 600 "$remote_php" >/dev/null
  pct exec "$ctid" -- docker cp "$remote_php" linkstack:/tmp/bratonien-linkstack-connector-provision.php >/dev/null || {
    pct exec "$ctid" -- rm -f "$remote_php" >/dev/null 2>&1 || true
    rm -f "$host_php"
    fail "Provisionierungsskript konnte nicht in den LinkStack-Container übertragen werden."
  }
  output="$(pct exec "$ctid" -- docker exec --user 0:0 \
      -e "BRATONIEN_CONNECTOR_APP_NAME=$LINKSTACK_APP_NAME" \
      -e "BRATONIEN_CONNECTOR_TOKEN_NAME=$LINKSTACK_TOKEN_NAME" \
      linkstack php /tmp/bratonien-linkstack-connector-provision.php)" || {
    pct exec "$ctid" -- docker exec --user 0:0 linkstack rm -f /tmp/bratonien-linkstack-connector-provision.php >/dev/null 2>&1 || true
    pct exec "$ctid" -- rm -f "$remote_php" >/dev/null 2>&1 || true
    rm -f "$host_php"
    fail "LinkStack konnte die Connector-Application nicht provisionieren."
  }
  pct exec "$ctid" -- docker exec --user 0:0 linkstack rm -f /tmp/bratonien-linkstack-connector-provision.php >/dev/null 2>&1 || true
  pct exec "$ctid" -- rm -f "$remote_php" >/dev/null 2>&1 || true
  rm -f "$host_php"

  token="$(printf '%s' "$output" | tr -d '\r\n')"
  [[ "$token" == ls_* ]] || fail "LinkStack hat keinen gültigen Connector-Token erzeugt."
  LINKSTACK_TOKEN="$token"
  note "LinkStack API-Application '$LINKSTACK_APP_NAME' und Connector-Token wurden automatisch provisioniert."
}

verify_linkstack_token() {
  local out status
  out="$(mktemp)"
  status="$(curl -sS --max-time 20 -o "$out" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer $LINKSTACK_TOKEN" \
    "$LINKSTACK_URL/api/v1/me" || true)"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$out"
    note "Der automatisch erzeugte LinkStack-Token wurde über die öffentliche API abgelehnt (HTTP ${status:-keine Verbindung})."
    return 1
  fi
  python3 - "$out" "$LINKSTACK_APP_NAME" <<'PY' || { rm -f "$out"; note "LinkStack /api/v1/me meldet nicht die erwartete Connector-Application."; return 1; }
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:
    data=json.load(f)
app=data.get('application') or {}
if app.get('name') != sys.argv[2] or app.get('active') is False:
    raise SystemExit(1)
PY
  rm -f "$out"
  note "Automatisch erzeugter LinkStack-Token erfolgreich über HTTPS geprüft."
}

ensure_not_registered() {
  local ctid="$1"
  if pct exec "$ctid" -- grep -Eq '"id"[[:space:]]*:[[:space:]]*"linkstack"' "$HOST_CONFIG"; then
    fail "Eine LinkStack-Connector-Installation ist bereits am zentralen MCP registriert."
  fi
}

run_from_proxmox() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "In der Proxmox-Shell als root ausführen."
  [[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Proxmox-Konsole erkannt."
  local cmd mcp_ctid linkstack_ctid tmp_input remote_input rc
  for cmd in pct base64 tr mktemp curl python3 rm; do command -v "$cmd" >/dev/null || fail "$cmd wird auf dem Proxmox-Host benötigt."; done

  mcp_ctid="$(prompt_mcp_lxc)"
  note "Verwende MCP-LXC CT $mcp_ctid."
  ensure_not_registered "$mcp_ctid"

  linkstack_ctid="$(prompt_linkstack_lxc)"
  note "Verwende LinkStack-LXC CT $linkstack_ctid."
  [[ "$mcp_ctid" != "$linkstack_ctid" ]] || fail "MCP-LXC und LinkStack-LXC dürfen nicht dieselbe CT-ID haben."

  prompt_linkstack_url
  preflight_public_api || fail "Die öffentliche Bratonien-LinkStack-API ist nicht erreichbar oder nicht vollständig installiert."
  provision_linkstack_token "$linkstack_ctid"
  verify_linkstack_token || fail "Der automatisch provisionierte LinkStack-Zugang funktioniert nicht über die öffentliche HTTPS-API."

  tmp_input="$(mktemp)"
  remote_input="/root/.linkstack-connector-install-input"
  trap 'rm -f "$tmp_input"' EXIT
  umask 077
  {
    printf 'LINKSTACK_URL_B64=%s\n' "$(b64 "$LINKSTACK_URL")"
    printf 'LINKSTACK_TOKEN_B64=%s\n' "$(b64 "$LINKSTACK_TOKEN")"
  } > "$tmp_input"

  pct push "$mcp_ctid" "$tmp_input" "$remote_input" >/dev/null || fail "Installationsdaten konnten nicht in den MCP-LXC übertragen werden."
  pct exec "$mcp_ctid" -- chmod 600 "$remote_input" >/dev/null

  set +e
  pct exec "$mcp_ctid" -- env LINKSTACK_INSTALL_INPUT="$remote_input" bash -lc "bash <(curl -fsSL '$SELF_URL')"
  rc=$?
  set -e

  pct exec "$mcp_ctid" -- rm -f "$remote_input" >/dev/null 2>&1 || true
  rm -f "$tmp_input"
  trap - EXIT
  return "$rc"
}

read_transferred_credentials() {
  local input="$LINKSTACK_INSTALL_INPUT" value
  [[ -r "$input" ]] || fail "Übertragene Installationsdaten fehlen im MCP-LXC."
  value="$(sed -n 's/^LINKSTACK_URL_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "LinkStack-URL fehlt."; LINKSTACK_URL="$(printf '%s' "$value" | base64 -d)"
  value="$(sed -n 's/^LINKSTACK_TOKEN_B64=//p' "$input" | head -n1)"; [[ -n "$value" ]] || fail "LinkStack-Token fehlt."; LINKSTACK_TOKEN="$(printf '%s' "$value" | base64 -d)"
}

preflight_from_mcp_lxc() {
  local status
  status="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer $LINKSTACK_TOKEN" \
    "$LINKSTACK_URL/api/v1/me" || true)"
  [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

prepare_connector_path() {
  local backup_path
  if grep -Eq '"id"[[:space:]]*:[[:space:]]*"linkstack"' "$HOST_CONFIG"; then
    fail "Eine LinkStack-Connector-Installation ist bereits am zentralen MCP registriert."
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx 'linkstack-mcp'; then
    docker rm -f linkstack-mcp >/dev/null || fail "Der unvollständige LinkStack-Connector-Container konnte nicht entfernt werden."
  fi
  [[ -e "$CONNECTOR_ROOT" ]] || return 0
  backup_path="${CONNECTOR_ROOT}.failed-$(date +%Y%m%d-%H%M%S)"
  mv "$CONNECTOR_ROOT" "$backup_path" || fail "Unvollständige vorherige Installation konnte nicht gesichert werden."
  note "Unvollständiger vorheriger Installationsversuch wurde erhalten unter: $backup_path"
}

if command -v pct >/dev/null 2>&1 && [[ -z "${LINKSTACK_INSTALL_INPUT:-}" ]]; then
  run_from_proxmox
  exit $?
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Als root im Bratonien-MCP-LXC ausführen."
for cmd in docker python3 openssl curl tar base64 sed head grep mv date mktemp rm systemctl; do command -v "$cmd" >/dev/null || fail "$cmd wird im MCP-LXC benötigt."; done
[[ -r "$HOST_CONFIG" ]] || fail "Bratonien-MCP-Konfiguration fehlt: $HOST_CONFIG"
[[ -r "$HOST_ENV" ]] || fail "Bratonien-MCP-Umgebung fehlt: $HOST_ENV"
[[ -n "${LINKSTACK_INSTALL_INPUT:-}" ]] || fail "Dieser Installer wird aus der Proxmox-Host-Shell gestartet; direkte Token-Eingabe im MCP-LXC ist nicht vorgesehen."

read_transferred_credentials
[[ "$LINKSTACK_URL" =~ ^https:// ]] || fail "Die übertragene LinkStack-URL ist keine HTTPS-URL."
[[ "$LINKSTACK_TOKEN" == ls_* ]] || fail "Der automatisch erzeugte LinkStack-Token ist ungültig."
preflight_from_mcp_lxc || fail "Der automatisch provisionierte LinkStack-Zugang funktioniert aus dem MCP-LXC nicht über HTTPS."

prepare_connector_path

INTERNAL_TOKEN="$(openssl rand -hex 32)"
LINKSTACK_APP_TOKEN="$(openssl rand -hex 32)"
TMP_ARCHIVE="$(mktemp)"
trap 'rm -f "$TMP_ARCHIVE"' EXIT
mkdir -p "$CONNECTOR_ROOT"
curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || fail "Connector-Archiv konnte nicht von GitHub geladen werden."
tar -xzf "$TMP_ARCHIVE" -C "$CONNECTOR_ROOT" --strip-components=2 --wildcards '*/linkstack/*' || fail "Connector-Archiv konnte nicht entpackt werden."
[[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Connector-Dateien wurden nicht vollständig entpackt."
[[ -f "$APP_DIR/operations.py" && -f "$APP_DIR/management_surface.py" && -f "$APP_DIR/server.py" ]] || fail "LinkStack-Tool-Oberfläche fehlt im Connector-Archiv."

umask 077
cat > "$APP_DIR/.env" <<EOF
LINKSTACK_URL=$LINKSTACK_URL
LINKSTACK_TOKEN=$LINKSTACK_TOKEN
MCP_HTTP_TOKEN=$INTERNAL_TOKEN
MCP_BIND_ADDRESS=127.0.0.1
MCP_PORT=8103
MCP_CONTAINER_NAME=linkstack-mcp
EOF
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build
for _ in {1..45}; do
  curl -fsS http://127.0.0.1:8103/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:8103/health >/dev/null || fail "LinkStack Connector wurde nicht bereit."

ME="$(curl -fsS -H "Authorization: Bearer $INTERNAL_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"me","arguments":{}}}' http://127.0.0.1:8103/mcp)" || fail "LinkStack me-Test fehlgeschlagen."
python3 - "$ME" <<'PY' || fail "LinkStack me-Test meldete einen Fehler."
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
connectors=[c for c in cfg.get('connectors',[]) if c.get('id') != 'linkstack']
connectors.append({'id':'linkstack','enabled':True,'url':'http://127.0.0.1:8103/mcp','timeout_seconds':30,'auth':{'mode':'service_token','bearer_env':'LINKSTACK_CONNECTOR_HTTP_TOKEN'}})
cfg['connectors']=connectors
host=cfg.setdefault('host',{})
access=[x for x in (host.get('access_tokens') or []) if isinstance(x,dict) and x.get('env') != 'MCP_LINKSTACK_HTTP_TOKEN']
access.append({'env':'MCP_LINKSTACK_HTTP_TOKEN','connectors':['linkstack']})
host['access_tokens']=access
fd,tmp=tempfile.mkstemp(prefix='.config-',dir=os.path.dirname(path),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(cfg,f,indent=2); f.write('\n')
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

python3 - "$HOST_ENV" "$INTERNAL_TOKEN" "$LINKSTACK_APP_TOKEN" <<'PY'
import sys,os,tempfile
path,internal,app=sys.argv[1:]
replace={'LINKSTACK_CONNECTOR_HTTP_TOKEN':internal,'MCP_LINKSTACK_HTTP_TOKEN':app}
lines=[]; seen=set()
if os.path.exists(path):
    with open(path,encoding='utf-8') as f:
        for line in f:
            if '=' in line and not line.lstrip().startswith('#'):
                key=line.split('=',1)[0].strip()
                if key in replace:
                    if key not in seen:
                        lines.append(key+'='+replace[key]+'\n'); seen.add(key)
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
curl -fsS -H "Authorization: Bearer $LINKSTACK_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' http://127.0.0.1:8000/mcp > "$TOOLS_FILE" || fail "tools/list über den zentralen Host fehlgeschlagen."
TOOL_COUNT="$(python3 - "$TOOLS_FILE" "$APP_DIR" <<'PY'
import importlib.util,json,os,sys
payload_path,app=sys.argv[1],sys.argv[2]
with open(payload_path,encoding='utf-8') as f: data=json.load(f)
if data.get('error'): raise SystemExit(1)
all_names=[str(t.get('name','')) for t in ((data.get('result') or {}).get('tools') or [])]
if any(not name.startswith('linkstack__') for name in all_names): raise SystemExit(1)
names=set(all_names)
spec=importlib.util.spec_from_file_location('management_surface',os.path.join(app,'management_surface.py'))
mod=importlib.util.module_from_spec(spec); sys.path.insert(0,app); spec.loader.exec_module(mod)
required={'linkstack__'+name for name in mod.REQUIRED_MANAGEMENT_TOOLS}
if not required.issubset(names):
    print('Fehlende Tools: '+', '.join(sorted(required-names)),file=sys.stderr); raise SystemExit(1)
print(len(names))
PY
)" || fail "LinkStack-Verwaltungsoberfläche ist über den zentralen Host nicht vollständig oder nicht sauber getrennt sichtbar."
rm -f "$TOOLS_FILE"

READ="$(curl -fsS -H "Authorization: Bearer $LINKSTACK_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"linkstack__me","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "LinkStack-Test über den zentralen Host fehlgeschlagen."
python3 - "$READ" <<'PY' || fail "LinkStack-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY

CROSS="$(curl -fsS -H "Authorization: Bearer $LINKSTACK_APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"manifold__whoami","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Cross-Namespace-Test konnte nicht ausgeführt werden."
python3 - "$CROSS" <<'PY' || fail "LinkStack-App-Token kann unerwartet auf Manifold zugreifen."
import json,sys
data=json.loads(sys.argv[1])
err=data.get('error') or {}
if err.get('code') != -32602:
    raise SystemExit(1)
PY

echo
echo "============================================================"
echo " LinkStack Connector registriert und geprüft"
echo "============================================================"
echo "LinkStack API:       $LINKSTACK_URL"
echo "API Application:     $LINKSTACK_APP_NAME"
echo "Interner Connector:  http://127.0.0.1:8103/mcp"
echo "Namespace:           linkstack__"
echo "App-Token-Variable:  MCP_LINKSTACK_HTTP_TOKEN"
echo "LinkStack-Tools:      $TOOL_COUNT"
echo "Token-Provisioning:  automatisch"
echo "me:                  erfolgreich"
echo "Cross-Namespace:     blockiert"
echo
echo "Der LinkStack-API-Token liegt ausschließlich geschützt in $APP_DIR/.env."
echo "Der eigentliche MCP-App-Token steht geschützt in $HOST_ENV."