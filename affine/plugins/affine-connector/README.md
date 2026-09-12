# AFFiNE Connector

ChatGPT-Plugin und MCP-/API-Connector für AFFiNE über den zentralen Bratonien-MCP.

## Abdeckung

Der Connector deckt zwei Ebenen ab:

1. **Native AFFiNE-MCP-Oberfläche:** `tools/list` und `tools/call` werden dynamisch an AFFiNE weitergereicht. Damit werden sämtliche aktuell und künftig vom verbundenen AFFiNE-Workspace veröffentlichten MCP-Tools automatisch unter `affine__*` verfügbar.
2. **AFFiNE HTTP API:** Das zusätzliche Tool `api_call` kann jeden relativen Pfad unter `/api/*` auf derselben AFFiNE-Instanz mit GET, HEAD, POST, PUT, PATCH, DELETE oder OPTIONS aufrufen. Damit sind auch API-Funktionen erreichbar, die AFFiNE nicht als natives MCP-Tool veröffentlicht.

Der Connector führt keine statische Whitelist einzelner AFFiNE-Endpunkte. Die Einschränkung auf denselben Host und `/api/*` verhindert dagegen, dass der generische Proxy für fremde Ziele missbraucht wird.

## Native MCP-Basis

Für die Bratonien-READ_WRITE-Installation werden mindestens diese Werkzeuge verlangt:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`
- `trash_document`
- `restore_document`
- `delete_document`

Weitere native Tools werden automatisch übernommen.

Die Lifecycle-Tools verwenden AFFiNEs vorhandenen nativen Dokument-Lifecycle (`apply_doc_lifecycle`) und müssen AFFiNEs eigene Workspace- und Dokumentberechtigungen einhalten.

## Authentifizierung

MCP und normale API verwenden getrennte Credentials. Das `aff_mcp_v1...`-Credential ist für den nativen Workspace-MCP bestimmt und wird von AFFiNE nicht als allgemeines API-Credential behandelt.

Serverseitige Konfiguration:

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-mcp-credential>
AFFINE_API_AUTH_HEADER=Authorization
AFFINE_API_AUTH_VALUE=Bearer <api-credential>
MCP_HTTP_TOKEN=<interner-service-token>
```

`AFFINE_API_AUTH_HEADER` kann bei einer anders authentifizierten Self-Hosted-Installation auch beispielsweise `Cookie` sein. Das Credential bleibt ausschließlich auf der MCP-Infrastruktur und kann durch ChatGPT weder gelesen noch überschrieben werden.

## API-Tool

`api_call` akzeptiert:

- `method`
- `path` unter `/api/*`
- optional `query`
- optional zusätzliche ungefährliche Header
- optional `body` oder `body_base64`

Antworten werden als JSON/Text zurückgegeben; binäre Antworten werden Base64-kodiert. Authorization, Cookie und Host können nicht vom Aufrufer überschrieben werden.

## ChatGPT-Plugin

`.mcp.json` verweist ausschließlich auf den zentralen Bratonien-MCP unter `https://mcp.bratonien.de/mcp`. AFFiNE-Secrets befinden sich nicht im Plugin.

## Sicherheit

AFFiNE bleibt die Quelle für Authentifizierung und Berechtigungen. Der Connector erzeugt keine eigenen AFFiNE-Rechte. Es werden keine GitHub Actions verwendet und kein automatisches Deployment eingerichtet.
