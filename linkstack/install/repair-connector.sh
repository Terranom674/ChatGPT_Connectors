#!/usr/bin/env bash
set -Eeuo pipefail

HOST_CONFIG="/etc/bratonien-mcp/config.json"
HOST_ENV="/etc/bratonien-mcp/host.env"
APP_DIR="/opt/connectors/linkstack/plugins/linkstack-connector"
COMPOSE_PROJECT="bratonien-linkstack-connector"
TTY=/dev/tty

fail() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

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

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "In der Proxmox-Shell als root ausführen."
[[ -r "$TTY" && -w "$TTY" ]] || fail "Keine interaktive Proxmox-Konsole erkannt."
for cmd in pct mktemp base64 tr rm grep sed head; do command -v "$cmd" >/dev/null || fail "$cmd wird auf dem Proxmox-Host benötigt."; done

MCP_CT="$(prompt_ctid 'CT-ID des bestehenden MCP-LXC: ')"
pct exec "$MCP_CT" -- test -r "$HOST_CONFIG" >/dev/null 2>&1 || fail "CT $MCP_CT enthält keine Bratonien-MCP-Konfiguration."
pct exec "$MCP_CT" -- test -r "$HOST_ENV" >/dev/null 2>&1 || fail "CT $MCP_CT enthält keine Bratonien-MCP-Umgebung."
pct exec "$MCP_CT" -- test -r "$APP_DIR/.env" >/dev/null 2>&1 || fail "Die bestehende LinkStack-Connector-.env fehlt."
pct exec "$MCP_CT" -- grep -Eq '"id"[[:space:]]*:[[:space:]]*"linkstack"' "$HOST_CONFIG" || fail "LinkStack ist am zentralen MCP nicht registriert."

LINKSTACK_CT="$(prompt_ctid 'CT-ID des LinkStack-LXC: ')"
[[ "$MCP_CT" != "$LINKSTACK_CT" ]] || fail "MCP-LXC und LinkStack-LXC dürfen nicht dieselbe CT-ID haben."
pct exec "$LINKSTACK_CT" -- sh -lc 'command -v docker >/dev/null 2>&1 && docker inspect linkstack >/dev/null 2>&1' >/dev/null 2>&1 || fail "CT $LINKSTACK_CT enthält keinen LinkStack-Container namens linkstack."
pct exec "$LINKSTACK_CT" -- docker exec linkstack test -r /htdocs/app/Models/BratonienApiApplication.php >/dev/null 2>&1 || fail "Die Bratonien-LinkStack-API ist in CT $LINKSTACK_CT nicht vollständig installiert."

LINKSTACK_URL="$(pct exec "$MCP_CT" -- sh -lc "sed -n 's/^LINKSTACK_URL=//p' '$APP_DIR/.env' | head -n1")"
[[ "$LINKSTACK_URL" =~ ^https:// ]] || fail "LINKSTACK_URL fehlt oder ist ungültig in der bestehenden Connector-.env."
note "Verwende bestehende LinkStack-URL: $LINKSTACK_URL"

HOST_PHP="$(mktemp)"
REMOTE_PHP="/root/.bratonien-linkstack-mcp-repair.php"
umask 077
cat > "$HOST_PHP" <<'PHP'
<?php
require '/htdocs/vendor/autoload.php';
$app = require '/htdocs/bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

use App\Models\BratonienApiApplication;
use App\Models\BratonienApiPermission;
use App\Models\BratonienApiToken;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

$name = 'MCP-Server';
$tokenName = 'MCP-Server';
$application = BratonienApiApplication::whereIn('name', [
    $name,
    'LinkStack MCP-Server',
    'Bratonien ChatGPT / LinkStack Connector',
    'ChatGPT-Integration',
    'LinkStack-Connectorzugang',
    'MCP-Server-Zugang',
])->first();

if (!$application) {
    $application = BratonienApiApplication::create([
        'name' => $name,
        'description' => 'API-Zugang des zentralen MCP-Servers zu LinkStack. Rechte und Scope werden in LinkStack verwaltet.',
        'active' => true,
        'resource_scope' => 'all',
        'owner_user_id' => null,
    ]);
} else {
    $values = [
        'name' => $name,
        'description' => 'API-Zugang des zentralen MCP-Servers zu LinkStack. Rechte und Scope werden in LinkStack verwaltet.',
        'active' => true,
        'resource_scope' => 'all',
        'owner_user_id' => null,
    ];
    if (Schema::hasColumn('bratonien_api_applications', 'system_managed')) {
        $values['system_managed'] = false;
    }
    $application->forceFill($values)->save();
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
    ->whereIn('name', [$tokenName, 'Bratonien MCP Connector', 'Connector -> LinkStack', 'MCP-Server -> LinkStack'])
    ->whereNull('revoked_at')
    ->update(['revoked_at' => now()]);

$plain = 'ls_' . Str::random(64);
$values = [
    'application_id' => $application->id,
    'name' => $tokenName,
    'prefix' => substr($plain, 0, 12),
    'token_hash' => hash('sha256', $plain),
];
if (Schema::hasColumn('bratonien_api_tokens', 'token_ciphertext')) {
    $values['token_ciphertext'] = Crypt::encryptString($plain);
}
BratonienApiToken::create($values);
echo $plain;
PHP

pct push "$LINKSTACK_CT" "$HOST_PHP" "$REMOTE_PHP" >/dev/null || { rm -f "$HOST_PHP"; fail "Reparaturskript konnte nicht in den LinkStack-LXC übertragen werden."; }
pct exec "$LINKSTACK_CT" -- chmod 600 "$REMOTE_PHP" >/dev/null
NEW_TOKEN="$(pct exec "$LINKSTACK_CT" -- bash -lc "cat '$REMOTE_PHP' | docker exec -i --user 0:0 linkstack php")" || {
  pct exec "$LINKSTACK_CT" -- rm -f "$REMOTE_PHP" >/dev/null 2>&1 || true
  rm -f "$HOST_PHP"
  fail "Neuer LinkStack-MCP-API-Key konnte nicht erzeugt werden."
}
pct exec "$LINKSTACK_CT" -- rm -f "$REMOTE_PHP" >/dev/null 2>&1 || true
rm -f "$HOST_PHP"
NEW_TOKEN="$(printf '%s' "$NEW_TOKEN" | tr -d '\r\n')"
[[ "$NEW_TOKEN" == ls_* ]] || fail "LinkStack hat keinen gültigen neuen API-Key erzeugt."

TMP_TOKEN="$(mktemp)"
printf '%s' "$NEW_TOKEN" > "$TMP_TOKEN"
REMOTE_TOKEN="/root/.linkstack-repair-token"
pct push "$MCP_CT" "$TMP_TOKEN" "$REMOTE_TOKEN" >/dev/null || { rm -f "$TMP_TOKEN"; fail "Neuer API-Key konnte nicht in den MCP-LXC übertragen werden."; }
rm -f "$TMP_TOKEN"
pct exec "$MCP_CT" -- chmod 600 "$REMOTE_TOKEN" >/dev/null

pct exec "$MCP_CT" -- env LINKSTACK_REPAIR_TOKEN_FILE="$REMOTE_TOKEN" bash -s <<'INNER'
set -Eeuo pipefail
APP_DIR="/opt/connectors/linkstack/plugins/linkstack-connector"
COMPOSE_PROJECT="bratonien-linkstack-connector"
HOST_ENV="/etc/bratonien-mcp/host.env"
fail() { echo "FEHLER: $*" >&2; exit 1; }

for cmd in docker curl sed head python3 systemctl; do command -v "$cmd" >/dev/null || fail "$cmd wird im MCP-LXC benötigt."; done
[[ -r "$APP_DIR/.env" ]] || fail "LinkStack-Connector-.env fehlt."
[[ -r "$LINKSTACK_REPAIR_TOKEN_FILE" ]] || fail "Übertragener Reparatur-Key fehlt."
NEW_TOKEN="$(cat "$LINKSTACK_REPAIR_TOKEN_FILE")"
rm -f "$LINKSTACK_REPAIR_TOKEN_FILE"
[[ "$NEW_TOKEN" == ls_* ]] || fail "Übertragener Reparatur-Key ist ungültig."

python3 - "$APP_DIR/.env" "$NEW_TOKEN" <<'PY'
import os,sys,tempfile
path,token=sys.argv[1:]
lines=[]; seen=False
with open(path,encoding='utf-8') as f:
    for line in f:
        if line.startswith('LINKSTACK_TOKEN='):
            if not seen:
                lines.append('LINKSTACK_TOKEN='+token+'\n'); seen=True
        else:
            lines.append(line)
if not seen:
    lines.append('LINKSTACK_TOKEN='+token+'\n')
fd,tmp=tempfile.mkstemp(prefix='.env-',dir=os.path.dirname(path),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f: f.writelines(lines)
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

cd "$APP_DIR"
docker compose -p "$COMPOSE_PROJECT" up -d --build
for _ in {1..45}; do
  curl -fsS http://127.0.0.1:8103/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:8103/health >/dev/null || fail "LinkStack-MCP-Dienst wurde nach Token-Reparatur nicht bereit."

INTERNAL_TOKEN="$(sed -n 's/^MCP_HTTP_TOKEN=//p' "$APP_DIR/.env" | head -n1)"
[[ -n "$INTERNAL_TOKEN" ]] || fail "MCP_HTTP_TOKEN fehlt."
LOCAL="$(curl -fsS -H "Authorization: Bearer $INTERNAL_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"system_diagnostics","arguments":{}}}' http://127.0.0.1:8103/mcp)" || fail "Lokaler Diagnostics-Test fehlgeschlagen."
python3 - "$LOCAL" <<'PY' || fail "Lokaler Diagnostics-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY

systemctl restart bratonien-mcp.service
sleep 1
curl -fsS http://127.0.0.1:8000/health >/dev/null || fail "Zentraler MCP ist nach Reparatur nicht bereit."
APP_TOKEN="$(sed -n 's/^MCP_LINKSTACK_HTTP_TOKEN=//p' "$HOST_ENV" | head -n1)"
[[ -n "$APP_TOKEN" ]] || fail "MCP_LINKSTACK_HTTP_TOKEN fehlt."
CENTRAL="$(curl -fsS -H "Authorization: Bearer $APP_TOKEN" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"linkstack__system_diagnostics","arguments":{}}}' http://127.0.0.1:8000/mcp)" || fail "Zentraler Diagnostics-Test fehlgeschlagen."
python3 - "$CENTRAL" <<'PY' || fail "Zentraler Diagnostics-Test meldete einen Fehler."
import json,sys
data=json.loads(sys.argv[1])
if data.get('error') or (data.get('result') or {}).get('isError') is True:
    raise SystemExit(1)
PY
INNER

echo
echo "============================================================"
echo " LinkStack-Connector-Zugang repariert"
echo "============================================================"
echo "MCP-LXC:               CT $MCP_CT"
echo "LinkStack-LXC:         CT $LINKSTACK_CT"
echo "API-Anwendung:         MCP-Server"
echo "API-Key:               neu provisioniert"
echo "system_diagnostics:    erfolgreich"
echo "MCP-Registrierung:     beibehalten"
echo
