## Neu in 0.3.0

- Automatisch wiederverbinden nach Kamera- oder USB-Ausfällen. „Verbindung beenden“ stoppt weitere Versuche.
- Zoom, Bildausschnitt, Spiegelung, Drehung und Auto-Drehung werden je Kameraprofil gespeichert.
- Nativer Lichtschalter mit Abfrage und Bestätigung des Kamerazustands.
- Kameraprofile mit Name, WLAN-Name und IP; Übertragung an den C3 ohne erneutes Kompilieren.
- JPEG-Decodierung im Hintergrund, begrenzter Bildpuffer und Anzeige der lokalen Verarbeitung in Millisekunden.
- Automatische GitHub-Releases nach erfolgreichem Push einer neuen Versionsnummer.

**Einmalig die mitgelieferte C3-Firmware in der App installieren.** Ohne diese Firmware kann der C3 das Kameraprofil nicht bestätigen. Für USB bitte einen ESP32-C3 SuperMini verwenden.

Profile unterstützen weiterhin nur kompatible Soulear/i4season-Kameras mit offenem WLAN. Andere Kameraprotokolle sind noch nicht implementiert. Das Mac-Paket ist für Apple Silicon und macOS 13 oder neuer. Die gemessene Verarbeitungszeit umfasst nicht die Verzögerung im Kamerasensor oder WLAN.
