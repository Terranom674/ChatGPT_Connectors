#!/usr/bin/env bash
set -Eeuo pipefail

TTY="/dev/tty"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run this helper as root inside the Gitea MCP LXC."
for cmd in curl python3 sed; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done
[[ -r "$TTY" && -w "$TTY" ]] || fail "No interactive terminal detected."

APP_ENV=""
for candidate in \
  /opt/connectors/gitea/plugins/gitea-connector/.env \
  /opt/gitea-connector/plugins/gitea-connector/.env; do
  if [[ -r "$candidate" ]]; then
    APP_ENV="$candidate"
    break
  fi
done
[[ -n "$APP_ENV" ]] || fail "Gitea connector environment file not found in shared-host or legacy location."

GITEA_URL="$(sed -n 's/^GITEA_URL=//p' "$APP_ENV" | head -n1)"
GITEA_TOKEN="$(sed -n 's/^GITEA_TOKEN=//p' "$APP_ENV" | head -n1)"

[[ -n "$GITEA_URL" ]] || fail "GITEA_URL is missing from $APP_ENV"
[[ -n "$GITEA_TOKEN" ]] || fail "GITEA_TOKEN is missing from $APP_ENV"
GITEA_URL="${GITEA_URL%/}"

echo
echo "============================================================"
echo " Gitea MCP - ChatGPT OAuth setup"
echo "============================================================"
echo "This helper creates the Gitea OAuth2 application after ChatGPT"
echo "has shown the callback/redirect URL for this MCP connection."
echo
echo "It does not change the MCP container or tunnel configuration."
echo "It creates one new OAuth2 application in Gitea."
echo "Connector environment: $APP_ENV"

echo
while true; do
  printf 'ChatGPT callback/redirect URL: ' > "$TTY"
  read -r CALLBACK_URL < "$TTY"
  if [[ "$CALLBACK_URL" =~ ^https://[^[:space:]]+$ ]]; then
    break
  fi
  echo "Enter the exact HTTPS callback URL shown by ChatGPT." >&2
done

printf 'OAuth application name [ChatGPT Gitea MCP]: ' > "$TTY"
read -r APP_NAME < "$TTY"
APP_NAME="${APP_NAME:-ChatGPT Gitea MCP}"

PAYLOAD="$(python3 - "$APP_NAME" "$CALLBACK_URL" <<'PY'
import json
import sys
name = sys.argv[1]
callback = sys.argv[2]
print(json.dumps({
    "confidential_client": True,
    "name": name,
    "redirect_uris": [callback],
    "skip_secondary_authorization": False,
}))
PY
)"

echo
echo "Creating OAuth2 application in: $GITEA_URL"
RESPONSE="$(curl --fail-with-body -sS \
  --request POST \
  --url "$GITEA_URL/api/v1/user/applications/oauth2" \
  --header "Authorization: token $GITEA_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "$PAYLOAD")" || fail "Gitea rejected the OAuth2 application creation request."

python3 - "$RESPONSE" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
client_id = data.get("client_id")
client_secret = data.get("client_secret")
app_id = data.get("id")
name = data.get("name")
redirects = data.get("redirect_uris") or []
if not client_id or not client_secret:
    raise SystemExit("Gitea response did not contain client_id and client_secret.")
print()
print("============================================================")
print(" OAuth2 application created")
print("============================================================")
print(f"Application:    {name}")
print(f"Application ID: {app_id if app_id is not None else 'unknown'}")
print(f"Redirect URI:   {redirects[0] if redirects else 'unknown'}")
print()
print(f"Client ID:      {client_id}")
print(f"Client Secret:  {client_secret}")
print()
print("Copy Client ID and Client Secret into the OAuth configuration in ChatGPT.")
print("Treat the Client Secret as a credential and do not commit it to Git or paste it into logs.")
PY
