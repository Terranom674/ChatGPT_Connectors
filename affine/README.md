# AFFiNE Connector

Eigenstaendiger ChatGPT-/MCP-Connector fuer die selbstgehostete AFFiNE-Instanz der Bratonien-Infrastruktur.

## Ziel

Der Connector stellt ChatGPT die native Workspace-MCP-Oberflaeche von AFFiNE als `affine__*` bereit. Neue native AFFiNE-MCP-Tools werden dynamisch uebernommen.

Fuer die Self-Hosted-READ_WRITE-Installation werden genau die fehlenden Dokument-Lifecycle-Werkzeuge durch den AFFiNE-MCP-Patch innerhalb desselben authentifizierten Workspace-MCP-Kontexts ergaenzt.

## Architektur

```text
ChatGPT Plugin
   ↓
https://mcp.bratonien.de/mcp
   ↓  affine__*
AFFiNE Connector
   ↓  aff_mcp_v1...
AFFiNE Workspace MCP
   ↓
AFFiNE native Runtime / Permissions
```

Es gibt keinen zweiten AFFiNE-Login, keinen API-JWT-Nebenkanal und keine eigene Socket.IO-Lifecycle-Implementierung im Connector.

## Erforderliche Dokumentwerkzeuge

Der Connector gilt nur dann als gesund, wenn diese acht Werkzeuge vorhanden sind:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`
- `trash_document`
- `restore_document`
- `delete_document`

Weitere native MCP-Tools werden automatisch weitergereicht.

## Serverkonfiguration

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-mcp-credential>
MCP_HTTP_TOKEN=<interner-service-token>
```

Weitere AFFiNE-Benutzercredentials sind nicht erforderlich.

## Lifecycle

Die Self-Hosted-AFFiNE-Erweiterung nutzt fuer Trash, Restore und Delete AFFiNEs vorhandenen nativen Domain-Command `apply_doc_lifecycle` mit den gleichen Permission-Aktionen wie der offizielle Sync-Gateway-Pfad:

- `Doc.Trash`
- `Doc.Restore`
- `Doc.Delete`

Die Operationen laufen mit `userId`, `workspaceId` und READ_WRITE-Zugriff des bereits authentifizierten MCP-Credentials.

## Sicherheit

- AFFiNE bleibt Quelle fuer Authentifizierung und Berechtigungen.
- Keine AFFiNE-Secrets im ChatGPT-Plugin oder Repository.
- Keine GitHub Actions.
- Kein automatisches Deployment.
- Der Connector-Updater bricht ab, wenn eines der acht Pflichtwerkzeuge fehlt.

## Deployment

`install/update-connector.sh` aktualisiert den Connector auf der Bratonien-MCP-Infrastruktur. Repository-Aenderungen werden bewusst nicht automatisch ausgerollt.
