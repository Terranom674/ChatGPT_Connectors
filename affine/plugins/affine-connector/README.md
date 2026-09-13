# AFFiNE Connector

Ein einzelner ChatGPT-/MCP-Connector für die selbstgehostete AFFiNE-Instanz über den zentralen Bratonien-MCP.

## Grundprinzip

ChatGPT kennt genau **einen** AFFiNE-Connector. Der Connector kapselt intern alle nötigen AFFiNE-Zugriffswege:

1. **Native AFFiNE-MCP-Oberfläche:** `tools/list` und `tools/call` werden dynamisch an AFFiNE weitergereicht. Neue native AFFiNE-MCP-Tools werden automatisch sichtbar.
2. **AFFiNE HTTP API:** `api_call` ruft same-origin Pfade unter `/api/*` mit GET, HEAD, POST, PUT, PATCH, DELETE oder OPTIONS auf.
3. **Dokument-Lifecycle:** `trash_document`, `restore_document` und `delete_document` verwenden AFFiNEs vorhandene Sync-/Socket.IO-Schnittstellen. Dafür wird kein Lifecycle-Code in AFFiNE Core injiziert.

## Native MCP-Basis

Für die READ_WRITE-Installation werden upstream mindestens diese nativen Werkzeuge verlangt:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`

Zusätzlich veröffentlicht der Connector lokal:

- `trash_document`
- `restore_document`
- `delete_document`
- `api_call`

Damit besteht die aktuelle erwartete Oberfläche aus 9 Werkzeugen. Weitere native AFFiNE-MCP-Tools werden automatisch ergänzt.

## Authentifizierung

Das native `aff_mcp_v1...`-Credential ist absichtlich nur für AFFiNEs Workspace-MCP bestimmt. Normale AFFiNE-API- und Sync-Aufrufe verwenden AFFiNEs normale Benutzer-/Session-Authentifizierung.

Diese Trennung ist **intern im selben Connector** gekapselt. Für ChatGPT existiert weiterhin nur eine Verbindung.

Empfohlene Self-Hosted-Konfiguration:

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-mcp-credential>
AFFINE_EMAIL=<connector-account-email>
AFFINE_PASSWORD=<connector-account-password>
AFFINE_CLIENT_VERSION=0.27.0
MCP_HTTP_TOKEN=<interner-service-token>
```

Der Connector meldet sich über AFFiNEs vorhandenen `/api/auth/sign-in`-Endpunkt selbst an, hält die Session ausschließlich im Prozessspeicher und erneuert sie bei Authentifizierungsfehlern automatisch. ChatGPT erhält weder E-Mail/Passwort noch Session-Cookie.

Optional kann statt des automatischen Logins weiterhin ein bereits serverseitig verwaltetes Credential mit `AFFINE_API_AUTH_HEADER` und `AFFINE_API_AUTH_VALUE` vorgegeben werden. Das ist nur ein Override und nicht der normale Betriebsweg.

## Dokument-Lifecycle

- Trash/Restore verwenden AFFiNEs nativen `space:doc-lifecycle`-Pfad.
- Permanentes Löschen verwendet AFFiNEs nativen `space:delete-doc`-Pfad.
- AFFiNE bleibt für Authentifizierung und Berechtigungen verantwortlich.
- AFFiNE Core wird für diese Funktionen nicht erweitert.

## API-Tool

`api_call` akzeptiert `method`, `path` unter `/api/*`, optional `query`, zusätzliche ungefährliche Header sowie `body` oder `body_base64`. Authorization, Cookie und Host können vom Aufrufer nicht überschrieben werden.

## ChatGPT-Plugin

`.mcp.json` verweist ausschließlich auf den zentralen Bratonien-MCP unter `https://mcp.bratonien.de/mcp`. AFFiNE-Secrets befinden sich nicht im Plugin.

## Sicherheit und Deployment

- AFFiNE bleibt Quelle für Authentifizierung und Berechtigungen.
- Keine AFFiNE-Secrets im ChatGPT-Plugin oder Repository.
- Keine GitHub Actions.
- Kein automatisches Deployment.
- Repository-Änderungen werden ausschließlich über den vorhandenen manuellen Updater ausgerollt.
