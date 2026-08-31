#!/usr/bin/env bash
set -Eeuo pipefail
URL="https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/gitea/install/proxmox-en.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP"
sed -i 's/^  printf '\''%s \[%s\]: '\'' "$prompt" "$default"$/  printf '\''%s [%s]: '\'' "$prompt" "$default" >\&2/' "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''HOSTNAME="$(ask_default 'Hostname' "$DEFAULT_HOSTNAME")"
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "Invalid hostname."'''
new = '''echo >&2
echo "Name of the new LXC" >&2
echo "This name is shown in Proxmox and is also used as the hostname." >&2
while true; do
  printf 'Desired LXC name: ' > /dev/tty
  read -r HOSTNAME < /dev/tty
  [[ -n "$HOSTNAME" ]] || { echo "The LXC name must not be empty." >&2; continue; }
  [[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "Invalid name. Letters, numbers, dots and hyphens are allowed." >&2; continue; }
  break
done'''
if old not in s:
    raise SystemExit('Hostname block not found')
p.write_text(s.replace(old, new))
PY
exec bash "$TMP"
