# MR-Linse automatisch veröffentlichen

## Aktueller Stand: v0.3.0

In GitHub Desktop alle Änderungen committen und **Push origin** klicken. Der Workflow baut, testet und veröffentlicht anschließend automatisch die Mac-App, C3-Firmware und PDF-Anleitung.

**Tags und Releases nicht mehr manuell anlegen.** Eine vorhandene vollständig veröffentlichte Version bleibt unverändert. Die App und die C3-Firmware werden niemals durch einen GitHub-Lauf auf lokaler Hardware installiert.

## Spätere Versionen

1. `SoulearLupe/VERSION` erhöhen, zum Beispiel auf `0.3.1`.
2. `RELEASE_NOTES.md` aktualisieren.
3. Commit und Push auf main.

Der Tag wird aus VERSION erzeugt und auf genau den gebauten Commit gesetzt. App, Firmware und PDF müssen vorhanden sein, bevor veröffentlicht wird. Bei einem Uploadfehler denselben Workflow erneut ausführen; ein passender Entwurf wird fortgesetzt. Ein vorhandener Tag auf einem anderen Commit oder ein bereits unvollständig veröffentlichtes Release erfordert eine neue Versionsnummer.

## Projekt hochladen

Die Repository-Wurzel enthält `.github`, `.gitignore`, `Docs`, `SoulearLupe`, `README.md`, `GITHUB.md` und `RELEASE_NOTES.md`. Alle Dateien unter `.github` müssen mit hochgeladen werden. Build-Verzeichnisse, .pio-tools und .app-Dateien sind ausgeschlossen.

## Kontrolle

Unter **Actions → Build MR-Linse** müssen Build und Veröffentlichung grün sein. Danach stehen die ZIP-Dateien und die PDF unter **Releases**. Zusätzlich gibt es den Build als Artifact. Pull Requests bauen nur. Manuelle Ausführung ist möglich; automatische Veröffentlichung nur auf main/master.

Der Workflow prüft Versionslogik, Profilvalidierung, Einstellungen, Wiederverbindung, Lichtpakete, USB-Konfiguration über einen simulierten seriellen Anschluss, Bildpuffer und Release-Verhalten. Tests an echter Kamera bleiben notwendig.

Das Paket unterstützt macOS 13+ auf Apple Silicon. Windows/Linux benötigen eine Portierung. Die App ist ad-hoc signiert, aber nicht Apple-notarisiert. Für Updateabfragen muss das Release öffentlich erreichbar sein. Repository-/Organisationsregeln müssen Schreibzugriff für den Release-Job erlauben.

## C3-Firmware

Mit 0.3.0 die mitgelieferte Firmware einmal über die App installieren. WLAN-Name und IP werden anschließend aus dem gewählten Kameraprofil an den C3 übertragen. Andere Kameraprotokolle sind damit noch nicht implementiert.
