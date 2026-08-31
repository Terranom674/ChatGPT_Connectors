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

fehler() { echo "FEHLER: $*" >&2; exit 1; }
hinweis() { echo "$*" >&2; }

frage_standard() {
  local __var="$1" prompt="$2" default="$3" value
  printf '%s [%s]: ' "$prompt" "$default" > "$TTY"
  read -r value < "$TTY"
  printf -v "$__var" '%s' "${value:-$default}"
}

frage_pflicht() {
  local __var="$1" prompt="$2" value
  while true; do
    printf '%s: ' "$prompt" > "$TTY"
    read -r value < "$TTY"
    if [[ -n "$value" ]]; then
      printf -v "$__var" '%s' "$value"
      return 0
    fi
    hinweis "Dieses Feld darf nicht leer sein. Bitte erneut eingeben."
  done
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fehler "Dieser Installer muss als root in der Proxmox-VE-Host-Shell gestartet werden."
for cmd in pct pveversion pveam pvesm pvesh curl ip awk grep; do
  command -v "$cmd" >/dev/null 2>&1 || fehler "$cmd wird benötigt."
done
[[ -r "$TTY" && -w "$TTY" ]] || fehler "Keine interaktive Proxmox-Konsole erkannt."

echo
echo "============================================================"
echo " Gitea MCP - Erweiterter Proxmox Installer"
echo "============================================================"
echo "Dieser Installer erstellt einen eigenen LXC, installiert Docker,"
echo "startet den Gitea-MCP und verbindet ihn über den sicheren"
echo "OpenAI-MCP-Tunnel."
echo
echo "Ungültige Benutzereingaben beenden den Installer nicht."
echo "Die jeweilige Frage wird wiederholt, bis ein gültiger Wert eingegeben wurde."

NEXT_ID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
[[ "$NEXT_ID" =~ ^[0-9]+$ ]] || NEXT_ID="100"

echo
echo "------------------------------------------------------------"
echo " 1. LXC-Grundeinstellungen"
echo "------------------------------------------------------------"
echo "Werte in [eckigen Klammern] sind Vorschläge."
echo "Mit Enter übernimmst du den vorgeschlagenen Wert."

while true; do
  frage_standard CTID "LXC-ID" "$NEXT_ID"
  [[ "$CTID" =~ ^[0-9]+$ ]] || { hinweis "Die LXC-ID muss aus Zahlen bestehen."; continue; }
  (( CTID >= 100 )) || { hinweis "Bitte eine LXC-ID ab 100 wählen."; continue; }
  if pct status "$CTID" >/dev/null 2>&1; then
    hinweis "Die LXC-ID $CTID existiert bereits. Bitte eine andere ID wählen."
    continue
  fi
  break
done

echo
echo "Name des neuen LXC"
echo "Dieser Name wird in Proxmox angezeigt und zugleich als Hostname verwendet."
while true; do
  frage_pflicht HOSTNAME "Gewünschter LXC-Name"
  [[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] && break
  hinweis "Ungültiger Name. Erlaubt sind Buchstaben, Zahlen, Punkt und Bindestrich."
done

while true; do
  frage_standard ROOTFS_STORAGE "Container-Speicher" "$DEFAULT_ROOTFS_STORAGE"
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$ROOTFS_STORAGE" && break
  hinweis "Speicher '$ROOTFS_STORAGE' wurde nicht gefunden. Bitte erneut eingeben."
done
while true; do
  frage_standard TEMPLATE_STORAGE "Template-Speicher" "$DEFAULT_TEMPLATE_STORAGE"
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_STORAGE" && break
  hinweis "Speicher '$TEMPLATE_STORAGE' wurde nicht gefunden. Bitte erneut eingeben."
done
while true; do
  frage_standard CORES "CPU-Kerne" "$DEFAULT_CORES"
  [[ "$CORES" =~ ^[0-9]+$ ]] && (( CORES >= 1 )) && break
  hinweis "CPU-Kerne müssen eine Zahl ab 1 sein."
done
while true; do
  frage_standard RAM "RAM in MB" "$DEFAULT_RAM"
  [[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 )) && break
  hinweis "RAM muss numerisch sein und mindestens 512 MB betragen."
done
while true; do
  frage_standard SWAP "Swap in MB" "$DEFAULT_SWAP"
  [[ "$SWAP" =~ ^[0-9]+$ ]] && break
  hinweis "Swap muss numerisch sein."
done
while true; do
  frage_standard DISK_GB "Festplattengröße in GB" "$DEFAULT_DISK"
  [[ "$DISK_GB" =~ ^[0-9]+$ ]] && (( DISK_GB >= 4 )) && break
  hinweis "Die Festplattengröße muss numerisch sein und mindestens 4 GB betragen."
done

echo
echo "------------------------------------------------------------"
echo " 2. Netzwerk"
echo "------------------------------------------------------------"
while true; do
  frage_standard BRIDGE "Netzwerk-Bridge" "$DEFAULT_BRIDGE"
  ip link show "$BRIDGE" >/dev/null 2>&1 && break
  hinweis "Die Bridge '$BRIDGE' existiert auf diesem Proxmox-Host nicht."
done

while true; do
  printf 'Netzwerkmodus [statisch/dhcp] [statisch]: ' > "$TTY"
  read -r NET_MODE < "$TTY"
  NET_MODE="${NET_MODE:-statisch}"
  case "$NET_MODE" in
    statisch|static) NET_MODE="static"; break ;;
    dhcp|DHCP) NET_MODE="dhcp"; break ;;
    *) hinweis "Bitte 'statisch' oder 'dhcp' eingeben." ;;
  esac
done

IP_CIDR=""; GATEWAY=""
if [[ "$NET_MODE" == "static" ]]; then
  while true; do
    printf 'IPv4-Adresse mit CIDR (Beispiel 192.168.51.17/24): ' > "$TTY"
    read -r IP_CIDR < "$TTY"
    [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] && break
    hinweis "Ungültige Eingabe. Bitte die Adresse inklusive Netzmaske angeben, z. B. 192.168.51.17/24."
  done
  while true; do
    printf 'IPv4-Gateway (Beispiel 192.168.51.1): ' > "$TTY"
    read -r GATEWAY < "$TTY"
    [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    hinweis "Ungültiges IPv4-Gateway. Bitte erneut eingeben."
  done
fi
while true; do
  printf 'VLAN-ID [keine]: ' > "$TTY"
  read -r VLAN_TAG < "$TTY"
  [[ -z "$VLAN_TAG" ]] && break
  [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] && (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )) && break
  hinweis "Ungültige VLAN-ID. Erlaubt sind 1 bis 4094 oder Enter für keine VLAN-ID."
done

echo
echo "------------------------------------------------------------"
echo " 3. Gitea-Verbindung"
echo "------------------------------------------------------------"
while true; do
  printf 'Gitea-Basis-URL (Beispiel git.example.com): ' > "$TTY"
  read -r GITEA_URL < "$TTY"
  GITEA_URL="${GITEA_URL%/}"
  [[ -n "$GITEA_URL" ]] || { hinweis "Die Gitea-URL darf nicht leer sein."; continue; }
  if [[ ! "$GITEA_URL" =~ ^https?:// ]]; then
    GITEA_URL="https://$GITEA_URL"
    hinweis "https:// wurde automatisch ergänzt: $GITEA_URL"
  fi
  [[ "$GITEA_URL" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]] && break
  hinweis "Ungültige Gitea-URL. Bitte z. B. git.example.com oder https://git.example.com eingeben."
done

while true; do
  printf 'Gitea-Zugriffstoken: ' > "$TTY"
  read -r -s GITEA_TOKEN < "$TTY"
  echo > "$TTY"
  [[ -n "$GITEA_TOKEN" ]] && break
  hinweis "Der Gitea-Zugriffstoken darf nicht leer sein."
done

echo
echo "------------------------------------------------------------"
echo " 4. OpenAI Secure MCP Tunnel"
echo "------------------------------------------------------------"
while true; do
  printf 'OpenAI Secure MCP Tunnel-ID (tunnel_...): ' > "$TTY"
  read -r OPENAI_TUNNEL_ID < "$TTY"
  [[ "$OPENAI_TUNNEL_ID" =~ ^tunnel_[0-9A-Za-z_-]+$ ]] && break
  hinweis "Ungültige Tunnel-ID. Bitte erneut eingeben."
done
while true; do
  printf 'OpenAI Tunnel Runtime API-Key: ' > "$TTY"
  read -r -s OPENAI_TUNNEL_API_KEY < "$TTY"
  echo > "$TTY"
  [[ -n "$OPENAI_TUNNEL_API_KEY" ]] && break
  hinweis "Der OpenAI Tunnel Runtime API-Key darf nicht leer sein."
done
while true; do
  printf 'Öffentliche MCP-URL für OAuth (Beispiel https://mcp.example.com/mcp): ' > "$TTY"
  read -r MCP_RESOURCE_URL < "$TTY"
  MCP_RESOURCE_URL="${MCP_RESOURCE_URL%/}"
  [[ "$MCP_RESOURCE_URL" =~ ^https://[^[:space:]]+/mcp$ ]] && break
  hinweis "Bitte die vollständige öffentliche HTTPS-MCP-URL inklusive /mcp eingeben."
done

MCP_HTTP_TOKEN="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"
NET0="name=eth0,bridge=${BRIDGE},type=veth,firewall=1"
if [[ "$NET_MODE" == "dhcp" ]]; then NET0+=",ip=dhcp"; else NET0+=",ip=${IP_CIDR},gw=${GATEWAY}"; fi
[[ -n "$VLAN_TAG" ]] && NET0+=",tag=${VLAN_TAG}"

echo
echo "---------------- Konfiguration ----------------"
echo "LXC-ID:             $CTID"
echo "LXC-Name/Hostname:  $HOSTNAME"
echo "Container-Speicher: $ROOTFS_STORAGE"
echo "Template-Speicher:  $TEMPLATE_STORAGE"
echo "CPU / RAM / Swap:   $CORES Kerne / $RAM MB / $SWAP MB"
echo "Festplatte:         $DISK_GB GB"
echo "Bridge:             $BRIDGE"
if [[ "$NET_MODE" == "dhcp" ]]; then echo "IPv4:               DHCP"; else echo "IPv4:               $IP_CIDR"; echo "Gateway:            $GATEWAY"; fi
echo "VLAN:                ${VLAN_TAG:-keine}"
echo "Gitea:              $GITEA_URL"
echo "MCP-Ressource:      $MCP_RESOURCE_URL"
echo "Tunnel-ID:          $OPENAI_TUNNEL_ID"
echo "-------------------------------------------------"

while true; do
  printf 'Diesen LXC erstellen und Installation starten? [J/n]: ' > "$TTY"
  read -r CONFIRM < "$TTY"
  CONFIRM="${CONFIRM:-J}"
  case "$CONFIRM" in
    J|j|Y|y|Ja|ja) break ;;
    N|n|Nein|nein) echo "Installation abgebrochen."; exit 0 ;;
    *) hinweis "Bitte J oder N eingeben." ;;
  esac
done

echo
echo "Proxmox-Appliance-Katalog wird aktualisiert..."
pveam update >/dev/null
TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | tail -n1)"
if [[ -z "$TEMPLATE_NAME" ]]; then TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n1)"; fi
[[ -n "$TEMPLATE_NAME" ]] || fehler "Kein Debian-LXC-Template im Proxmox-Appliance-Katalog gefunden."
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fq "/${TEMPLATE_NAME}"; then
  echo "Debian-Template $TEMPLATE_NAME wird heruntergeladen..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi
OSTEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

echo "LXC $CTID wird erstellt..."
pct create "$CTID" "$OSTEMPLATE" --hostname "$HOSTNAME" --ostype debian --cores "$CORES" --memory "$RAM" --swap "$SWAP" --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" --net0 "$NET0" --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --timezone host --tags "gitea-mcp" --start 1
trap 'echo; echo "Installation gestoppt. LXC $CTID bleibt zur Fehleranalyse bestehen." >&2' ERR

echo "Warte auf Netzwerk im LXC..."
for _ in {1..60}; do pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' 2>/dev/null && break; sleep 2; done
pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' || fehler "Der LXC hat keine funktionierende Netzwerk-/DNS-Verbindung."

echo "Basispakete und Docker werden installiert..."
pct exec "$CTID" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git unzip python3'
pct exec "$CTID" -- bash -lc 'curl -fsSL https://get.docker.com | sh'
pct exec "$CTID" -- bash -lc 'systemctl enable --now docker'

echo "Gitea-MCP wird installiert..."
pct exec "$CTID" -- bash -lc "rm -rf /opt/gitea-connector && git clone --depth 1 '$REPO_URL' /opt/gitea-connector"
printf 'GITEA_URL=%s\nGITEA_TOKEN=%s\nMCP_HTTP_TOKEN=%s\nMCP_OAUTH_ISSUER=%s\nMCP_RESOURCE_URL=%s\nMCP_PORT=8000\nMCP_ALLOWED_ORIGINS=\n' "$GITEA_URL" "$GITEA_TOKEN" "$MCP_HTTP_TOKEN" "$GITEA_URL" "$MCP_RESOURCE_URL" | pct exec "$CTID" -- bash -lc "umask 077; cat > '$APP_DIR/.env'"
pct exec "$CTID" -- bash -lc "cd '$APP_DIR' && docker compose up -d --build"

echo "OpenAI tunnel-client wird installiert..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
case "$(uname -m)" in x86_64) tunnel_arch="linux-amd64" ;; aarch64|arm64) tunnel_arch="linux-arm64" ;; *) echo "Nicht unterstützte Architektur: $(uname -m)" >&2; exit 1 ;; esac
release_json="$(curl -fsSL https://api.github.com/repos/openai/tunnel-client/releases/latest)"
download_url="$(printf "%s" "$release_json" | python3 -c "import json,sys; d=json.load(sys.stdin); arch=sys.argv[1]; urls=[a.get(\"browser_download_url\",\"\") for a in d.get(\"assets\",[]) if arch in a.get(\"name\",\"\") and a.get(\"name\",\"\").endswith(\".zip\")]; print(urls[0] if urls else \"\")" "$tunnel_arch")"
[[ -n "$download_url" ]] || { echo "Keine tunnel-client-Version gefunden." >&2; exit 1; }
rm -rf /tmp/openai-tunnel-client && mkdir -p /tmp/openai-tunnel-client
curl -fsSL "$download_url" -o /tmp/openai-tunnel-client/tunnel.zip
unzip -q /tmp/openai-tunnel-client/tunnel.zip -d /tmp/openai-tunnel-client
binary="$(find /tmp/openai-tunnel-client -type f -name tunnel-client | head -n1)"
[[ -n "$binary" ]] || { echo "tunnel-client-Binärdatei nicht gefunden." >&2; exit 1; }
install -m 0755 "$binary" /usr/local/bin/tunnel-client
rm -rf /tmp/openai-tunnel-client
'

printf 'CONTROL_PLANE_TUNNEL_ID=%s\nCONTROL_PLANE_API_KEY=%s\nMCP_SERVER_URL=http://127.0.0.1:8000/mcp\nMCP_EXTRA_HEADERS="Authorization: Bearer %s"\nMCP_DISCOVERY_EXTRA_HEADERS="Authorization: Bearer %s"\nHEALTH_LISTEN_ADDR=127.0.0.1:8080\nLOG_LEVEL=info\nLOG_FORMAT=struct-text\n' "$OPENAI_TUNNEL_ID" "$OPENAI_TUNNEL_API_KEY" "$MCP_HTTP_TOKEN" "$MCP_HTTP_TOKEN" | pct exec "$CTID" -- bash -lc 'umask 077; cat > /etc/gitea-mcp-tunnel.env'

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
systemctl enable --now gitea-mcp-tunnel.service'

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
echo "LXC-Name:     $HOSTNAME"
echo "LXC-IP:       ${LXC_IP:-unbekannt}"
echo "Gitea-MCP:    läuft"
echo "OpenAI MCP:   Tunnel verbunden und bereit"
echo "Tunnel-ID:    $OPENAI_TUNNEL_ID"
echo "MCP-URL:      $MCP_RESOURCE_URL"
echo
echo "Der LXC ist für unbeaufsichtigten Betrieb und Autostart eingerichtet."
echo
echo "OAuth-Ersteinrichtung in ChatGPT:"
echo "1. MCP/App in ChatGPT mit der öffentlichen MCP-URL anlegen und OAuth auswählen."
echo "2. Die von ChatGPT angezeigte Callback-/Redirect-URL kopieren."
echo "3. Im neuen LXC als root ausführen:"
echo "   bash /opt/gitea-connector/gitea/install/oauth-setup.sh"
echo "4. Die Callback-URL eingeben. Das Hilfsskript legt die OAuth2-App in Gitea an."
echo "5. Die ausgegebene Client ID und das Client Secret in ChatGPT eintragen."
echo "6. OAuth-Autorisierung abschließen und die MCP-Tools neu einlesen."
echo
echo "Der vollständige Ablauf ist in README.md dokumentiert."