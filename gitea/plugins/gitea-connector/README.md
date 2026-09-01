# Gitea Connector Runtime

Interner MCP-Connector für eine selbstgehostete Gitea-Instanz hinter dem zentralen Bratonien-MCP.

## Runtime-Modell

```text
zentraler Bratonien MCP
   ↓ service_token
Gitea Connector :8101
   ↓ GITEA_TOKEN
Gitea /api/v1/*
```

Der Connector ist kein öffentlicher MCP-Endpunkt und veröffentlicht keine eigene OAuth-Konfiguration. Der OpenAI Secure MCP Tunnel sowie die öffentliche MCP-Authentifizierung gehören ausschließlich zum zentralen Bratonien-MCP aus `Terranom674/Proxmox_Scripts/mcp`.

## Konfiguration

```bash
GITEA_URL=https://git.example.com
GITEA_TOKEN=...
MCP_HTTP_TOKEN=...
MCP_BIND_ADDRESS=127.0.0.1
MCP_PORT=8101
MCP_CONTAINER_NAME=gitea-mcp
```

- `GITEA_URL`: Basis-URL ohne `/api/v1`
- `GITEA_TOKEN`: serverseitiges Gitea-Zugriffstoken für die gewünschten Projektoperationen
- `MCP_HTTP_TOKEN`: interner Service-Token zwischen zentralem MCP und Connector
- `MCP_BIND_ADDRESS`: im Produktivbetrieb `127.0.0.1`
- `MCP_PORT`: standardmäßig `8101`

Der Gitea-Token wird nie als ChatGPT-Bearer verwendet oder an ChatGPT weitergereicht.

## MCP

- Endpoint: `/mcp`
- Health: `/health`
- Transport: stateless Streamable HTTP
- Namespace am zentralen Host: `gitea__`

## Scope

Der Connector deckt Repositories, Dateien, Branches, Commits, Issues, Pull Requests, Reviews, Tags, Releases und einen sicherheitsgefilterten Katalog weiterer Gitea-Projektoperationen ab.

Nicht exponiert werden insbesondere Passwort-, Token-, Secret-, Benutzeradministrations-, Permission-, Runner- und Webhook-Verwaltung.

Der Operations-Katalog umfasst 221 gefilterte Operationen aus der getesteten Gitea-1.24.5-Oberfläche.

## Lokale Prüfung

```bash
python3 -m unittest discover -s tests -v
```

Keine GitHub Actions; Build- und Laufzeitprüfungen erfolgen lokal bzw. im Installationspfad.

Siehe außerdem `docs/architecture.md` und `docs/tool-contracts.md`.
