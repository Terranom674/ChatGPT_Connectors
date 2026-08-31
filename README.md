# ChatGPT Connectors

Sammlung eigenständiger ChatGPT-/MCP-Connectoren für die Bratonien-Infrastruktur.

Dieses Repository ist bewusst als **Sammel-Repository** aufgebaut. Jeder Connector liegt vollständig in einem eigenen Ordner und bringt dort seine gesamte Implementierung, Dokumentation, Konfiguration, Tests und benötigten Hilfsdateien mit. Connectoren dürfen sich nicht darauf verlassen, dass Dateien oder Abhängigkeiten eines anderen Connector-Ordners vorhanden sind.

Die Repository-Hauptebene dient ausschließlich als übersichtlicher Einstieg und als Verzeichnis der enthaltenen Connectoren. **Dieses Repository ist die kanonische Quelle der Bratonien-ChatGPT-Connectoren.** Frühere Einzel-Repositories werden nach abgeschlossener Migration nur noch als private Legacy-/Archivquellen geführt.

## Connectoren

| Ordner | Dienst | Status | Beschreibung |
| --- | --- | --- | --- |
| [`gitea/`](gitea/) | Gitea | Aktiv | Eigenständiger ChatGPT-/MCP-Connector für selbstgehostetes Gitea mit Runtime, Shared-MCP-Integration, OAuth-Helfer, Skills, Tests und Dokumentation. |
| [`manifold/`](manifold/) | Manifold | Aktiv | Eigenständiger ChatGPT-/MCP-Connector für selbstgehostetes Manifold mit vollständiger API-Verwaltungsoberfläche, Runtime, Installer und Bratonien-MCP-Integration. |

## Grundprinzip

Jeder Connector ist ein in sich abgeschlossenes Teilprojekt. Dadurch kann ein einzelner Connector unabhängig entwickelt, geprüft, ausgeliefert, aktualisiert oder auf einen anderen MCP-Host übernommen werden, ohne dabei andere Connectoren mitzuführen.

Ein Connector-Ordner enthält deshalb selbst alle zu ihm gehörenden Bestandteile, beispielsweise:

```text
<connector>/
├── README.md
├── src/
├── tests/
├── config/
├── docs/
└── scripts/
```

Die tatsächlich benötigte Struktur darf je nach Connector erweitert werden. Nicht benötigte Verzeichnisse werden nicht künstlich angelegt. Entscheidend ist, dass sämtliche connector-spezifischen Dateien innerhalb seines eigenen Ordners bleiben.

## Verbindliche Trennung

- Keine gemeinsam genutzte Connector-Implementierung auf Repository-Hauptebene.
- Keine Abhängigkeit eines Connectors von Dateien eines anderen Connector-Ordners.
- Zugangsdaten, Tokens, Passwörter und andere Secrets werden nicht im Repository gespeichert.
- Connector-spezifische Konfiguration gehört in den jeweiligen Connector-Ordner.
- Dokumentation zur Installation, Konfiguration, Berechtigung und Verwendung gehört in die README bzw. Dokumentation des jeweiligen Connectors.
- Tests müssen zum jeweiligen Connector gehören und dürfen dessen Grenzen nicht verlassen.
- Änderungen an einem Connector sollen keinen Neuaufbau anderer Connectoren erforderlich machen.

## GitHub Actions

Dieses Repository verwendet **keine GitHub Actions** für Builds, Tests, Deployments oder automatische Prüfungen.

Prüfungen und Builds werden bewusst lokal bzw. auf der dafür vorgesehenen Zielumgebung ausgeführt. Dadurch entstehen keine unnötigen GitHub-Actions-Laufzeiten, Artefakte oder zusätzlichen Datenmengen.

## Verwendung

Vor Installation oder Änderung eines Connectors immer dessen eigene `README.md` lesen. Dort werden die konkreten Voraussetzungen, Konfigurationswerte, Berechtigungen, Start-/Installationswege sowie die verfügbaren MCP-Werkzeuge und Ressourcen beschrieben.

## Ziel der Sammlung

Das Repository soll eine klar strukturierte, langfristig wartbare Sammlung der Bratonien-Connectoren bilden. Die Hauptebene bleibt dabei bewusst schlank: **finden, verstehen, zum richtigen Connector navigieren**. Die vollständige technische Verantwortung bleibt beim jeweiligen Connector-Ordner.
