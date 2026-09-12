# AFFiNE Connector

ChatGPT-Plugin und MCP-Connector für AFFiNE über den zentralen Bratonien-MCP.

## ChatGPT-Plugin

Der Plugin-Teil dieses Ordners wird **nicht über Proxmox installiert**. Er folgt demselben Muster wie die bestehenden Gitea- und LinkStack-Plugins:

```text
.codex-plugin/plugin.json
.mcp.json
```

`.mcp.json` verweist auf den bereits bestehenden zentralen MCP-Endpunkt:

```text
https://mcp.bratonien.de/mcp
```

ChatGPT verbindet sich damit ausschließlich zum zentralen Bratonien-MCP. AFFiNE-Workspace-ID und AFFiNE-MCP-Credential gehören **nicht** in das ChatGPT-Plugin und werden dort auch nicht abgefragt oder gespeichert.

## Serverseitiger Connector

Hinter dem zentralen Bratonien-MCP läuft ein interner AFFiNE-Adapter. Dieser verbindet den Namespace `affine__*` mit dem nativen MCP-Endpunkt der selbstgehosteten AFFiNE-Instanz.

Der Adapter erfindet keine eigene Dokument-API. `tools/list` und `tools/call` werden an AFFiNE weitergereicht. Dadurch bleiben Tool-Schemas, Workspace-Zuordnung und effektive Berechtigungen bei AFFiNE.

Erwartete native AFFiNE-Tools:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`

## Serverseitige Konfiguration

Nur der interne Connector benötigt:

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-credential>
MCP_HTTP_TOKEN=<interner-service-token>
```

Diese Werte liegen ausschließlich auf der MCP-Infrastruktur. Sie werden weder in `plugin.json` noch in `.mcp.json` gespeichert.

Der lokale Adapter lauscht standardmäßig auf `127.0.0.1:8104`; der zentrale MCP veröffentlicht seine Tools unter `affine__*`.

## Sicherheit

Das AFFiNE-MCP-Credential bleibt serverseitig. ChatGPT erhält keinen direkten AFFiNE-Token und keinen direkten Zugriff auf den nativen AFFiNE-MCP-Endpunkt.

Es werden keine GitHub Actions verwendet.
