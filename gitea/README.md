# Gitea Connector

Eigenständiger Gitea-Connector für den zentralen Bratonien-MCP.

## Architektur

Der zentrale MCP-Host wird ausschließlich über den Helper in `Terranom674/Proxmox_Scripts/mcp/install.sh` installiert. Dieses Repository installiert keinen eigenen MCP-Host und keinen eigenen Secure Tunnel.

```text
ChatGPT
   ↓
OpenAI Secure MCP Tunnel
   ↓
zentraler Bratonien MCP
   ↓ gitea__*
Gitea Connector
   ↓ serverseitiger GITEA_TOKEN
Gitea API
```

Der Gitea-Connector entspricht damit dem Manifold-/LinkStack-Modell:

- eigener interner Connector-Container
- eigener interner Service-Token zwischen Host und Connector
- eigener App-Token am zentralen MCP
- eigener Namespace `gitea__`
- keine Änderung der globalen MCP-Authentifizierung
- kein Forwarding des externen ChatGPT-Bearers an Gitea
- keine eigene Tunnel- oder MCP-Host-Installation

## Installation

Zuerst wird der zentrale MCP über den Proxmox-Helper installiert:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Terranom674/Proxmox_Scripts/main/mcp/install.sh)
```

Danach wird der Gitea-Connector aus der Proxmox-Host-Shell registriert:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/gitea/install/register-with-bratonien-mcp.sh)
```

Der Registrierungsinstaller fragt nach:

- CT-ID des bestehenden Bratonien-MCP-LXC
- Gitea-Basis-URL
- Gitea-Zugriffstoken

Er prüft den Gitea-Zugang über `/api/v1/user`, überträgt die Zugangsdaten geschützt in den MCP-LXC, installiert den Connector nach `/opt/connectors/gitea`, startet ihn auf `127.0.0.1:8101`, registriert ihn als `gitea` und prüft anschließend den Namespace sowie einen read-only Repository-Call über den zentralen MCP.

## Zugangsdaten

`GITEA_TOKEN` bleibt ausschließlich im internen Connector und wird nicht an ChatGPT weitergegeben. Der zentrale MCP kommuniziert mit dem Connector über `GITEA_CONNECTOR_HTTP_TOKEN`. Für die ChatGPT-/App-Seite wird der auf Gitea beschränkte Host-Token `MCP_GITEA_HTTP_TOKEN` verwendet.

## Connector-Dateien

Die Runtime liegt unter `plugins/gitea-connector/` und enthält MCP-Transport, Gitea-Client, Operations-Katalog, Docker-Konfiguration, Dokumentation und lokale Tests.

## Tests

```bash
cd plugins/gitea-connector
python3 -m unittest discover -s tests -v
```

Es werden keine GitHub Actions verwendet. Prüfungen erfolgen lokal bzw. durch den Installer auf der Zielumgebung.

## Scope

Der Connector stellt die sicherheitsgefilterte Gitea-Projektoberfläche bereit, unter anderem Repositories, Dateien, Branches, Commits, Issues, Pull Requests, Reviews, Tags und Releases. Passwort-, Token-, Secret-, Benutzeradministrations-, Permission-, Runner- und Webhook-Verwaltung bleiben ausgeschlossen.
