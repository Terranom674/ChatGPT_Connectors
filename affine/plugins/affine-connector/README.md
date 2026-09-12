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

`tools/list` und `tools/call` werden dynamisch an AFFiNE weitergereicht. Neue native AFFiNE-MCP-Tools werden deshalb automatisch durch den Connector veröffentlicht und müssen nicht einzeln im Adapter nachgebaut werden.

Für die Bratonien-READ_WRITE-Installation werden mindestens diese nativen AFFiNE-Tools verlangt:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`
- `trash_document`
- `restore_document`
- `delete_document`

Die drei Lifecycle-Tools werden durch `Terranom674/Affine-MCP-Patch` aus AFFiNEs bereits vorhandenem nativen Dokument-Lifecycle bereitgestellt. Sie delegieren an AFFiNEs eigenes `apply_doc_lifecycle` und umgehen keine Workspace- oder Dokumentberechtigungen.

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

Die Lifecycle-Erweiterung nutzt AFFiNEs eigenen Backend-Runtime-Pfad und damit dieselben Berechtigungsprüfungen wie AFFiNE selbst.

Es werden keine GitHub Actions verwendet.
