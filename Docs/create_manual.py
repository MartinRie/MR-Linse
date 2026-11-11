"""Build the German user guide (requires reportlab)."""
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, white
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph
from reportlab.lib.styles import ParagraphStyle

ROOT = Path(__file__).resolve().parent.parent
font = Path('/System/Library/Fonts/Supplemental/Arial.ttf')
bold = font.with_name('Arial Bold.ttf')
if not font.exists():
    font = Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
    bold = font.with_name('DejaVuSans-Bold.ttf')
pdfmetrics.registerFont(TTFont('Body', str(font)))
pdfmetrics.registerFont(TTFont('Bold', str(bold)))
pdfmetrics.registerFontFamily('Body', normal='Body', bold='Bold', italic='Body', boldItalic='Bold')
W, H = 595.28, 841.89
c = canvas.Canvas(str(ROOT/'Docs/MR-Linse-Bedienungsanleitung.pdf'), pagesize=(W,H))
c.setTitle('MR-Linse 0.3.0 | Bedienungsanleitung')
c.setAuthor('MR-Linse')
ink, teal, gray = '#182B35', '#087E80', '#567079'
def text(s, x, top, size=11, color=ink, bold=False):
    c.setFillColor(HexColor(color)); c.setFont('Bold' if bold else 'Body',size); c.drawString(x,H-top,s)
def para(s, top, x=52, width=491, size=11, color=ink):
    p=Paragraph(s,ParagraphStyle('body',fontName='Body',fontSize=size,leading=size*1.45,textColor=HexColor(color)))
    _,h=p.wrap(width,700);p.drawOn(c,x,H-top-h)
    assert top+h<778, 'Content exceeds page: '+s[:70]
    return top+h
def base(n, label, title, subtitle):
    c.setFillColor(white);c.rect(0,0,W,H,fill=1,stroke=0)
    text('MR-Linse',52,42,12,teal,True);text(label.upper(),350,42,9,gray)
    text(title,52,104,28,ink,True);para(subtitle,124,size=12,color=gray)
    c.setStrokeColor(HexColor('#DCE7E8'));c.line(52,49,543,49)
    text('Version 0.3.0 · Stand 11.11.2026',52,H-32,8,gray)
    text(f'{n:02d} / 06',504,H-32,8,gray)
def section(title, body, top):
    text(title,52,top,15,ink,True)
    return para(body,top+13)+26
def box(title,body,top,height=92):
    c.setFillColor(HexColor('#EAF5F3'));c.roundRect(52,H-top-height,491,height,12,fill=1,stroke=0)
    text(title,68,top+24,12,teal,True);para(body,top+36,x=68,width=459,size=10.5)
    return top+height+30

base(1,'Der schnelle Einstieg','Kleine Details. Groß im Bild.','Deine Soulear-Kamera als digitale Lupe am Mac.')
c.drawImage(str(ROOT/'SoulearLupe/Artwork/Linsli.png'),52,H-310,width=120,height=120,mask='auto')
text('MR-Linse',202,224,32,ink,True)
para('Livebild, ruhige Ausrichtung und Fotos.<br/>Mit Kameraprofilen, Lichtschalter und automatischer Wiederverbindung.',246,x=202,width=330,size=12)
y=box('Neu: die Verbindung bleibt im Blick','Nach einem Ausfall versucht die App automatisch, die Kamera wieder zu erreichen. Ein bewusster Stopp beendet weitere Versuche. Zoom und Ausrichtung bleiben je Profil gespeichert.',348,105)
y=section('Das brauchst du','Mac mit Apple Silicon (M1 oder neuer), macOS 13 oder neuer und eine kompatible Soulear/i4season-Kamera. Für USB zusätzlich einen ESP32-C3 SuperMini und ein USB-Datenkabel.',y)
y=section('Schnellstart','Kamera einschalten, C3 per USB anschließen und MR-Linse öffnen. USB als Quelle wählen, Firmware prüfen bzw. aktualisieren und <b>Verbinden</b> klicken.',y)
para('<b>Wichtig bei diesem Update:</b> Einmal die neue C3-Firmware in der App installieren. Sie ermöglicht Kameraprofile und die Abfrage des Lichtzustands.',y,color=teal)
c.showPage()

base(2,'Verbinden','USB oder Kamera-WLAN','Der USB-Weg hält das WLAN deines Macs für das Internet frei.')
y=section('1 · App öffnen','Download-ZIP entpacken und MR-Linse.app in den Programme-Ordner ziehen. Bei einer macOS-Startsperre unter <b>Systemeinstellungen → Datenschutz &amp; Sicherheit</b> die Freigabe prüfen. Die App ist nicht Apple-notarisiert. Den Zugriff auf das lokale Netzwerk erlauben, falls macOS danach fragt.',202)
y=section('2 · Kamera vorbereiten','Kamera einschalten. Ihre Handy-App schließen, falls sie gerade verbunden ist. Das Profil <b>Meine Soulear</b> ist mit Soulear-79144 und 192.168.1.1 vorbelegt.',y)
y=section('3A · Empfohlen: C3 über USB','C3 per Datenkabel verbinden. Unter <b>Verbindung</b> den Eintrag <b>USB · cu.usbmodem…</b> wählen. Firmwareprüfung abwarten und auf <b>Verbinden</b> klicken. Die App überträgt WLAN-Name und IP aus dem Profil und wartet auf die Bestätigung des C3.',y)
y=box('So fließt das Bild','Kamera → WLAN → C3 → USB → Mac.<br/>Der Mac bleibt im Heim-WLAN; der C3 verbindet sich mit dem WLAN der Kamera.',y,85)
y=section('3B · Direkt per WLAN','Mac mit dem im Profil angegebenen Kamera-WLAN verbinden. In MR-Linse <b>Kamera-WLAN</b> als Quelle wählen und <b>Verbinden</b> klicken. Die erkannte Adresse erscheint unter Gerät. Das Kamera-WLAN selbst liefert kein Internet.',y)
para('Die Heimrouter-Adresse ist nicht die Kamera-Adresse. Bei der bisherigen Kamera ist die Kamera-IP normalerweise 192.168.1.1.',y,size=10.5,color=gray)
c.showPage()

base(3,'C3 & Profile','Einmal einrichten. Weiter nutzen.','Neue WLAN-Namen lassen sich jetzt direkt in der App speichern.')
y=section('Firmware installieren','USB-Quelle wählen und die Prüfung abwarten. Bei <b>Firmware aktuell</b> verschwindet das Installationssymbol. Andernfalls im Bereich <b>Gerät</b> auf das Download-Symbol klicken und <b>Installieren</b> bestätigen. Vorher die Verbindung beenden.',200)
y=box('Installation ersetzt das Board-Programm','Das USB-Kabel bis zum Abschluss eingesteckt lassen. Die automatische Prüfung kann den C3 kurz neu starten. Es wird keine Firmware ohne deine Bestätigung installiert.',y,91)
y=section('Profil bearbeiten oder ergänzen','Unter <b>Kamera → Profil bearbeiten …</b> einen Namen, den exakten WLAN-Namen und die Kamera-IP eintragen. <b>Speichern</b> ändert das gewählte Profil; <b>Als neues Profil</b> legt ein weiteres an. Bei mehreren Profilen lässt sich eines löschen. Profile nur bei beendeter Verbindung wechseln.',y)
y=section('Was wird gespeichert?','Der Mac merkt sich Profile sowie Zoom, Bildausschnitt, Spiegelung, Drehung und Auto-Drehung je Profil. Der C3 speichert den zuletzt übertragenen WLAN-Namen und die Kamera-IP. Nach einem Neustart nutzt er diese Werte wieder.',y)
box('Kompatibilität','Profile unterstützen kompatible Soulear/i4season-Kameras mit offenem WLAN. Passwortgeschützte Netze und andere Kameraprotokolle sind noch nicht implementiert. Ein neuer Profilname macht eine beliebige Kamera nicht kompatibel.',y,104)
c.showPage()

base(4,'Bild & Licht','Dein Bild im Griff','Die runde Bildfläche bleibt stehen, während das Bild darin gedreht wird.')
y=200
for title,body in [
('Zoom und Ausrichtung','Mit <b>Plus/Minus</b> digital zwischen 1× und 4× zoomen. Scrollen oder eine Trackpad-Vergrößerungsgeste zoomt am Mauszeiger. <b>Auto-Drehung</b> nutzt die Kamerasensoren. Manuell lässt sich in 90°-Schritten drehen oder horizontal spiegeln.'),
('Kameralicht','Den nativen Schiebeschalter <b>Kameralicht</b> bedienen. Nach dem ersten Bild fragt die App den Zustand ab. Während des Lesens oder Schaltens ist der Schalter kurz gesperrt. <b>Licht an/aus</b> zeigt eine bestätigte Antwort; <b>Zustand unbestätigt</b> kennzeichnet eine fehlende Rückmeldung.'),
('Standbild und Vollbild','Pause-Schaltfläche oder <b>Leertaste</b> hält das Bild an. Erneut drücken setzt das Livebild fort; die Übertragung läuft im Hintergrund weiter. Die Vollbild-Schaltfläche vergrößert das Fenster.'),
('Foto speichern','Auf das Kamera-Symbol klicken und den Speicherort wählen. <b>Aktuelle Ansicht</b> übernimmt Zoom, Drehung, Spiegelung und den runden Ausschnitt. <b>Kameraoriginal</b> speichert das unveränderte Kamera-JPEG.')]:
 y=section(title,body,y)
box('Ein Foto in Ruhe auswählen','Erst den Bildausschnitt einstellen, dann Standbild aktivieren und speichern. Die aktuelle Ansicht ist ein quadratisches JPEG mit schwarzem Bereich außerhalb des Kreises.',y,88)
c.showPage()

base(5,'Verbindung & Hilfe','Nach einem Ausfall','Die App versucht es erneut, solange du die Verbindung nicht beendest.')
y=200
for title,body in [
('Wiederverbinden','Bei USB-Trennung oder ausbleibenden Bildern stoppt der Empfänger und versucht es mit zunehmendem Abstand erneut (bis 15 Sekunden zwischen Versuchen). Bei mehreren erkannten USB-Geräten den richtigen Anschluss manuell auswählen. <b>Verbindung beenden</b> stoppt die Versuche.'),
('Kein USB-Gerät oder kein Bild','Datenfähiges Kabel verwenden, Kamera laden/einschalten und Handy-App schließen. WLAN-Name und IP im Profil prüfen. Andere Programme schließen, die den seriellen USB-Port benutzen.'),
('„C3-Firmware aktualisieren“','Die Brücke hat das Kameraprofil nicht bestätigt. Die neue Firmware über das Installationssymbol in der App installieren. Falls nötig: BOOT gedrückt halten, RESET kurz drücken, BOOT loslassen und den USB-Anschluss neu auswählen.'),
('Direktes WLAN antwortet nicht','Mac mit dem Kamera-WLAN verbinden und die Quelle Kamera-WLAN wählen. Netzwerkfreigabe für MR-Linse prüfen. Die im Profil hinterlegte Kamera-IP muss stimmen.'),
('Bild steht still oder wirkt verzögert','Standbild prüfen, Abstand zwischen Kamera und C3 verkleinern. Die Anzeige <b>Verarbeitung … ms</b> misst nur vom vollständigen JPEG am Mac bis zur Übergabe an die Ansicht, nicht die Verzögerung von Sensor, WLAN und Bildschirm.')]:
 y=section(title,body,y)
c.showPage()

base(6,'Updates & Downloads','Neue Versionen ganz einfach','Für Nutzer in der App. Für die Entwicklung automatisch auf GitHub.')
y=section('In der App nach Updates suchen','Im Menü <b>MR-Linse → Nach Updates suchen …</b> das neueste stabile öffentliche Release prüfen. Optional <b>Automatisch nach Updates suchen</b> einschalten: Prüfung beim Start, höchstens einmal täglich. Ohne Internet bleiben automatische Prüfungen still.',200)
y=section('Eine neue App-Version installieren','Bei einer neuen Version erscheinen Änderungsnotizen und <b>Update herunterladen</b>. Der Browser lädt das ZIP. Danach MR-Linse beenden, ZIP entpacken und die App im Programme-Ordner ersetzen. Ein C3-Update wird weiterhin separat in der App bestätigt.',y)
y=box('Bei einem lokalen Build','Unter <b>Updatequelle …</b> Benutzer/Repository eintragen, beispielsweise MartinRie/MR-Linse. GitHub-Builds tragen ihre Quelle automatisch ein. Private Repositories werden nicht unterstützt.',y,95)
y=section('Als Entwickler veröffentlichen','Für die nächste Version die Datei <b>SoulearLupe/VERSION</b> erhöhen und RELEASE_NOTES.md aktualisieren. In GitHub Desktop committen und <b>Push origin</b> klicken. Nach erfolgreichem Build erstellt GitHub Tag, Release und Downloads automatisch.',y)
para('Tags und Releases nicht mehr von Hand anlegen. Bestehende vollständige Releases werden nicht überschrieben. Die neue Version muss höher sein. Weitere Details stehen in README.md und GITHUB.md.',y,color=gray)
c.save()
print(ROOT/'Docs/MR-Linse-Bedienungsanleitung.pdf')
