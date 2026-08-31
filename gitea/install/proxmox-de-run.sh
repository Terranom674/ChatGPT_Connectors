#!/usr/bin/env bash
set -Eeuo pipefail
URL="https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/gitea/install/proxmox-de.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()

# Prompts used inside command substitutions must be visible on the terminal.
s = s.replace("  printf '%s [%s]: ' \"$prompt\" \"$default\"\n  read -r value", "  printf '%s [%s]: ' \"$prompt\" \"$default\" > /dev/tty\n  read -r value < /dev/tty")

# LXC ID: retry until numeric, >=100 and unused.
s = re.sub(r'''CTID="\$\(frage_standard 'LXC-ID' "\$NEXT_ID"\)"\n\[\[ "\$CTID" =~ \^\[0-9\]\+\$ \]\] \|\| fehler "Die LXC-ID muss numerisch sein\."\n\(\( CTID >= 100 \)\) \|\| fehler "LXC-IDs unter 100 sind von Proxmox reserviert\."\nif pct status "\$CTID" >/dev/null 2>&1; then\n  fehler "Die LXC-ID \$CTID existiert bereits\."\nfi''', '''while true; do
  CTID="$(frage_standard 'LXC-ID' "$NEXT_ID")"
  [[ "$CTID" =~ ^[0-9]+$ ]] || { echo "Die LXC-ID muss numerisch sein." >&2; continue; }
  (( CTID >= 100 )) || { echo "LXC-IDs unter 100 sind von Proxmox reserviert." >&2; continue; }
  if pct status "$CTID" >/dev/null 2>&1; then
    echo "Die LXC-ID $CTID existiert bereits. Bitte eine andere wählen." >&2
    continue
  fi
  break
done''', s)

# Individual LXC name.
s = re.sub(r'''HOSTNAME="\$\(frage_standard 'Hostname' "\$DEFAULT_HOSTNAME"\)"\n\[\[ "\$HOSTNAME" =~ \^\[A-Za-z0-9\]\[A-Za-z0-9\.\-\]\*\$ \]\] \|\| fehler "Ungültiger Hostname\."''', '''echo >&2
echo "Name des neuen LXC" >&2
echo "Dieser Name wird in Proxmox angezeigt und zugleich als Hostname verwendet." >&2
while true; do
  printf 'Gewünschter LXC-Name: ' > /dev/tty
  read -r HOSTNAME < /dev/tty
  [[ -n "$HOSTNAME" ]] || { echo "Der LXC-Name darf nicht leer sein." >&2; continue; }
  [[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "Ungültiger Name. Erlaubt sind Buchstaben, Zahlen, Punkt und Bindestrich." >&2; continue; }
  break
done''', s)

# Storage selections: retry if not found.
s = re.sub(r'''ROOTFS_STORAGE="\$\(frage_standard 'Container-Speicher' "\$DEFAULT_ROOTFS_STORAGE"\)"\npvesm status 2>/dev/null \| awk 'NR>1 \{print \$1\}' \| grep -Fxq "\$ROOTFS_STORAGE" \|\| fehler "Speicher '\$ROOTFS_STORAGE' wurde nicht gefunden\."''', '''while true; do
  ROOTFS_STORAGE="$(frage_standard 'Container-Speicher' "$DEFAULT_ROOTFS_STORAGE")"
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$ROOTFS_STORAGE" && break
  echo "Speicher '$ROOTFS_STORAGE' wurde nicht gefunden. Bitte erneut wählen." >&2
done''', s)
s = re.sub(r'''TEMPLATE_STORAGE="\$\(frage_standard 'Template-Speicher' "\$DEFAULT_TEMPLATE_STORAGE"\)"\npvesm status 2>/dev/null \| awk 'NR>1 \{print \$1\}' \| grep -Fxq "\$TEMPLATE_STORAGE" \|\| fehler "Speicher '\$TEMPLATE_STORAGE' wurde nicht gefunden\."''', '''while true; do
  TEMPLATE_STORAGE="$(frage_standard 'Template-Speicher' "$DEFAULT_TEMPLATE_STORAGE")"
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_STORAGE" && break
  echo "Speicher '$TEMPLATE_STORAGE' wurde nicht gefunden. Bitte erneut wählen." >&2
done''', s)

# Resources: retry each field independently.
old = '''CORES="$(frage_standard 'CPU-Kerne' "$DEFAULT_CORES")"
RAM="$(frage_standard 'RAM in MB' "$DEFAULT_RAM")"
SWAP="$(frage_standard 'Swap in MB' "$DEFAULT_SWAP")"
DISK_GB="$(frage_standard 'Festplattengröße in GB' "$DEFAULT_DISK")"
for pair in "CPU:$CORES" "RAM:$RAM" "Swap:$SWAP" "Festplatte:$DISK_GB"; do
  name="${pair%%:*}"; value="${pair#*:}"
  [[ "$value" =~ ^[0-9]+$ ]] || fehler "$name muss numerisch sein."
done
(( CORES >= 1 )) || fehler "Mindestens ein CPU-Kern wird benötigt."
(( RAM >= 512 )) || fehler "Mindestens 512 MB RAM werden benötigt."
(( DISK_GB >= 4 )) || fehler "Mindestens 4 GB Festplattenspeicher werden benötigt."'''
new = '''while true; do
  CORES="$(frage_standard 'CPU-Kerne' "$DEFAULT_CORES")"
  [[ "$CORES" =~ ^[0-9]+$ ]] && (( CORES >= 1 )) && break
  echo "CPU-Kerne müssen eine Zahl größer oder gleich 1 sein." >&2
done
while true; do
  RAM="$(frage_standard 'RAM in MB' "$DEFAULT_RAM")"
  [[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 )) && break
  echo "RAM muss numerisch und mindestens 512 MB sein." >&2
done
while true; do
  SWAP="$(frage_standard 'Swap in MB' "$DEFAULT_SWAP")"
  [[ "$SWAP" =~ ^[0-9]+$ ]] && break
  echo "Swap muss numerisch sein." >&2
done
while true; do
  DISK_GB="$(frage_standard 'Festplattengröße in GB' "$DEFAULT_DISK")"
  [[ "$DISK_GB" =~ ^[0-9]+$ ]] && (( DISK_GB >= 4 )) && break
  echo "Die Festplattengröße muss numerisch und mindestens 4 GB sein." >&2
done'''
s = s.replace(old, new)

# Bridge and network mode.
s = re.sub(r'''BRIDGE="\$\(frage_standard 'Netzwerk-Bridge' "\$DEFAULT_BRIDGE"\)"\nip link show "\$BRIDGE" >/dev/null 2>&1 \|\| fehler "Die Bridge '\$BRIDGE' existiert auf diesem Proxmox-Host nicht\."''', '''while true; do
  BRIDGE="$(frage_standard 'Netzwerk-Bridge' "$DEFAULT_BRIDGE")"
  ip link show "$BRIDGE" >/dev/null 2>&1 && break
  echo "Die Bridge '$BRIDGE' existiert auf diesem Proxmox-Host nicht." >&2
done''', s)
old = '''printf 'Netzwerkmodus [statisch/dhcp] [statisch]: '
read -r NET_MODE
NET_MODE="${NET_MODE:-statisch}"
case "$NET_MODE" in
  statisch|static) NET_MODE="static" ;;
  dhcp) NET_MODE="dhcp" ;;
  *) fehler "Netzwerkmodus muss statisch oder dhcp sein." ;;
esac'''
new = '''while true; do
  printf 'Netzwerkmodus [statisch/dhcp] [statisch]: ' > /dev/tty
  read -r NET_MODE < /dev/tty
  NET_MODE="${NET_MODE:-statisch}"
  case "$NET_MODE" in
    statisch|static) NET_MODE="static"; break ;;
    dhcp) NET_MODE="dhcp"; break ;;
    *) echo "Netzwerkmodus muss statisch oder dhcp sein." >&2 ;;
  esac
done'''
s = s.replace(old, new)

# IP / gateway / VLAN retry.
old = '''if [[ "$NET_MODE" == "static" ]]; then
  printf 'IPv4-Adresse mit CIDR (Beispiel 192.168.1.50/24): '
  read -r IP_CIDR
  [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fehler "IPv4 bitte in CIDR-Schreibweise eingeben, z. B. 192.168.1.50/24."
  printf 'IPv4-Gateway (Beispiel 192.168.1.1): '
  read -r GATEWAY
  [[ "$GATEWAY" =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}$ ]] || fehler "Ungültiges IPv4-Gateway."
fi
printf 'VLAN-ID [keine]: '
read -r VLAN_TAG
if [[ -n "$VLAN_TAG" ]]; then
  [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] || fehler "Die VLAN-ID muss numerisch sein."
  (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )) || fehler "Die VLAN-ID muss zwischen 1 und 4094 liegen."
fi'''
new = '''if [[ "$NET_MODE" == "static" ]]; then
  while true; do
    printf 'IPv4-Adresse mit CIDR (Beispiel 192.168.1.50/24): ' > /dev/tty
    read -r IP_CIDR < /dev/tty
    [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] && break
    echo "Ungültige Eingabe. Bitte die Adresse inklusive Netzmaske angeben, z. B. 192.168.51.17/24." >&2
  done
  while true; do
    printf 'IPv4-Gateway (Beispiel 192.168.1.1): ' > /dev/tty
    read -r GATEWAY < /dev/tty
    [[ "$GATEWAY" =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}$ ]] && break
    echo "Ungültiges IPv4-Gateway. Bitte erneut eingeben, z. B. 192.168.51.1." >&2
  done
fi
while true; do
  printf 'VLAN-ID [keine]: ' > /dev/tty
  read -r VLAN_TAG < /dev/tty
  [[ -z "$VLAN_TAG" ]] && break
  [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] && (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )) && break
  echo "Ungültige VLAN-ID. Erlaubt sind 1 bis 4094 oder Enter für keine VLAN-ID." >&2
done'''
s = s.replace(old, new)

# Gitea URL: add https automatically and retry.
old = '''printf 'Gitea-Basis-URL (Beispiel https://git.example.com): '
read -r GITEA_URL
GITEA_URL="${GITEA_URL%/}"
[[ "$GITEA_URL" =~ ^https?://[^[:space:]]+$ ]] || fehler "Ungültige Gitea-URL."'''
new = '''while true; do
  printf 'Gitea-Basis-URL (Beispiel git.example.com): ' > /dev/tty
  read -r GITEA_URL < /dev/tty
  GITEA_URL="${GITEA_URL%/}"
  [[ -n "$GITEA_URL" ]] || { echo "Die Gitea-URL darf nicht leer sein." >&2; continue; }
  if [[ ! "$GITEA_URL" =~ ^https?:// ]]; then
    GITEA_URL="https://$GITEA_URL"
    echo "https:// wurde automatisch ergänzt: $GITEA_URL" >&2
  fi
  [[ "$GITEA_URL" =~ ^https?://[^[:space:]]+$ ]] && break
  echo "Ungültige Gitea-URL. Bitte z. B. git.example.com oder https://git.example.com eingeben." >&2
done'''
s = s.replace(old, new)

# Required secrets/IDs: retry instead of aborting.
old = '''printf 'Gitea-Zugriffstoken: '
read -r -s GITEA_TOKEN
echo
[[ -n "$GITEA_TOKEN" ]] || fehler "Ein Gitea-Zugriffstoken wird benötigt."'''
new = '''while true; do
  printf 'Gitea-Zugriffstoken: ' > /dev/tty
  read -r -s GITEA_TOKEN < /dev/tty
  echo > /dev/tty
  [[ -n "$GITEA_TOKEN" ]] && break
  echo "Ein Gitea-Zugriffstoken wird benötigt. Bitte erneut eingeben." >&2
done'''
s = s.replace(old, new)
old = '''printf 'OpenAI Secure MCP Tunnel-ID (tunnel_...): '
read -r OPENAI_TUNNEL_ID
[[ "$OPENAI_TUNNEL_ID" =~ ^tunnel_[0-9A-Za-z_-]+$ ]] || fehler "Ungültige OpenAI-Tunnel-ID."'''
new = '''while true; do
  printf 'OpenAI Secure MCP Tunnel-ID (tunnel_...): ' > /dev/tty
  read -r OPENAI_TUNNEL_ID < /dev/tty
  [[ "$OPENAI_TUNNEL_ID" =~ ^tunnel_[0-9A-Za-z_-]+$ ]] && break
  echo "Ungültige OpenAI-Tunnel-ID. Bitte erneut eingeben." >&2
done'''
s = s.replace(old, new)
old = '''printf 'OpenAI Tunnel Runtime API-Key: '
read -r -s OPENAI_TUNNEL_API_KEY
echo
[[ -n "$OPENAI_TUNNEL_API_KEY" ]] || fehler "Ein OpenAI Tunnel Runtime API-Key wird benötigt."'''
new = '''while true; do
  printf 'OpenAI Tunnel Runtime API-Key: ' > /dev/tty
  read -r -s OPENAI_TUNNEL_API_KEY < /dev/tty
  echo > /dev/tty
  [[ -n "$OPENAI_TUNNEL_API_KEY" ]] && break
  echo "Ein OpenAI Tunnel Runtime API-Key wird benötigt. Bitte erneut eingeben." >&2
done'''
s = s.replace(old, new)

p.write_text(s)
PY
exec bash "$TMP"
