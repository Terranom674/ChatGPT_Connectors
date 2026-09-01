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
- CT-ID des LinkStack-LXC
- öffentlicher HTTPS-URL der LinkStack-Instanz

Ein LinkStack-API-Token muss nicht manuell erzeugt oder eingegeben werden.

Der Installer prüft zunächst die öffentliche Bratonien-LinkStack-API. Anschließend provisioniert er direkt im LinkStack-LXC die dedizierte API Application `Bratonien ChatGPT / LinkStack Connector` und erzeugt dafür ein eigenes einmalig verwendbares `ls_...`-Token. Existiert diese Application bereits, wird sie wiederverwendet; vorhandene aktive Connector-Tokens mit dem Namen `Bratonien MCP Connector` werden widerrufen und durch ein neues Token ersetzt.

Die Application erhält die aktuell bekannte vollständige Connector-Berechtigungsmatrix. Read-only-Bereiche wie Analytics, Diagnostics, API Audit und Metadaten bleiben auf `read`; administrierbare Bereiche erhalten `write`. Die Berechtigungen können anschließend im LinkStack-Adminbereich jederzeit reduziert oder erweitert werden. Die Rechteentscheidung bleibt vollständig bei LinkStack.

Das erzeugte Token wird nicht interaktiv angezeigt. Es wird vom Installer geschützt direkt in den MCP-LXC übertragen und dort ausschließlich in der Connector-`.env` gespeichert.

Der Installer prüft das neu erzeugte Token über den authentifizierten Endpunkt `/api/v1/me`. Erst danach wird der Connector lokal auf `127.0.0.1:8103` installiert, unter dem Namespace `linkstack__` im zentralen MCP registriert und über den zentralen Host erneut mit `linkstack__me` geprüft.

## LinkStack API

Die zugrunde liegende API wird im Repository `Proxmox_Scripts` unter `linkstack/api/` installiert und gepflegt. Der Connector setzt voraus, dass diese API auf der Zielinstanz bereits installiert und abgeschlossen ist.

Die API deckt unter anderem Profil, Links, Themes, Assets, Analytics, Benutzer, Instanzeinstellungen, Import/Export, Backups, Reports sowie die eigene API-Application-/Token-/Audit-Verwaltung ab.

## Berechtigungen

LinkStack liefert bei fehlenden Fine-Grained-Rechten `403` inklusive `required_permission`. Der MCP versucht nicht, diese Entscheidung selbst nachzubilden oder zu umgehen.

Der Connector wird bei der Erstinstallation mit seiner vollständigen bekannten Berechtigungsmatrix provisioniert. Danach ist LinkStack die alleinige Quelle für die tatsächlich erlaubten Rechte. Neu hinzukommende Permissions werden bewusst nicht stillschweigend freigeschaltet.

## GitHub Actions

Für diesen Connector werden keine GitHub Actions verwendet. Build- und Laufzeitprüfungen erfolgen lokal bzw. bei der gezielt ausgeführten Installation.
