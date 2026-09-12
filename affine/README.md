# AFFiNE Connector

Status: **In Aufbau**

Eigenständiger ChatGPT-/MCP-Connector für die selbstgehostete AFFiNE-Instanz der Bratonien-Infrastruktur.

Der Connector folgt demselben Betriebsmodell wie LinkStack: Er läuft als eigener interner MCP-Dienst im zentralen Bratonien-MCP-LXC, besitzt einen eigenen Namespace und eigene Service-/App-Tokens und wird über einen Proxmox-Installer registriert.

## Struktur

```text
affine/
├── README.md
├── install/
│   ├── register-with-bratonien-mcp.sh
│   └── update-connector.sh
└── plugins/
    └── affine-connector/
        ├── .codex-plugin/
        │   └── plugin.json
        ├── .env.example
        ├── .mcp.json
        ├── Dockerfile
        ├── docker-compose.yml
        ├── http_server.py
        ├── README.md
        └── server.py
```

## Architektur

```text
ChatGPT
   ↓
zentraler Bratonien MCP
   ↓  affine__*
AFFiNE MCP Connector
   ↓  Authorization: Bearer aff_mcp_v1...
AFFiNE /api/workspaces/<workspaceId>/mcp
   ↓
Workspace- und Dokumentberechtigungen
   ↓
AFFiNE
```

Der Connector baut keine parallele AFFiNE-Dokument-API. Er nutzt AFFiNEs nativen MCP-Endpunkt als Upstream. `tools/list` und `tools/call` werden dynamisch an AFFiNE weitergereicht. Damit bleiben Tool-Schemas, Workspace-Zuordnung und effektive Dokumentberechtigungen bei AFFiNE selbst.

## Erwartete Tools

Für den vorgesehenen READ_WRITE-Betrieb müssen über AFFiNE sichtbar sein:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`

Der zentrale Bratonien-MCP veröffentlicht sie nach der Registrierung als:

- `affine__read_document`
- `affine__doc_search`
- `affine__create_document`
- `affine__update_document`
- `affine__update_document_meta`

## Voraussetzungen auf AFFiNE-Seite

AFFiNE koppelt den nativen MCP an Copilot. Deshalb muss `copilot.enabled=true` aktiv sein.

Für Stable wird zusätzlich der separate Patch aus `Terranom674/Affine-MCP-Patch` verwendet. Er erweitert ausschließlich die vorhandenen MCP-Write-Gates um `AFFINE_MCP_WRITE_ENABLED=true`; die bestehende READ_WRITE-Prüfung und AFFiNEs interne Berechtigungsprüfungen bleiben erhalten.

Vor der Registrierung muss in AFFiNE unter den Workspace-Einstellungen ein MCP-Credential mit **READ_WRITE** erstellt werden. Dieses Credential gehört zu genau einem Workspace.

## Installation

Der Installer wird wie beim LinkStack-Connector aus der Proxmox-Host-Shell gestartet:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/affine/install/register-with-bratonien-mcp.sh)
```

Er fragt nach:

- CT-ID des bestehenden zentralen Bratonien-MCP-LXC
- öffentlicher HTTPS-URL der AFFiNE-Instanz
- AFFiNE Workspace-ID
- AFFiNE MCP-Token mit READ_WRITE

Der Token wird verdeckt eingegeben und anschließend nicht ausgegeben.

Vor der Installation ruft der Installer den echten AFFiNE-MCP-Endpunkt mit `tools/list` auf. Die Registrierung wird nur fortgesetzt, wenn alle fünf erwarteten Read-/Search-/Write-Tools tatsächlich von AFFiNE ausgeliefert werden. Damit prüft der Installer nicht nur, ob ein Patch im Bundle steht, sondern die reale MCP-Antwort der laufenden AFFiNE-Instanz.

Danach wird der Connector im MCP-LXC unter `/opt/connectors/affine` installiert, als eigener Docker-Dienst auf `127.0.0.1:8104` gestartet und mit der Connector-ID `affine` beim zentralen MCP registriert.

Für die drei Ebenen werden getrennte Credentials verwendet:

1. AFFiNE MCP-Credential: Connector → AFFiNE
2. interner Service-Token: zentraler MCP → AFFiNE Connector
3. MCP-App-Token: ChatGPT → zentraler MCP, ausschließlich für `affine`

Nach der Registrierung prüft der Installer die vollständige `affine__*`-Tooloberfläche über den zentralen MCP und kontrolliert zusätzlich, dass der AFFiNE-App-Token keinen Zugriff auf den LinkStack-Namespace erhält.

## Update

Eine bestehende Installation kann aktualisiert werden mit:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/affine/install/update-connector.sh)
```

Der Updater behält die vorhandene `.env` und damit das AFFiNE-MCP-Credential, ersetzt nur die Connector-Dateien, baut den Container neu und prüft anschließend sowohl den lokalen Connector als auch die über den zentralen MCP sichtbaren AFFiNE-Tools.

## Sicherheit und Berechtigungen

- Das AFFiNE-MCP-Credential wird nicht im Repository gespeichert.
- Die produktive `.env` liegt geschützt im MCP-LXC.
- AFFiNE bleibt die Quelle für Workspace- und Dokumentberechtigungen.
- Der Connector erfindet keine eigenen Schreibrechte und umgeht keine AFFiNE-Permissions.
- Der ChatGPT-App-Token wird im zentralen MCP ausschließlich auf den Connector `affine` begrenzt.
- Keine GitHub Actions.

## Status

Der Connector-Code, Installer und Updatepfad sind vorbereitet. Der Status bleibt bis zur realen Installation und zum erfolgreichen End-to-End-Test auf **In Aufbau**. Danach wird er in der Haupt-README auf **Aktiv** gesetzt.
