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

fehler() {
  echo "FEHLER: $*" >&2
  exit 1
}

frage_standard() {
  local prompt="$1" default="$2" value
  printf '%s [%s]: ' "$prompt" "$default"
  read -r value
  printf '%s' "${value:-$default}"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  fehler "Dieser Installer muss als root in der Proxmox-VE-Host-Shell gestartet werden."
fi

for cmd in pct pveversion pveam pvesm pvesh curl; do
  command -v "$cmd" >/dev/null 2>&1 || fehler "$cmd wird benötigt."
done

echo
echo "============================================================"
echo " Gitea MCP - Erweiterter Proxmox Installer"
echo "============================================================"
echo "Dieser Installer erstellt einen eigenen LXC, installiert Docker,"
echo "startet den Gitea-MCP und verbindet ihn über den sicheren"
echo "OpenAI-MCP-Tunnel."
echo

NEXT_ID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
[[ "$NEXT_ID" =~ ^[0-9]+$ ]] || NEXT_ID="100"

CTID="$(frage_standard 'LXC-ID' "$NEXT_ID")"
[[ "$CTID" =~ ^[0-9]+$ ]] || fehler "Die LXC-ID muss numerisch sein."
(( CTID >= 100 )) || fehler "LXC-IDs unter 100 sind von Proxmox reserviert."
if pct status "$CTID" >/dev/null 2>&1; then
  fehler "Die LXC-ID $CTID existiert bereits."
fi

HOSTNAME="$(frage_standard 'Hostname' "$DEFAULT_HOSTNAME")"
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fehler "Ungültiger Hostname."

ROOTFS_STORAGE="$(frage_standard 'Container-Speicher' "$DEFAULT_ROOTFS_STORAGE")"
pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$ROOTFS_STORAGE" || fehler "Speicher '$ROOTFS_STORAGE' wurde nicht gefunden."

TEMPLATE_STORAGE="$(frage_standard 'Template-Speicher' "$DEFAULT_TEMPLATE_STORAGE")"
pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_STORAGE" || fehler "Speicher '$TEMPLATE_STORAGE' wurde nicht gefunden."

CORES="$(frage_standard 'CPU-Kerne' "$DEFAULT_CORES")"
RAM="$(frage_standard 'RAM in MB' "$DEFAULT_RAM")"
SWAP="$(frage_standard 'Swap in MB' "$DEFAULT_SWAP")"
DISK_GB="$(frage_standard 'Festplattengröße in GB' "$DEFAULT_DISK")"
for pair in "CPU:$CORES" "RAM:$RAM" "Swap:$SWAP" "Festplatte:$DISK_GB"; do
  name="${pair%%:*}"; value="${pair#*:}"
  [[ "$value" =~ ^[0-9]+$ ]] || fehler "$name muss numerisch sein."
done
(( CORES >= 1 )) || fehler "Mindestens ein CPU-Kern wird benötigt."
(( RAM >= 512 )) || fehler "Mindestens 512 MB RAM werden benötigt."
(( DISK_GB >= 4 )) || fehler "Mindestens 4 GB Festplattenspeicher werden benötigt."

BRIDGE="$(frage_standard 'Netzwerk-Bridge' "$DEFAULT_BRIDGE")"
ip link show "$BRIDGE" >/dev/null 2>&1 || fehler "Die Bridge '$BRIDGE' existiert auf diesem Proxmox-Host nicht."

printf 'Netzwerkmodus [statisch/dhcp] [statisch]: '
read -r NET_MODE
NET_MODE="${NET_MODE:-statisch}"
case "$NET_MODE" in
  statisch|static) NET_MODE="static" ;;
  dhcp) NET_MODE="dhcp" ;;
  *) fehler "Netzwerkmodus muss statisch oder dhcp sein." ;;
esac

VLAN_TAG=""
if [[ "$NET_MODE" == "static" ]]; then
  printf 'IPv4-Adresse mit CIDR (Beispiel 192.168.1.50/24): '
  read -r IP_CIDR
  [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fehler "IPv4 bitte in CIDR-Schreibweise eingeben, z. B. 192.168.1.50/24."
  printf 'IPv4-Gateway (Beispiel 192.168.1.1): '
  read -r GATEWAY
  [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fehler "Ungültiges IPv4-Gateway."
fi
printf 'VLAN-ID [keine]: '
read -r VLAN_TAG
if [[ -n "$VLAN_TAG" ]]; then
  [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] || fehler "Die VLAN-ID muss numerisch sein."
  (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )) || fehler "Die VLAN-ID muss zwischen 1 und 4094 liegen."
fi

printf 'Gitea-Basis-URL (Beispiel https://git.example.com): '
read -r GITEA_URL
GITEA_URL="${GITEA_URL%/}"
[[ "$GITEA_URL" =~ ^https?://[^[:space:]]+$ ]] || fehler "Ungültige Gitea-URL."

printf 'Gitea-Zugriffstoken: '
read -r -s GITEA_TOKEN
echo
[[ -n "$GITEA_TOKEN" ]] || fehler "Ein Gitea-Zugriffstoken wird benötigt."

printf 'OpenAI Secure MCP Tunnel-ID (tunnel_...): '
read -r OPENAI_TUNNEL_ID
[[ "$OPENAI_TUNNEL_ID" =~ ^tunnel_[0-9A-Za-z_-]+$ ]] || fehler "Ungültige OpenAI-Tunnel-ID."

printf 'OpenAI Tunnel Runtime API-Key: '
read -r -s OPENAI_TUNNEL_API_KEY
echo
[[ -n "$OPENAI_TUNNEL_API_KEY" ]] || fehler "Ein OpenAI Tunnel Runtime API-Key wird benötigt."

MCP_HTTP_TOKEN="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"

NET0="name=eth0,bridge=${BRIDGE},type=veth,firewall=1"
if [[ "$NET_MODE" == "dhcp" ]]; then
  NET0+=",ip=dhcp"
else
  NET0+=",ip=${IP_CIDR},gw=${GATEWAY}"
fi
[[ -n "$VLAN_TAG" ]] && NET0+=",tag=${VLAN_TAG}"

echo
echo "---------------- Konfiguration ----------------"
echo "LXC-ID:             $CTID"
echo "Hostname:           $HOSTNAME"
echo "Container-Speicher: $ROOTFS_STORAGE"
echo "Template-Speicher:  $TEMPLATE_STORAGE"
echo "CPU / RAM / Swap:   $CORES Kerne / $RAM MB / $SWAP MB"
echo "Festplatte:         $DISK_GB GB"
echo "Bridge:             $BRIDGE"
if [[ "$NET_MODE" == "dhcp" ]]; then
  echo "IPv4:               DHCP"
else
  echo "IPv4:               $IP_CIDR"
  echo "Gateway:            $GATEWAY"
fi
echo "VLAN:                ${VLAN_TAG:-keine}"
echo "Gitea:              $GITEA_URL"
echo "Tunnel-ID:          $OPENAI_TUNNEL_ID"
echo "-------------------------------------------------"
printf 'Diesen LXC erstellen und Installation starten? [J/n]: '
read -r CONFIRM
CONFIRM="${CONFIRM:-J}"
[[ "$CONFIRM" =~ ^[JjYy]$ ]] || { echo "Installation abgebrochen."; exit 0; }

echo
echo "Proxmox-Appliance-Katalog wird aktualisiert..."
pveam update >/dev/null
TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | tail -n1)"
if [[ -z "$TEMPLATE_NAME" ]]; then
  TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE_NAME" ]] || fehler "Kein Debian-LXC-Template im Proxmox-Appliance-Katalog gefunden."

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fq "/${TEMPLATE_NAME}"; then
  echo "Debian-Template $TEMPLATE_NAME wird heruntergeladen..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi
OSTEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

echo "LXC $CTID wird erstellt..."
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

trap 'echo; echo "Installation gestoppt. LXC $CTID bleibt zur Fehleranalyse bestehen." >&2' ERR

echo "Warte auf Netzwerk im LXC..."
for _ in {1..60}; do
  if pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' 2>/dev/null; then
    break
  fi
  sleep 2
done
pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' || fehler "Der LXC hat keine funktionierende Netzwerk-/DNS-Verbindung."

echo "Basispakete und Docker werden installiert..."
pct exec "$CTID" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git unzip python3'
pct exec "$CTID" -- bash -lc 'curl -fsSL https://get.docker.com | sh'
pct exec "$CTID" -- bash -lc 'systemctl enable --now docker'

echo "Gitea-MCP wird installiert..."
pct exec "$CTID" -- bash -lc "rm -rf /opt/gitea-connector && git clone --depth 1 '$REPO_URL' /opt/gitea-connector"
printf 'GITEA_URL=%s\nGITEA_TOKEN=%s\nMCP_HTTP_TOKEN=%s\nMCP_PORT=8000\nMCP_ALLOWED_ORIGINS=\n' \
  "$GITEA_URL" "$GITEA_TOKEN" "$MCP_HTTP_TOKEN" |
  pct exec "$CTID" -- bash -lc "umask 077; cat > '$APP_DIR/.env'"
pct exec "$CTID" -- bash -lc "cd '$APP_DIR' && docker compose up -d --build"

echo "OpenAI tunnel-client wird installiert..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
case "$(uname -m)" in
  x86_64) tunnel_arch="linux-amd64" ;;
  aarch64|arm64) tunnel_arch="linux-arm64" ;;
  *) echo "Nicht unterstützte Architektur für OpenAI tunnel-client: $(uname -m)" >&2; exit 1 ;;
esac
release_json="$(curl -fsSL https://api.github.com/repos/openai/tunnel-client/releases/latest)"
download_url="$(printf "%s" "$release_json" | python3 -c "import json,sys; d=json.load(sys.stdin); arch=sys.argv[1]; urls=[a.get(\"browser_download_url\",\"\") for a in d.get(\"assets\",[]) if arch in a.get(\"name\",\"\") and a.get(\"name\",\"\").endswith(\".zip\")]; print(urls[0] if urls else \"\")" "$tunnel_arch")"
[[ -n "$download_url" ]] || { echo "Keine tunnel-client-Version für $tunnel_arch gefunden." >&2; exit 1; }
rm -rf /tmp/openai-tunnel-client && mkdir -p /tmp/openai-tunnel-client
curl -fsSL "$download_url" -o /tmp/openai-tunnel-client/tunnel.zip
unzip -q /tmp/openai-tunnel-client/tunnel.zip -d /tmp/openai-tunnel-client
binary="$(find /tmp/openai-tunnel-client -type f -name tunnel-client | head -n1)"
[[ -n "$binary" ]] || { echo "tunnel-client-Binärdatei wurde im Release-Archiv nicht gefunden." >&2; exit 1; }
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

echo "MCP und Tunnel werden geprüft..."
pct exec "$CTID" -- bash -lc 'for i in {1..30}; do curl -fsS http://127.0.0.1:8000/health >/dev/null && exit 0; sleep 2; done; exit 1' || fehler "Gitea-MCP-Healthcheck fehlgeschlagen."
pct exec "$CTID" -- bash -lc 'for i in {1..30}; do curl -fsS http://127.0.0.1:8080/readyz >/dev/null && exit 0; sleep 2; done; systemctl --no-pager --full status gitea-mcp-tunnel.service || true; exit 1' || fehler "OpenAI tunnel-client wurde nicht bereit."

LXC_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
trap - ERR

echo
echo "============================================================"
echo " Installation abgeschlossen"
echo "============================================================"
echo "LXC-ID:       $CTID"
echo "Hostname:     $HOSTNAME"
echo "LXC-IP:       ${LXC_IP:-unbekannt}"
echo "Gitea-MCP:    läuft"
echo "OpenAI MCP:   Tunnel verbunden und bereit"
echo "Tunnel-ID:    $OPENAI_TUNNEL_ID"
echo
echo "Der LXC ist für unbeaufsichtigten Betrieb und Autostart eingerichtet."
echo "Nächster Schritt: Diesen Tunnel beim Hinzufügen der Gitea-MCP-App in ChatGPT auswählen/verbinden."