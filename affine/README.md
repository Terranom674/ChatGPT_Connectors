# AFFiNE Connector

Status: **In Aufbau**

Eigenständiger ChatGPT-/MCP-Connector für die selbstgehostete AFFiNE-Instanz der Bratonien-Infrastruktur.

## Ziel

Der AFFiNE-Connector soll die **vollständige erreichbare AFFiNE-Oberfläche** abdecken:

1. sämtliche nativen MCP-Tools des verbundenen Workspace werden dynamisch über `tools/list` und `tools/call` veröffentlicht;
2. zusätzlich stellt der Connector mit `api_call` einen kontrollierten Passthrough auf sämtliche relativen AFFiNE-HTTP-Endpunkte unter `/api/*` bereit, damit Funktionen nutzbar bleiben, die AFFiNE nicht als MCP-Tool veröffentlicht.

Es gibt keine statische Liste, die zusätzliche native MCP-Tools abschneidet. Neue AFFiNE-MCP-Tools werden automatisch sichtbar.

## Architektur

```text
ChatGPT Plugin
   ↓
https://mcp.bratonien.de/mcp
   ↓  affine__*
AFFiNE Connector
   ├─ native MCP → /api/workspaces/<workspaceId>/mcp/
   └─ API proxy  → /api/*
   ↓
AFFiNE
```

MCP- und normale API-Authentifizierung sind getrennt. Das native `aff_mcp_v1...`-Credential bleibt auf den Workspace-MCP beschränkt; normale `/api/*`-Aufrufe verwenden ein separat serverseitig konfiguriertes AFFiNE-API-/Session-Credential.

## Native MCP-Basis

Für den READ_WRITE-Betrieb werden mindestens folgende Tools vorausgesetzt:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`
- `trash_document`
- `restore_document`
- `delete_document`

Weitere native Tools werden automatisch weitergereicht.

Die Lifecycle-Tools verwenden AFFiNEs nativen Dokument-Lifecycle und müssen dieselben Workspace- und Dokumentberechtigungen einhalten wie AFFiNE selbst.

## API-Abdeckung

Das lokale Tool `api_call` akzeptiert HTTP-Methoden GET, HEAD, POST, PUT, PATCH, DELETE und OPTIONS für Pfade unter `/api/*` derselben AFFiNE-Instanz. Fremde Hosts sind ausgeschlossen. Authentifizierungs-, Host- und Cookie-Header können durch den Aufrufer nicht überschrieben werden.

## Serverkonfiguration

```env
AFFINE_URL=https://affine.example.com
AFFINE_WORKSPACE_ID=<workspace-id>
AFFINE_MCP_TOKEN=<read-write-mcp-credential>
AFFINE_API_AUTH_HEADER=Authorization
AFFINE_API_AUTH_VALUE=Bearer <api-credential>
MCP_HTTP_TOKEN=<interner-service-token>
```

Je nach Self-Hosted-Authentifizierung kann `AFFINE_API_AUTH_HEADER` auch beispielsweise `Cookie` sein.

## Sicherheit

- AFFiNE bleibt Quelle für Authentifizierung und Berechtigungen.
- Keine AFFiNE-Secrets im ChatGPT-Plugin oder Repository.
- API-Proxy nur same-origin und nur unter `/api/*`.
- Keine GitHub Actions.
- Kein automatisches Deployment.

## Deployment

`install/update-connector.sh` aktualisiert den Connector auf der Bratonien-MCP-Infrastruktur und prüft anschließend die sichtbare Tool-Oberfläche. Repository-Änderungen werden bewusst **nicht automatisch** auf die laufende Infrastruktur ausgerollt.
