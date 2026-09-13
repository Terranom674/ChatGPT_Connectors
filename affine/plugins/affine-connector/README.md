# AFFiNE Connector

Ein einzelner ChatGPT-/MCP-Connector fuer die selbstgehostete AFFiNE-Instanz ueber den zentralen Bratonien-MCP.

## Grundprinzip

ChatGPT kennt genau **einen** AFFiNE-Connector. Dieser Connector reicht die native Workspace-MCP-Oberflaeche der verbundenen AFFiNE-Instanz dynamisch durch.

Es gibt keinen zweiten Login-Pfad, keinen Cookie-/JWT-Nebenkanal und keine eigene Socket.IO-Implementierung im Connector.

## Erwartete AFFiNE-MCP-Werkzeuge

Der Connector gilt nur dann als gesund, wenn upstream mindestens diese sechs Dokumentwerkzeuge vorhanden sind:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`
- `delete_document`

Weitere native AFFiNE-MCP-Tools werden automatisch durchgereicht.

Die ersten fuenf Werkzeuge stammen unveraendert aus AFFiNE Stable. `delete_document` wird durch den Self-Hosted-MCP-Patch in denselben bereits authentifizierten READ_WRITE-MCP-Kontext aufgenommen und verwendet AFFiNEs bestehende `Doc.Delete`-Berechtigungspruefung.

## Authentifizierung

Der Connector benoetigt fuer AFFiNE genau den bereits vorhandenen Workspace-MCP-Credential:

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-mcp-credential>
MCP_HTTP_TOKEN=<interner-service-token>
```

Es werden **keine** zusaetzlichen AFFiNE-Benutzerzugangsdaten, Cookies oder API-JWTs benoetigt.

## Verhalten

- `tools/list` wird an AFFiNE weitergereicht.
- `tools/call` wird an AFFiNE weitergereicht.
- Die externe Tool-Oberflaeche wird vom zentralen Bratonien-MCP als `affine__*` veroeffentlicht.
- Delete laeuft durch denselben MCP-Credential und denselben Workspace-Kontext wie Create/Update.

## Sicherheit und Deployment

- AFFiNE bleibt Quelle fuer Authentifizierung und Berechtigungen.
- Keine AFFiNE-Secrets im ChatGPT-Plugin oder Repository.
- Keine GitHub Actions.
- Kein automatisches Deployment.
- Der Updater bricht ab, wenn eines der sechs erforderlichen Dokumentwerkzeuge fehlt.
