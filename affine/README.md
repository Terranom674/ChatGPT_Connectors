# AFFiNE Connector

Eigenstaendiger ChatGPT-/MCP-Connector fuer die selbstgehostete AFFiNE-Instanz der Bratonien-Infrastruktur.

## Ziel

Der Connector stellt ChatGPT die native Workspace-MCP-Oberflaeche von AFFiNE als `affine__*` bereit. Neue native AFFiNE-MCP-Tools werden dynamisch uebernommen.

Der Self-Hosted-Patch laesst den AFFiNE-Stable-Core bis auf den READ_WRITE-Gate unveraendert und ergaenzt genau `delete_document` innerhalb desselben authentifizierten Workspace-MCP-Kontexts.

## Architektur

```text
ChatGPT Plugin
   ↓
https://mcp.bratonien.de/mcp
   ↓  affine__*
AFFiNE Connector
   ↓  aff_mcp_v1...
AFFiNE Workspace MCP
```

Es gibt keinen zweiten AFFiNE-Login, keinen API-JWT-Nebenkanal und keine eigene Socket.IO-Implementierung im Connector.

## Erforderliche Dokumentwerkzeuge

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`
- `delete_document`

Weitere native MCP-Tools werden automatisch weitergereicht.

## Delete

`delete_document` verwendet den bereits authentifizierten MCP-Benutzer und Workspace und prueft ueber AFFiNE `Doc.Delete`, bevor irgendeine Aenderung erfolgt. Passt die erwartete Stable-Struktur beim Image-Build nicht exakt, bricht der Patch fail-closed ab.

## Serverkonfiguration

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-mcp-credential>
MCP_HTTP_TOKEN=<interner-service-token>
```

Weitere AFFiNE-Benutzercredentials sind nicht erforderlich.

## Sicherheit

- AFFiNE bleibt Quelle fuer Authentifizierung und Berechtigungen.
- Keine AFFiNE-Secrets im ChatGPT-Plugin oder Repository.
- Keine GitHub Actions.
- Kein automatisches Deployment.
- Der Connector-Updater bricht ab, wenn eines der sechs Pflichtwerkzeuge fehlt.

## Deployment

`install/update-connector.sh` aktualisiert den Connector auf der Bratonien-MCP-Infrastruktur. Repository-Aenderungen werden bewusst nicht automatisch ausgerollt.
