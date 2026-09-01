# LinkStack Connector

MCP-Connector für die vollständige Bratonien-LinkStack-REST-API.

## Architektur

```text
ChatGPT
  -> zentraler Bratonien MCP
  -> LinkStack Connector
  -> https://<linkstack>/api/v1/*
  -> LinkStack API Access / Fine-Grained Permissions
  -> LinkStack
```

Der Connector trifft **keine eigene Berechtigungsentscheidung**. Er kennt die vollständige Management-Oberfläche; LinkStack entscheidet zur Laufzeit anhand der API Application und des verwendeten `ls_...`-Tokens, welche Operationen erlaubt sind.

Damit können Rechte später in LinkStack geändert werden, ohne den MCP-Connector oder die ChatGPT-App neu zu bauen.

## Konfiguration

```env
LINKSTACK_URL=https://links.example.com
LINKSTACK_TOKEN=ls_...
MCP_HTTP_TOKEN=<interner Connector-Token>
```

`LINKSTACK_URL` muss die öffentliche HTTPS-URL der LinkStack-Instanz sein. `LINKSTACK_TOKEN` ist ein von der Bratonien-LinkStack-API erzeugter Token.

## MCP-Endpunkte

- `/mcp` – stateless JSON-RPC/MCP
- `/health` – lokaler Healthcheck

Der Connector wird standardmäßig nur an `127.0.0.1:8103` gebunden und vom zentralen Bratonien-MCP angesprochen.

## Management-Oberfläche

Abgedeckt sind:

- Systemstatus, Capabilities und Diagnostics
- Profil, Profile Data und Preferences
- Themes, Assets und Social Icons
- Links, Reihenfolge, Pinning, Styling, Favicons, Link Types und Buttons
- Pages und typisierte Instanzeinstellungen
- Domains, Mail, Security, Maintenance, Logging und Advanced Config
- Analytics
- Benutzer, Status, Verifikation und Rollen
- kontrollierter Import/Export
- Bratonien API Snapshots/Backups
- Reports
- API Applications, Fine-Grained Permissions, Tokens und Audit

Zusätzlich existiert `api_call` für zukünftige API-Endpunkte. Dieser Call akzeptiert ausschließlich Pfade unter `/api/v1/`; rohe `.env`-, Datei-, PHP- oder Studio-Routen sind darüber nicht erreichbar.

## Sicherheitsgrenzen

Der Connector exponiert nicht absichtlich:

- LinkStack-Installer oder Auto-Updater
- PHPInfo
- beliebige `.env`-/Datei-/PHP-Editoren
- Session-Impersonation
- Social-OAuth-Browserflows
- native Vollarchiv-Downloads
- beliebige Theme-/PHP-Code-Uploads

Diese Grenzen entsprechen der Bratonien-LinkStack-API selbst.

## Fine-Grained Permissions

Der MCP kennt die Tools unabhängig vom aktuell vergebenen Recht. Ein fehlendes Recht bleibt eine LinkStack-Entscheidung und wird als HTTP `403` samt `required_permission` durchgereicht.

## Lokale Prüfung

Der Docker-Build kompiliert alle Python-Dateien und prüft, dass die definierte Management-Oberfläche vollständig in der MCP-Toolliste vorhanden ist.

Es werden **keine GitHub Actions** verwendet.
