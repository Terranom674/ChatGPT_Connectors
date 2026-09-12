# AFFiNE Connector Runtime

Interner MCP-Adapter zwischen dem zentralen Bratonien-MCP und dem nativen MCP-Endpunkt einer selbstgehosteten AFFiNE-Instanz.

Der Adapter erfindet keine eigene Dokument-API. `tools/list` und `tools/call` werden an AFFiNE weitergereicht. Dadurch bleiben Tool-Schemas, Workspace-Zuordnung und effektive Berechtigungen bei AFFiNE.

## Erwartete AFFiNE-Tools

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`

Der Connector gilt nur dann als betriebsbereit, wenn alle fünf Werkzeuge über das konfigurierte READ_WRITE-Credential sichtbar sind.

## Konfiguration

Die produktive `.env` wird vom Installer erzeugt und nicht im Repository gespeichert. Benötigt werden:

- `AFFINE_URL`
- `AFFINE_WORKSPACE_ID`
- `AFFINE_MCP_TOKEN`
- `MCP_HTTP_TOKEN`

Der lokale Connector lauscht standardmäßig ausschließlich auf `127.0.0.1:8104` und wird vom zentralen Bratonien-MCP unter der Connector-ID `affine` eingebunden. Der zentrale Host veröffentlicht die nativen AFFiNE-Werkzeuge dadurch als `affine__*`.

## Sicherheit

Das AFFiNE-MCP-Credential bleibt ausschließlich in der geschützten `.env` des Connectors. Der zentrale MCP spricht den Adapter mit einem separaten internen Service-Token an. Für ChatGPT wird wiederum ein eigener App-Token erzeugt, der ausschließlich auf den Connector `affine` begrenzt ist.
