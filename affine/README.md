# AFFiNE Connector

Status: **In Aufbau**

Eigenständiger ChatGPT-/MCP-Connector für die selbstgehostete AFFiNE-Instanz der Bratonien-Infrastruktur.

Wichtig: Dieser Ordner enthält **zwei getrennte Ebenen**:

1. das **ChatGPT-Plugin** unter `plugins/affine-connector/`
2. die **serverseitige AFFiNE-Anbindung** an den zentralen Bratonien-MCP unter `install/`

Das ChatGPT-Plugin wird **nicht über Proxmox installiert**. Es folgt demselben Plugin-Muster wie Gitea und LinkStack: `.codex-plugin/plugin.json` beschreibt das Plugin und `.mcp.json` verweist auf den bereits bestehenden zentralen MCP-Endpunkt `https://mcp.bratonien.de/mcp`.

Workspace-ID und AFFiNE-MCP-Credential gehören ausschließlich zur serverseitigen Anbindung und niemals in das ChatGPT-Plugin.

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

## ChatGPT-Plugin

Das Plugin verbindet ChatGPT ausschließlich mit:

```text
https://mcp.bratonien.de/mcp
```

Die eigentliche AFFiNE-Verbindung bleibt hinter dem zentralen MCP verborgen. ChatGPT benötigt daher weder AFFiNE-URL noch Workspace-ID noch AFFiNE-MCP-Token.

## Architektur

```text
ChatGPT Plugin
   ↓
https://mcp.bratonien.de/mcp
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

Der zentrale Bratonien-MCP veröffentlicht sie als `affine__*`.

## Voraussetzungen auf AFFiNE-Seite

AFFiNE koppelt den nativen MCP an Copilot. Deshalb muss `copilot.enabled=true` aktiv sein.

Für Stable wird zusätzlich der separate Patch aus `Terranom674/Affine-MCP-Patch` verwendet. Er erweitert ausschließlich die vorhandenen MCP-Write-Gates um `AFFINE_MCP_WRITE_ENABLED=true`; die bestehende READ_WRITE-Prüfung und AFFiNEs interne Berechtigungsprüfungen bleiben erhalten.

Die serverseitige Anbindung benötigt ein AFFiNE-MCP-Credential mit **READ_WRITE** für den gewünschten Workspace. Dieses Credential bleibt ausschließlich auf der MCP-Infrastruktur.

## Serverseitige Registrierung

Die Skripte unter `install/` sind **kein ChatGPT-Plugin-Installer**. Sie dienen ausschließlich dazu, den internen AFFiNE-Adapter auf der Bratonien-MCP-Infrastruktur zu registrieren bzw. zu aktualisieren.

Dabei werden getrennte Credentials verwendet:

1. AFFiNE MCP-Credential: interner Connector → AFFiNE
2. interner Service-Token: zentraler MCP → AFFiNE Connector
3. MCP-App-Token: ChatGPT → zentraler MCP, ausschließlich für `affine`

## Sicherheit und Berechtigungen

- Das AFFiNE-MCP-Credential wird nicht im Repository gespeichert.
- AFFiNE bleibt die Quelle für Workspace- und Dokumentberechtigungen.
- Der Connector erfindet keine eigenen Schreibrechte und umgeht keine AFFiNE-Permissions.
- Das ChatGPT-Plugin enthält keine AFFiNE-Secrets.
- Keine GitHub Actions.

## Status

Der Plugin-Teil ist strukturell vorhanden. Der Gesamtstatus bleibt bis zur realen serverseitigen Registrierung und zum erfolgreichen End-to-End-Test auf **In Aufbau**. Danach wird AFFiNE in der Haupt-README auf **Aktiv** gesetzt.
