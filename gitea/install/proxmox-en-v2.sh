#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Terranom674/ChatGPT_Connectors.git"
APP_DIR="/opt/gitea-connector/gitea/plugins/gitea-connector"
TTY="/dev/tty"

DEFAULT_BRIDGE="vmbr0"
DEFAULT_CORES="2"
DEFAULT_RAM="2048"
DEFAULT_SWAP="512"
DEFAULT_DISK="8"
DEFAULT_ROOTFS_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

note() {
  echo "$*" >&2
}

ask_default() {
  local __var="$1" prompt="$2" default="$3" value
  printf '%s [%s]: ' "$prompt" "$default" > "$TTY"
  read -r value < "$TTY"
  printf -v "$__var" '%s' "${value:-$default}"
}

ask_required() {
  local __var="$1" prompt="$2" value
  while true; do
    printf '%s: ' "$prompt" > "$TTY"
    read -r value < "$TTY"
    if [[ -n "$value" ]]; then
      printf -v "$__var" '%s' "$value"
      return 0
    fi
    note "This field must not be empty. Please try again."
  done
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run this installer as root in the Proxmox VE host shell."
for cmd in pct pveversion pveam pvesm pvesh curl ip awk grep; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done
[[ -r "$TTY" && -w "$TTY" ]] || fail "No interactive Proxmox console detected."

echo
echo "============================================================"
echo " Gitea MCP - Advanced Proxmox Installer"
echo "============================================================"
echo "This installer creates a dedicated LXC, installs Docker,"
echo "starts the Gitea MCP and connects it through the secure"
echo "OpenAI MCP Tunnel."
echo
echo "Invalid user input never terminates the installer."
echo "The current question is repeated until a valid value is entered."

NEXT_ID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
[[ "$NEXT_ID" =~ ^[0-9]+$ ]] || NEXT_ID="100"

echo
echo "------------------------------------------------------------"
echo " 1. LXC basics"
echo "------------------------------------------------------------"
echo "Values in [brackets] are suggested defaults."
echo "Press Enter to accept a suggested value."

while true; do
  ask_default CTID "LXC ID" "$NEXT_ID"
  if [[ ! "$CTID" =~ ^[0-9]+$ ]]; then
    note "The LXC ID must be numeric."
    continue
  fi
  if (( CTID < 100 )); then
    note "LXC IDs below 100 are not used. Choose an ID of 100 or higher."
    continue
  fi
  if pct status "$CTID" >/dev/null 2>&1; then
    note "LXC ID $CTID already exists. Choose another ID."
    continue
  fi
  break
done

echo
echo "Name of the new LXC"
echo "This name is shown in Proxmox and is also used as the hostname."
while true; do
  ask_required HOSTNAME "Desired LXC name"
  if [[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    break
  fi
  note "Invalid name. Allowed characters are letters, numbers, dots and hyphens."
done

while true; do
  ask_default ROOTFS_STORAGE "Container storage" "$DEFAULT_ROOTFS_STORAGE"
  if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$ROOTFS_STORAGE"; then
    break
  fi
  note "Storage '$ROOTFS_STORAGE' was not found. Please try again."
done

while true; do
  ask_default TEMPLATE_STORAGE "Template storage" "$DEFAULT_TEMPLATE_STORAGE"
  if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_STORAGE"; then
    break
  fi
  note "Storage '$TEMPLATE_STORAGE' was not found. Please try again."
done

while true; do
  ask_default CORES "CPU cores" "$DEFAULT_CORES"
  [[ "$CORES" =~ ^[0-9]+$ ]] && (( CORES >= 1 )) && break
  note "CPU cores must be a number of 1 or higher."
done

while true; do
  ask_default RAM "RAM in MB" "$DEFAULT_RAM"
  [[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 )) && break
  note "RAM must be numeric and at least 512 MB."
done

while true; do
  ask_default SWAP "Swap in MB" "$DEFAULT_SWAP"
  [[ "$SWAP" =~ ^[0-9]+$ ]] && break
  note "Swap must be numeric."
done

while true; do
  ask_default DISK_GB "Disk size in GB" "$DEFAULT_DISK"
  [[ "$DISK_GB" =~ ^[0-9]+$ ]] && (( DISK_GB >= 4 )) && break
  note "Disk size must be numeric and at least 4 GB."
done

echo
echo "------------------------------------------------------------"
echo " 2. Network"
echo "------------------------------------------------------------"

while true; do
  ask_default BRIDGE "Network bridge" "$DEFAULT_BRIDGE"
  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    break
  fi
  note "Bridge '$BRIDGE' does not exist on this Proxmox host."
done

while true; do
  printf 'Network mode [static/dhcp] [static]: ' > "$TTY"
  read -r NET_MODE < "$TTY"
  NET_MODE="${NET_MODE:-static}"
  case "$NET_MODE" in
    static) NET_MODE="static"; break ;;
    dhcp|DHCP) NET_MODE="dhcp"; break ;;
    *) note "Enter 'static' or 'dhcp'." ;;
  esac
done

IP_CIDR=""
GATEWAY=""
if [[ "$NET_MODE" == "static" ]]; then
  while true; do
    printf 'IPv4 address with CIDR (example 192.168.51.17/24): ' > "$TTY"
    read -r IP_CIDR < "$TTY"
    if [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
      break
    fi
    note "Invalid input. Include the network prefix, for example 192.168.51.17/24."
  done

  while true; do
    printf 'IPv4 gateway (example 192.168.51.1): ' > "$TTY"
    read -r GATEWAY < "$TTY"
    if [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      break
    fi
    note "Invalid IPv4 gateway. Please try again."
  done
fi

while true; do
  printf 'VLAN ID [none]: ' > "$TTY"
  read -r VLAN_TAG < "$TTY"
  [[ -z "$VLAN_TAG" ]] && break
  if [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] && (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )); then
    break
  fi
  note "Invalid VLAN ID. Use 1 to 4094 or press Enter for none."
done

echo
echo "------------------------------------------------------------"
echo " 3. Gitea connection"
echo "------------------------------------------------------------"
while true; do
  printf 'Gitea base URL (example git.example.com): ' > "$TTY"
  read -r GITEA_URL < "$TTY"
  GITEA_URL="${GITEA_URL%/}"
  [[ -n "$GITEA_URL" ]] || { note "The Gitea URL must not be empty."; continue; }
  if [[ ! "$GITEA_URL" =~ ^https?:// ]]; then
    GITEA_URL="https://$GITEA_URL"
    note "Automatically added https:// -> $GITEA_URL"
  fi
  if [[ "$GITEA_URL" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]]; then
    break
  fi
  note "Invalid Gitea URL. Enter for example git.example.com or https://git.example.com."
done

while true; do
  printf 'Gitea access token: ' > "$TTY"
  read -r -s GITEA_TOKEN < "$TTY"
  echo > "$TTY"
  [[ -n "$GITEA_TOKEN" ]] && break
  note "The Gitea access token must not be empty."
done

echo
echo "------------------------------------------------------------"
echo " 4. OpenAI Secure MCP Tunnel"
echo "------------------------------------------------------------"
while true; do
  printf 'OpenAI Secure MCP Tunnel ID (tunnel_...): ' > "$TTY"
  read -r OPENAI_TUNNEL_ID < "$TTY"
  [[ "$OPENAI_TUNNEL_ID" =~ ^tunnel_[0-9A-Za-z_-]+$ ]] && break
  note "Invalid tunnel ID. Please try again."
done

while true; do
  printf 'OpenAI tunnel runtime API key: ' > "$TTY"
  read -r -s OPENAI_TUNNEL_API_KEY < "$TTY"
  echo > "$TTY"
  [[ -n "$OPENAI_TUNNEL_API_KEY" ]] && break
  note "The OpenAI tunnel runtime API key must not be empty."
done

while true; do
  printf 'Public MCP OAuth resource URL (example https://mcp.example.com/mcp): ' > "$TTY"
  read -r MCP_RESOURCE_URL < "$TTY"
  MCP_RESOURCE_URL="${MCP_RESOURCE_URL%/}"
  [[ "$MCP_RESOURCE_URL" =~ ^https://[^[:space:]]+/mcp$ ]] && break
  note "Enter the complete public HTTPS MCP URL including /mcp."
done

MCP_HTTP_TOKEN="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"

NET0="name=eth0,bridge=${BRIDGE},type=veth,firewall=1"
if [[ "$NET_MODE" == "dhcp" ]]; then
  NET0+=",ip=dhcp"
else
  NET0+=",ip=${IP_CIDR},gw=${GATEWAY}"
fi
[[ -n "$VLAN_TAG" ]] && NET0+=",tag=${VLAN_TAG}"

echo
echo "---------------- Configuration ----------------"
echo "LXC ID:             $CTID"
echo "LXC name/hostname:  $HOSTNAME"
echo "Container storage:  $ROOTFS_STORAGE"
echo "Template storage:   $TEMPLATE_STORAGE"
echo "CPU / RAM / Swap:   $CORES cores / $RAM MB / $SWAP MB"
echo "Disk:               $DISK_GB GB"
echo "Bridge:             $BRIDGE"
if [[ "$NET_MODE" == "dhcp" ]]; then
  echo "IPv4:               DHCP"
else
  echo "IPv4:               $IP_CIDR"
  echo "Gateway:            $GATEWAY"
fi
echo "VLAN:                ${VLAN_TAG:-none}"
echo "Gitea:              $GITEA_URL"
echo "MCP resource:       $MCP_RESOURCE_URL"
echo "Tunnel ID:          $OPENAI_TUNNEL_ID"
echo "-------------------------------------------------"

while true; do
  printf 'Create this LXC and start installation? [Y/n]: ' > "$TTY"
  read -r CONFIRM < "$TTY"
  CONFIRM="${CONFIRM:-Y}"
  case "$CONFIRM" in
    Y|y|Yes|yes) break ;;
    N|n|No|no) echo "Installation cancelled."; exit 0 ;;
    *) note "Enter Y or N." ;;
  esac
done

echo
echo "Updating Proxmox appliance catalog..."
pveam update >/dev/null
TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | tail -n1)"
if [[ -z "$TEMPLATE_NAME" ]]; then
  TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE_NAME" ]] || fail "No Debian LXC template was found in the Proxmox appliance catalog."

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fq "/${TEMPLATE_NAME}"; then
  echo "Downloading Debian template $TEMPLATE_NAME..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi
OSTEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

echo "Creating LXC $CTID..."
pct create "$CTID" "$OSTEMPLATE" \
  --hostname "$HOSTNAME" \
  --ostype debian \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$SWAP" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
  --net0 "$NET0" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --timezone host \
  --tags "gitea-mcp" \
  --start 1

trap 'echo; echo "Installation stopped. LXC $CTID remains in place for diagnostics." >&2' ERR

echo "Waiting for network inside the LXC..."
for _ in {1..60}; do
  if pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' 2>/dev/null; then
    break
  fi
  sleep 2
done
pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' || fail "The LXC has no working network/DNS connection."

echo "Installing base packages and Docker..."
pct exec "$CTID" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git unzip python3'
pct exec "$CTID" -- bash -lc 'curl -fsSL https://get.docker.com | sh'
pct exec "$CTID" -- bash -lc 'systemctl enable --now docker'

echo "Installing Gitea MCP..."
pct exec "$CTID" -- bash -lc "rm -rf /opt/gitea-connector && git clone --depth 1 '$REPO_URL' /opt/gitea-connector"
printf 'GITEA_URL=%s\nGITEA_TOKEN=%s\nMCP_HTTP_TOKEN=%s\nMCP_OAUTH_ISSUER=%s\nMCP_RESOURCE_URL=%s\nMCP_PORT=8000\nMCP_ALLOWED_ORIGINS=\n' \
  "$GITEA_URL" "$GITEA_TOKEN" "$MCP_HTTP_TOKEN" "$GITEA_URL" "$MCP_RESOURCE_URL" |
  pct exec "$CTID" -- bash -lc "umask 077; cat > '$APP_DIR/.env'"
pct exec "$CTID" -- bash -lc "cd '$APP_DIR' && docker compose up -d --build"

echo "Installing OpenAI tunnel-client..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
case "$(uname -m)" in
  x86_64) tunnel_arch="linux-amd64" ;;
  aarch64|arm64) tunnel_arch="linux-arm64" ;;
  *) echo "Unsupported architecture for OpenAI tunnel-client: $(uname -m)" >&2; exit 1 ;;
esac
release_json="$(curl -fsSL https://api.github.com/repos/openai/tunnel-client/releases/latest)"
download_url="$(printf "%s" "$release_json" | python3 -c "import json,sys; d=json.load(sys.stdin); arch=sys.argv[1]; urls=[a.get(\"browser_download_url\",\"\") for a in d.get(\"assets\",[]) if arch in a.get(\"name\",\"\") and a.get(\"name\",\"\").endswith(\".zip\")]; print(urls[0] if urls else \"\")" "$tunnel_arch")"
[[ -n "$download_url" ]] || { echo "No tunnel-client release found for $tunnel_arch." >&2; exit 1; }
rm -rf /tmp/openai-tunnel-client && mkdir -p /tmp/openai-tunnel-client
curl -fsSL "$download_url" -o /tmp/openai-tunnel-client/tunnel.zip
unzip -q /tmp/openai-tunnel-client/tunnel.zip -d /tmp/openai-tunnel-client
binary="$(find /tmp/openai-tunnel-client -type f -name tunnel-client | head -n1)"
[[ -n "$binary" ]] || { echo "tunnel-client binary not found in release archive." >&2; exit 1; }
install -m 0755 "$binary" /usr/local/bin/tunnel-client
rm -rf /tmp/openai-tunnel-client
'

printf 'CONTROL_PLANE_TUNNEL_ID=%s\nCONTROL_PLANE_API_KEY=%s\nMCP_SERVER_URL=http://127.0.0.1:8000/mcp\nMCP_EXTRA_HEADERS="Authorization: Bearer %s"\nMCP_DISCOVERY_EXTRA_HEADERS="Authorization: Bearer %s"\nHEALTH_LISTEN_ADDR=127.0.0.1:8080\nLOG_LEVEL=info\nLOG_FORMAT=struct-text\n' \
  "$OPENAI_TUNNEL_ID" "$OPENAI_TUNNEL_API_KEY" "$MCP_HTTP_TOKEN" "$MCP_HTTP_TOKEN" |
  pct exec "$CTID" -- bash -lc 'umask 077; cat > /etc/gitea-mcp-tunnel.env'

pct exec "$CTID" -- bash -lc 'cat > /etc/systemd/system/gitea-mcp-tunnel.service <<"EOF"
[Unit]
Description=OpenAI Secure MCP Tunnel for Gitea MCP
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/gitea-mcp-tunnel.env
ExecStart=/usr/local/bin/tunnel-client run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now gitea-mcp-tunnel.service
'

echo "Checking MCP and tunnel..."
pct exec "$CTID" -- bash -lc 'for i in {1..30}; do curl -fsS http://127.0.0.1:8000/health >/dev/null && exit 0; sleep 2; done; exit 1' || fail "Gitea MCP health check failed."
pct exec "$CTID" -- bash -lc 'for i in {1..30}; do curl -fsS http://127.0.0.1:8080/readyz >/dev/null && exit 0; sleep 2; done; systemctl --no-pager --full status gitea-mcp-tunnel.service || true; exit 1' || fail "OpenAI tunnel-client did not become ready."

LXC_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
trap - ERR

echo
echo "============================================================"
echo " Installation completed"
echo "============================================================"
echo "LXC ID:      $CTID"
echo "LXC name:    $HOSTNAME"
echo "LXC IP:      ${LXC_IP:-unknown}"
echo "Gitea MCP:   running"
echo "OpenAI MCP:  tunnel connected and ready"
echo "Tunnel ID:   $OPENAI_TUNNEL_ID"
echo "MCP URL:     $MCP_RESOURCE_URL"
echo
echo "The LXC is configured for unattended operation and autostart."
echo
echo "Initial OAuth setup in ChatGPT:"
echo "1. Add the MCP/app in ChatGPT using the public MCP URL and select OAuth."
echo "2. Copy the callback/redirect URL shown by ChatGPT."
echo "3. Run as root inside the new LXC:"
echo "   bash /opt/gitea-connector/gitea/install/oauth-setup.sh"
echo "4. Enter the callback URL. The helper creates the OAuth2 application in Gitea."
echo "5. Enter the returned Client ID and Client Secret in ChatGPT."
echo "6. Complete OAuth authorization and rescan the MCP tools."
echo
echo "The complete procedure is documented in README.md."