# MR-Linse auf GitHub bauen

## Was aktuell moeglich ist

Die App verwendet Swift/AppKit sowie CoreWLAN, IOKit und Darwin. Sie ist derzeit eine reine macOS-App. Anders als der JUCE-basierte WarmSix-Editor kann sie nicht unveraendert unter Windows oder Linux gebaut werden. Dafuer ist eine Portierung von Oberflaeche, Netzwerk-/USB-Zugriff und Firmware-Installer notwendig; weitere Runner in einer YAML reichen nicht.

Der Workflow baut macOS fuer Apple Silicon (M1 und neuer, macOS 13+), einschliesslich des eingebetteten ARM64-esptool. Intel-Macs sind mit diesem Paket nicht unterstuetzt. Die C3-Firmware wird aus dem Quellcode gebaut und in die App kopiert.

## Upload

Den INHALT des Ordners `Lupe` als Repository-Wurzel verwenden:

```
.github/workflows/build.yml
.gitignore
GITHUB.md
README.md
Docs/MR-Linse-Bedienungsanleitung.pdf
SoulearLupe/
  Package.swift
  build_app.sh
  Sources/
  Artwork/
  FlashResources/
  C3-Bruecke/platformio.ini
  C3-Bruecke/src/
```

Auch die versteckten Dateien `.github` und `.gitignore` muessen hochgeladen werden. Am einfachsten geht das mit GitHub Desktop und dem Ordner Lupe als lokalem Repository. Vorhandene .app-Pakete, .pio-tools, .pio und .build werden durch .gitignore ausgeschlossen. Quellcode, Icon und FlashResources inklusive esptool und boot_app0.bin muessen enthalten sein.

Falls stattdessen SoulearLupe selbst die Repository-Wurzel sein soll: .github, .gitignore, Docs und diese Anleitung dorthin kopieren. Der Workflow erkennt beide Strukturen.

## Bauen und herunterladen

- Push auf main/master oder Pull Request: automatischer Build.
- Manuell: Actions > Build MR-Linse > Run workflow.
- Nach erfolgreichem Build: unter Artifacts das Paket herunterladen. Es enthaelt MR-Linse-macOS-arm64.zip , MR-Linse-C3-Firmware.zip und die PDF-Bedienungsanleitung.
- Ein GitHub-Release mit Publish release veroeffentlichen: derselbe Workflow baut den Stand des Release-Tags und haengt beide ZIP-Dateien und die PDF-Bedienungsanleitung an das Release an.

Die Firmware steckt schon in der Mac-App. Ein GitHub-Build flasht keine angeschlossene Hardware.

## Signatur und Pruefung

Die App wird ad-hoc signiert, aber nicht mit einem Apple-Developer-Zertifikat signiert oder notarisiert. macOS kann daher beim Start einer heruntergeladenen App eine Freigabe in Systemeinstellungen > Datenschutz & Sicherheit verlangen.

CI prueft den Build, die eingebetteten Firmwaredateien, den Start des Flash-Tools und die Bundle-Signatur. Kamera, USB-Uebertragung und Firmware-Flash muessen weiterhin an echter Hardware getestet werden. Ein erfolgreicher Cloud-Lauf ist erst nach dem Upload in GitHub Actions bestaetigt.

## Versionen und Updatequelle

`SoulearLupe/VERSION` enthält die App-Version. Release-Tags müssen exakt `v` plus diese Version sein (z. B. `v0.2.2`). Der Workflow prüft diese Übereinstimmung und trägt `GITHUB_REPOSITORY` als Updatequelle in die App ein. Die App prüft öffentliche stabile Releases und bietet nur das fertige Paket `MR-Linse-macOS-arm64.zip` an. Vorabversionen sind ausgeschlossen. Details zur Bedienung stehen in der README.

## Veröffentlichung v0.2.2

1. Den vorbereiteten Commit auf main pushen.
2. Auf GitHub in SoulearLupe/VERSION prüfen: 0.2.2.
3. Ein neues Release mit dem NEUEN Tag v0.2.2 auf main veröffentlichen.
4. Den erfolgreichen Build abwarten. Alte fehlgeschlagene Releases müssen nicht erneut gestartet werden.
