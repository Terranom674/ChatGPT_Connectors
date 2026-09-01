# LinkStack Connector

Vollständiger ChatGPT-/MCP-Connector für die Bratonien-LinkStack-REST-API.

Der Connector folgt derselben Architektur wie der Manifold-Connector: Er läuft als eigener interner MCP-Connector im zentralen Bratonien-MCP-LXC und spricht die bestehende LinkStack-Instanz ausschließlich über deren öffentliche HTTPS-API unter `/api/v1/*` an.

## Struktur

```text
linkstack/
├── README.md
├── install/
│   └── register-with-bratonien-mcp.sh
└── plugins/
    └── linkstack-connector/
        ├── .codex-plugin/
        │   └── plugin.json
        ├── .env.example
        ├── .mcp.json
        ├── Dockerfile
        ├── docker-compose.yml
        ├── http_server.py
        ├── management_surface.py
        ├── operations.py
        ├── README.md
        └── server.py
```

## Architektur

```text
ChatGPT
   ↓
zentraler Bratonien MCP
   ↓  linkstack__*
LinkStack MCP Connector
   ↓  Authorization: Bearer ls_...
LinkStack /api/v1/*
   ↓
API Access / Fine-Grained Permissions
   ↓
LinkStack
```

Der Connector kennt die vollständige API-Oberfläche. Die effektiven Rechte werden ausschließlich in LinkStack an der API Application vergeben. Werden Rechte später erweitert oder entzogen, muss weder der Connector noch die ChatGPT-App neu gebaut werden.

## Installation

Der Registrierungsinstaller ist für die Proxmox-Host-Shell ausgelegt:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/linkstack/install/register-with-bratonien-mcp.sh)
```

Er fragt nach:

- CT-ID des bestehenden zentralen Bratonien-MCP-LXC
- öffentlicher HTTPS-URL der LinkStack-Instanz
- einem gültigen Bratonien-LinkStack-API-Token (`ls_...`)

Vor der Installation wird `/api/v1/status` mit dem angegebenen Token geprüft. Danach wird der Connector lokal auf `127.0.0.1:8103` installiert, unter dem Namespace `linkstack__` im zentralen MCP registriert und über den zentralen Host erneut geprüft.

## LinkStack API

Die zugrunde liegende API wird im Repository `Proxmox_Scripts` unter `linkstack/api/` installiert und gepflegt. Der Connector setzt voraus, dass diese API auf der Zielinstanz bereits installiert und abgeschlossen ist.

Die API deckt unter anderem Profil, Links, Themes, Assets, Analytics, Benutzer, Instanzeinstellungen, Import/Export, Backups, Reports sowie die eigene API-Application-/Token-/Audit-Verwaltung ab.

## Berechtigungen

LinkStack liefert bei fehlenden Fine-Grained-Rechten `403` inklusive `required_permission`. Der MCP versucht nicht, diese Entscheidung selbst nachzubilden oder zu umgehen.

## GitHub Actions

Für diesen Connector werden keine GitHub Actions verwendet. Build- und Laufzeitprüfungen erfolgen lokal bzw. bei der gezielt ausgeführten Installation.
