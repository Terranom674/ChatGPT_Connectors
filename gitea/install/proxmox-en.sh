#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Terranom674/ChatGPT_Connectors.git"
APP_DIR="/opt/gitea-connector/gitea/plugins/gitea-connector"
DEFAULT_HOSTNAME="gitea-mcp"
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

ask_default() {
  local prompt="$1" default="$2" value
  printf '%s [%s]: ' "$prompt" "$default"
  read -r value
  printf '%s' "${value:-$default}"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  fail "Run this installer as root in the Proxmox VE host shell."
fi

for cmd in pct pveversion pveam pvesm pvesh curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done

echo
echo "============================================================"
echo " Gitea MCP - Advanced Proxmox Installer"
echo "============================================================"
echo "This creates one dedicated LXC, installs Docker, starts the"
echo "Gitea MCP and connects it through OpenAI Secure MCP Tunnel."
echo

NEXT_ID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
[[ "$NEXT_ID" =~ ^[0-9]+$ ]] || NEXT_ID="100"

CTID="$(ask_default 'LXC ID' "$NEXT_ID")"
[[ "$CTID" =~ ^[0-9]+$ ]] || fail "LXC ID must be numeric."
(( CTID >= 100 )) || fail "LXC IDs below 100 are reserved by Proxmox."
if pct status "$CTID" >/dev/null 2>&1; then
  fail "LXC ID $CTID already exists."
fi

HOSTNAME="$(ask_default 'Hostname' "$DEFAULT_HOSTNAME")"
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "Invalid hostname."

ROOTFS_STORAGE="$(ask_default 'Container storage' "$DEFAULT_ROOTFS_STORAGE")"
pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$ROOTFS_STORAGE" || fail "Storage '$ROOTFS_STORAGE' was not found."

TEMPLATE_STORAGE="$(ask_default 'Template storage' "$DEFAULT_TEMPLATE_STORAGE")"
pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_STORAGE" || fail "Storage '$TEMPLATE_STORAGE' was not found."

CORES="$(ask_default 'CPU cores' "$DEFAULT_CORES")"
RAM="$(ask_default 'RAM in MB' "$DEFAULT_RAM")"
SWAP="$(ask_default 'Swap in MB' "$DEFAULT_SWAP")"
DISK_GB="$(ask_default 'Disk size in GB' "$DEFAULT_DISK")"
for pair in "CPU:$CORES" "RAM:$RAM" "Swap:$SWAP" "Disk:$DISK_GB"; do
  name="${pair%%:*}"; value="${pair#*:}"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be numeric."
done
(( CORES >= 1 )) || fail "At least one CPU core is required."
(( RAM >= 512 )) || fail "At least 512 MB RAM is required."
(( DISK_GB >= 4 )) || fail "At least 4 GB disk space is required."

BRIDGE="$(ask_default 'Network bridge' "$DEFAULT_BRIDGE")"
ip link show "$BRIDGE" >/dev/null 2>&1 || fail "Bridge '$BRIDGE' does not exist on this Proxmox host."

printf 'Network mode [static/dhcp] [static]: '
read -r NET_MODE
NET_MODE="${NET_MODE:-static}"
[[ "$NET_MODE" == "static" || "$NET_MODE" == "dhcp" ]] || fail "Network mode must be static or dhcp."

VLAN_TAG=""
if [[ "$NET_MODE" == "static" ]]; then
  printf 'IPv4 address with CIDR (example 192.168.1.50/24): '
  read -r IP_CIDR
  [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fail "Enter IPv4 in CIDR notation, for example 192.168.1.50/24."
  printf 'IPv4 gateway (example 192.168.1.1): '
  read -r GATEWAY
  [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "Invalid IPv4 gateway."
fi
printf 'VLAN tag [none]: '
read -r VLAN_TAG
if [[ -n "$VLAN_TAG" ]]; then
  [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] || fail "VLAN tag must be numeric."
  (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )) || fail "VLAN tag must be between 1 and 4094."
fi

printf 'Gitea base URL (example https://git.example.com): '
read -r GITEA_URL
GITEA_URL="${GITEA_URL%/}"
[[ "$GITEA_URL" =~ ^https?://[^[:space:]]+$ ]] || fail "Invalid Gitea URL."

printf 'Gitea access token: '
read -r -s GITEA_TOKEN
echo
[[ -n "$GITEA_TOKEN" ]] || fail "A Gitea access token is required."

printf 'OpenAI Secure MCP Tunnel ID (tunnel_...): '
read -r OPENAI_TUNNEL_ID
[[ "$OPENAI_TUNNEL_ID" =~ ^tunnel_[0-9A-Za-z_-]+$ ]] || fail "Invalid OpenAI tunnel ID."

printf 'OpenAI tunnel runtime API key: '
read -r -s OPENAI_TUNNEL_API_KEY
echo
[[ -n "$OPENAI_TUNNEL_API_KEY" ]] || fail "An OpenAI tunnel runtime API key is required."

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
echo "LXC ID:            $CTID"
echo "Hostname:          $HOSTNAME"
echo "Container storage: $ROOTFS_STORAGE"
echo "Template storage:  $TEMPLATE_STORAGE"
echo "CPU / RAM / Swap:  $CORES cores / $RAM MB / $SWAP MB"
echo "Disk:              $DISK_GB GB"
echo "Bridge:            $BRIDGE"
if [[ "$NET_MODE" == "dhcp" ]]; then
  echo "IPv4:              DHCP"
else
  echo "IPv4:              $IP_CIDR"
  echo "Gateway:           $GATEWAY"
fi
echo "VLAN:               ${VLAN_TAG:-none}"
echo "Gitea:             $GITEA_URL"
echo "Tunnel ID:         $OPENAI_TUNNEL_ID"
echo "-------------------------------------------------"
printf 'Create this LXC and continue? [Y/n]: '
read -r CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Installation cancelled."; exit 0; }

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

trap 'echo; echo "Installation stopped. LXC $CTID was left in place for diagnostics." >&2' ERR

echo "Waiting for the LXC network..."
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
printf 'GITEA_URL=%s\nGITEA_TOKEN=%s\nMCP_HTTP_TOKEN=%s\nMCP_PORT=8000\nMCP_ALLOWED_ORIGINS=\n' \
  "$GITEA_URL" "$GITEA_TOKEN" "$MCP_HTTP_TOKEN" |
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
echo "Hostname:    $HOSTNAME"
echo "LXC IP:      ${LXC_IP:-unknown}"
echo "Gitea MCP:   running"
echo "OpenAI MCP:  tunnel connected and ready"
echo "Tunnel ID:   $OPENAI_TUNNEL_ID"
echo
echo "The LXC is configured for unattended operation and autostart."
echo "Next step: select/connect this tunnel when adding the Gitea MCP app in ChatGPT."