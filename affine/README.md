# AFFiNE Connector

Status: **In Aufbau**

Eigenständiger ChatGPT-/MCP-Connector für die selbstgehostete AFFiNE-Instanz der Bratonien-Infrastruktur.

## Ziel

Der Connector soll den nativen AFFiNE-MCP-Endpunkt in den zentralen Bratonien-MCP integrieren. Dabei soll nach Möglichkeit die von AFFiNE selbst bereitgestellte MCP-Implementierung genutzt werden, statt eine parallele proprietäre Schreib-/Lese-API nachzubauen.

## Aktueller Stand

Die AFFiNE-Instanz läuft auf der Stable-Version und der native MCP-Endpunkt ist erreichbar.

Der native MCP bietet derzeit mindestens folgende Werkzeuge:

- `read_document`
- `doc_search`
- `create_document`
- `update_document`
- `update_document_meta`

AFFiNE liefert die Write-Tools upstream nur im Modus `READ_WRITE` und zusätzlich nur in Dev/Canary aus. Für die selbstgehostete Stable-Instanz existiert deshalb der separate Patch im Repository:

- `Terranom674/Affine-MCP-Patch`

Dieser Patch erweitert ausschließlich die vorhandenen MCP-Write-Gates um `AFFINE_MCP_WRITE_ENABLED=true`. Die bestehende `READ_WRITE`-Prüfung sowie die internen AFFiNE-Berechtigungsprüfungen bleiben bestehen.

Zusätzlich ist `copilot.enabled=true` erforderlich, da AFFiNE den MCP-Bereich an die Copilot-Verfügbarkeit koppelt.

## Authentifizierung

AFFiNE verwendet eigene MCP-Credentials. Ein Credential gehört zu genau einem Workspace und besitzt einen Access Mode:

- `READ_ONLY`
- `READ_WRITE`

Der MCP-Endpunkt erwartet einen Bearer-Token:

```text
POST /api/workspaces/<workspaceId>/mcp
Authorization: Bearer <AFFiNE-MCP-Token>
```

Ein Aufruf ohne gültiges Credential liefert erwartungsgemäß `401 Authentication failed`.

## Geplante Architektur

```text
ChatGPT
   ↓
zentraler Bratonien MCP
   ↓  affine__*
AFFiNE Connector
   ↓  Streamable HTTP + Bearer Credential
AFFiNE /api/workspaces/<workspaceId>/mcp
   ↓
Workspace- und Dokumentberechtigungen
   ↓
AFFiNE
```

## Grundsätze

- AFFiNE bleibt die Quelle für Workspace-, Dokument- und Benutzerberechtigungen.
- Der Connector soll keine eigenen Schreibrechte erfinden oder AFFiNE-Berechtigungen umgehen.
- Secrets und MCP-Tokens werden nicht im Repository gespeichert.
- Der Connector soll unabhängig von den anderen Connector-Ordnern betreibbar sein.
- Keine GitHub Actions.
- Änderungen am AFFiNE-Core werden nicht in diesem Connector-Ordner gepflegt. Der notwendige Stable-MCP-Write-Patch bleibt im separaten `Affine-MCP-Patch`-Repository.

## Nächste Schritte

1. AFFiNE-MCP-Credential mit `READ_WRITE` erzeugen.
2. `tools/list` gegen den realen MCP-Endpunkt prüfen.
3. AFFiNE im zentralen Bratonien-MCP registrieren.
4. Namensraum und Tool-Mapping für `affine__*` festlegen.
5. Installer/Updater und lokale Tests ergänzen.

Der Connector wird erst auf **Aktiv** gesetzt, wenn die reale Verbindung mit einem AFFiNE-MCP-Credential erfolgreich getestet und im zentralen MCP registriert ist.
