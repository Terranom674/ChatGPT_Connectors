# AFFiNE Connector

Ein einzelner ChatGPT-/MCP-Connector für die selbstgehostete AFFiNE-Instanz über den zentralen Bratonien-MCP.

## Grundprinzip

ChatGPT kennt genau **einen** AFFiNE-Connector. Der Connector reicht sämtliche nativen AFFiNE-MCP-Tools dynamisch über `tools/list` und `tools/call` weiter.

## Native MCP-Basis

AFFiNE veröffentlicht aktuell nativ:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`

Der Bratonien-Patch verändert ausschließlich die vorhandenen READ_WRITE-Gates; er fügt keine neuen AFFiNE-MCP-Tools und keine Lifecycle-Logik hinzu.

## Authentifizierung

Das `aff_mcp_v1...`-Credential ist ausschließlich für `/api/workspaces/<workspaceId>/mcp/` vorgesehen. AFFiNE schließt diesen Tokentyp ausdrücklich von der normalen JWT-/Session-Authentifizierung aus. Der Connector fordert daher **keine AFFINE_EMAIL/AFFINE_PASSWORD-Zugangsdaten an und speichert keine Benutzerpasswörter**.

Normale `/api/*`- und Socket.IO-Aufrufe können nur verwendet werden, wenn die Installation bereits separat eine gültige serverseitige AFFiNE-API-/Session-Authentifizierung bereitstellt. Das ist optional und nicht Bestandteil des nativen MCP-Credentials.

## Dokument-Lifecycle

AFFiNE besitzt intern `space:doc-lifecycle` und `space:delete-doc`, veröffentlicht diese Funktionen aber derzeit nicht als native Workspace-MCP-Tools. Solange ausschließlich das bestehende `aff_mcp_v1...`-Credential verwendet wird und AFFiNE Core unverändert bleibt, kann ein externer Connector diese Session-geschützten Lifecycle-Endpunkte nicht legitim mit dem MCP-Credential aufrufen.

Der Connector darf deshalb keine zweite Anmeldung vortäuschen und keine Benutzerzugangsdaten verlangen.

## API-Tool

`api_call` ist nur mit bereits vorhandener serverseitiger normaler AFFiNE-Authentifizierung nutzbar. Der MCP-Token wird dafür nicht zweckentfremdet.

## Sicherheit und Deployment

- AFFiNE bleibt Quelle für Authentifizierung und Berechtigungen.
- Keine AFFiNE-Benutzerpasswörter im Connector.
- Keine Secrets im ChatGPT-Plugin oder Repository.
- Keine GitHub Actions.
- Kein automatisches Deployment.
- Repository-Änderungen werden ausschließlich über den vorhandenen manuellen Updater ausgerollt.
