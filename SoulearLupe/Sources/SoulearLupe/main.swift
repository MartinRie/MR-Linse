import AppKit
import UniformTypeIdentifiers
import IOKit
import IOKit.serial
import Darwin
import CoreWLAN
import SystemConfiguration

@main
enum SoulearLupeMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private let updater = AppUpdater()
    private var frozen = false
    private let freezeButton = NSButton()
    private let captureButton = NSButton()
    private let activityDot = NSView()
    private var window: NSWindow!
    private let transport = CameraTransport()
    private let lamp = NSPopUpButton()
    private var lampID: UInt16 = 0
    private var awaitingLamp: UInt16?
    private let scaleLabel = NSTextField(labelWithString: "1×")
    private let previewLock = NSLock()
    private var pendingPreview: (jpeg: Data, roll: CGFloat?, inverted: Bool?)?
    private var previewScheduled = false
    private let usb = BridgeReader()
    private let source = NSPopUpButton()
    private var preferredSource: String?
    private let flashButton = NSButton(title: "Firmware installieren …", target: nil, action: nil)
    private var flashing = false
    private var checkingFirmware = false
    private var checkedPort: String?
    private var firmwareMatches = false
    private var bridgePath: String? { source.selectedItem?.representedObject as? String }
    private let statusLabel = NSTextField(labelWithString: "Kamera-WLAN nicht geprüft")
    private let imageView = LevelImageView()
    private var sensorAngle: CGFloat?
    private var mountAngle: CGFloat = 0
    private let automatic = NSButton(checkboxWithTitle: "Auto-Drehung", target: nil, action: nil)
    private let placeholder = NSTextField(labelWithString: "Noch kein Kamerabild")
    private let ipField = NSTextField(labelWithString: "Suche …")
    private let startButton = NSButton(title: "Verbinden", target: nil, action: nil)
    private let frameLabel = NSTextField(labelWithString: "Bereit")
    private var probing = false
    private var connectRequested = false
    private var live = false
    private var latestJPEG: Data?
    private var frameCount = 0
    private var zoom: CGFloat = 1
    private var rotation: CGFloat = 0
    private var mirrored = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        updater.mayPresent = { [weak self] in
            guard let self else { return false }
            return !self.flashing && !self.checkingFirmware && self.window.attachedSheet == nil && NSApp.modalWindow == nil
        }
        updater.installMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.updater.checkAutomaticallyIfDue() }
        imageView.onZoom = { [weak self] factor, point in self?.changeZoom(factor, at: point) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil,
                  event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                  self.freezeButton.isEnabled else { return event }
            if !event.isARepeat { self.toggleFreeze() }
            return nil
        }
        transport.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.setStatus(message) }
        }
        transport.onFrame = { [weak self] jpeg, roll in
            self?.enqueuePreview(jpeg, roll: roll, inverted: nil)
        }
        transport.onStopped = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.live = false
                self.resetFreeze()
                self.awaitingLamp = nil
                self.lamp.isEnabled = false
                self.lamp.item(at: 0)?.title = "Kameralicht"
                self.source.isEnabled = true
                self.startButton.title = "Verbinden"
                self.ipField.isEnabled = true
                self.setStatus(message)
            }
        }
        usb.onFrame = { [weak self] jpeg, roll, inverted in
            self?.enqueuePreview(jpeg, roll: roll, inverted: inverted)
        }
        let reply: (Data) -> Void = { [weak self] packet in
            DispatchQueue.main.async { self?.receiveLampReply(packet) }
        }
        transport.light.reply = reply
        usb.light.reply = reply
        usb.onStopped = transport.onStopped
        refreshSources()
        discover()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refreshSources(); self?.discover() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MR-Linse"
        window.minSize = NSSize(width: 780, height: 560)
        window.center()
        window.isReleasedWhenClosed = false

        window.toolbarStyle = .unified
        window.setFrameAutosaveName("SoulearLupeWorkspace")
        let toolbar = NSToolbar(identifier: "ViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .height
        body.distribution = .fill
        body.spacing = 0
        let stage = makeViewer()
        let inspector = makeInspector()
        body.addArrangedSubview(stage)
        body.addArrangedSubview(inspector)
        inspector.widthAnchor.constraint(equalToConstant: 242).isActive = true
        stage.setContentHuggingPriority(.defaultLow, for: .horizontal)
        window.contentView = body
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("Freeze"), .init("Photo"), .init("Fullscreen")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "Freeze" {
            item.label = "Standbild"
            freezeButton.target = self
            freezeButton.action = #selector(toggleFreeze)
            freezeButton.title = ""
            freezeButton.imagePosition = .imageOnly
            freezeButton.bezelStyle = .texturedRounded
            updateFreezeButton()
            item.view = freezeButton
            return item
        }
        let photo = id.rawValue == "Photo"
        item.label = photo ? "Foto speichern" : "Vollbild"
        item.toolTip = item.label
        let control = photo ? captureButton : NSButton()
        control.image = NSImage(systemSymbolName: photo ? "camera" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: item.label)
        control.title = ""
        control.imagePosition = .imageOnly
        control.bezelStyle = .texturedRounded
        control.target = self
        control.action = photo ? #selector(savePhoto) : #selector(toggleFullscreen)
        control.toolTip = item.label
        control.setAccessibilityLabel(item.label)
        control.isEnabled = !photo || latestJPEG != nil
        item.view = control
        return item
    }

    private func makeInspector() -> NSView {
        let panel = NSVisualEffectView()
        panel.material = .sidebar
        panel.blendingMode = .withinWindow
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18)
        ])

        func add(_ view: NSView) {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        func section(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            add(label)
        }
        func rule() {
            let line = NSBox()
            line.boxType = .separator
            column.setCustomSpacing(15, after: column.arrangedSubviews.last!)
            add(line)
            column.setCustomSpacing(15, after: line)
        }
        section("Verbindung")
        source.target = self
        source.action = #selector(sourceChanged)
        source.setAccessibilityLabel("Verbindungsquelle")
        add(source)
        startButton.target = self
        startButton.action = #selector(toggleLive)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        add(startButton)
        rule()
        section("Optik")
        let zoomRow = NSStackView(views: [
            button("Verkleinern", symbol: "minus.magnifyingglass", action: #selector(zoomOut)),
            scaleLabel,
            button("Vergrößern", symbol: "plus.magnifyingglass", action: #selector(zoomIn))
        ])
        zoomRow.distribution = .fillEqually
        scaleLabel.alignment = .center
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        add(zoomRow)
        automatic.target = self
        automatic.action = #selector(updateOrientation)
        automatic.state = .on
        add(automatic)
        let orientation = NSStackView(views: [
            button("Drehen", symbol: "rotate.right", action: #selector(rotateImage)),
            button("Spiegeln", symbol: "arrow.left.and.right", action: #selector(mirrorImage))
        ])
        orientation.distribution = .fillEqually
        add(orientation)
        lamp.addItems(withTitles: ["Kameralicht", "Licht einschalten", "Licht ausschalten"])
        lamp.target = self
        lamp.action = #selector(setLamp)
        lamp.isEnabled = false
        lamp.setAccessibilityLabel("Kameralicht")
        add(lamp)
        rule()
        let device = NSStackView()
        let title = NSTextField(labelWithString: "Gerät")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        device.addArrangedSubview(title)
        device.addArrangedSubview(spacer())
        flashButton.target = self
        flashButton.action = #selector(installFirmware)
        flashButton.title = ""
        flashButton.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Firmware installieren")
        flashButton.imagePosition = .imageOnly
        flashButton.toolTip = "Firmware auf dem C3 SuperMini installieren"
        flashButton.setAccessibilityLabel("Firmware installieren")
        flashButton.bezelStyle = .rounded
        device.addArrangedSubview(flashButton)
        add(device)
        ipField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ipField.textColor = .secondaryLabelColor
        add(ipField)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 4
        statusLabel.cell?.wraps = true
        add(statusLabel)
        return panel
    }

    private func makeViewer() -> NSView {
        let stage = LensStage()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.07, blue: 0.09, alpha: 1).cgColor
        stage.layer?.cornerRadius = 0
        stage.layer?.masksToBounds = true

        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .linear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            imageView.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),
            imageView.topAnchor.constraint(equalTo: stage.topAnchor, constant: 24),
            imageView.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -24)
        ])

        placeholder.textColor = NSColor.white.withAlphaComponent(0.7)
        placeholder.font = .systemFont(ofSize: 20, weight: .medium)
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: stage.centerYAnchor)
        ])
        let readout = NSStackView(views: [activityDot, frameLabel])
        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3
        activityDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        frameLabel.textColor = .white.withAlphaComponent(0.65)
        readout.spacing = 7
        readout.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(readout)
        NSLayoutConstraint.activate([
            activityDot.widthAnchor.constraint(equalToConstant: 6),
            activityDot.heightAnchor.constraint(equalToConstant: 6),
            readout.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 20),
            readout.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -16)
        ])
        return stage
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.controlSize = .regular
        return button
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
        activityDot.layer?.backgroundColor = (live && frameCount > 0 ? NSColor.systemGreen : .systemGray).cgColor
    }

    // Both receivers publish into one slot. A busy UI presents the freshest
    // complete JPEG with its own orientation when it can draw again.
    private func enqueuePreview(_ jpeg: Data, roll: CGFloat?, inverted: Bool?) {
        previewLock.lock()
        pendingPreview = (jpeg, roll, inverted)
        let schedule = !previewScheduled
        previewScheduled = true
        previewLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in self?.presentPendingPreview() }
    }

    private func presentPendingPreview() {
        previewLock.lock()
        let frame = pendingPreview
        pendingPreview = nil
        previewScheduled = false
        previewLock.unlock()
        guard live, !frozen, let frame else { return }
        if let inverted = frame.inverted { mountAngle = inverted ? .pi : 0 }
        showFrame(frame.jpeg, roll: frame.roll)
    }

    private func showFrame(_ jpeg: Data, roll: CGFloat?) {
        guard let image = NSImage(data: jpeg) else { return }
        if let roll {
            let target = roll + mountAngle
            if let previous = sensorAngle {
                let difference = target - previous
                sensorAngle = previous + 0.4 * atan2(sin(difference), cos(difference))
            } else {
                sensorAngle = target
            }
        }
        latestJPEG = jpeg
        captureButton.isEnabled = true
        frameCount += 1
        imageView.image = image
        placeholder.isHidden = true
        frameLabel.stringValue = "\(frameCount) Bilder · lokal"
        if frameCount == 1 {
            updateFreezeButton()
            setStatus("Livebild empfangen")
            lamp.isEnabled = true
        }
        applyImageTransform()
    }

    private func updateFreezeButton() {
        let title = frozen ? "Livebild fortsetzen" : "Standbild"
        freezeButton.image = NSImage(systemSymbolName: frozen ? "play.fill" : "pause.fill", accessibilityDescription: title)
        freezeButton.toolTip = title + " (Leertaste)"
        freezeButton.setAccessibilityLabel(title)
        freezeButton.isEnabled = live && latestJPEG != nil
    }

    private func resetFreeze() {
        frozen = false
        updateFreezeButton()
    }

    @objc private func toggleFreeze() {
        guard live, latestJPEG != nil else { return }
        frozen.toggle()
        updateFreezeButton()
        frameLabel.stringValue = frozen ? "Standbild" : "Livebild"
        setStatus(frozen ? "Standbild" : "Livebild empfangen")
        activityDot.layer?.backgroundColor = (frozen ? NSColor.systemOrange : .systemGreen).cgColor
    }

    private func applyImageTransform() {
        imageView.angle = rotation - (automatic.state == .on ? sensorAngle ?? 0 : 0)
        imageView.horizontalScale = mirrored ? -zoom : zoom
        imageView.verticalScale = zoom
        imageView.needsDisplay = true

    }

    @objc private func setLamp() {
        let choice = lamp.indexOfSelectedItem
        lamp.selectItem(at: 0)
        guard live, choice > 0 else { return }
        lampID &+= 1
        let id = lampID
        awaitingLamp = id
        lamp.isEnabled = false
        lamp.item(at: 0)?.title = "Licht …"
        let channel = bridgePath == nil ? transport.light : usb.light
        channel.submit(id: id, on: choice == 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.awaitingLamp == id else { return }
            self.awaitingLamp = nil
            self.lamp.isEnabled = self.live
            self.lamp.item(at: 0)?.title = "Licht unbestätigt"
        }
    }

    private func receiveLampReply(_ data: Data) {
        guard data.count >= 15, data.prefix(4) == Data([0xee,0xff,0xee,0xff]),
              data[6] == 10, data[7] == 0, data[9] == 0, data[10] >= 3,
              awaitingLamp == UInt16(data[4]) | (UInt16(data[5]) << 8) else { return }
        awaitingLamp = nil
        lamp.item(at: 0)?.title = data[13] == 0 ? "Licht aus" : "Licht an"
        lamp.isEnabled = live
    }

    private func refreshSources() {
        guard !checkingFirmware, !flashing, !live, !connectRequested else { return }
        let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") }.sorted()
        let titles = ["Kamera-WLAN"] + ports.map { "USB · " + $0 }
        guard titles != source.itemTitles else { return }
        source.removeAllItems()
        source.addItems(withTitles: titles)
        for (index, port) in ports.enumerated() {
            source.item(at: index + 1)?.representedObject = "/dev/" + port
        }
        if let preferredSource, titles.contains(preferredSource) {
            source.selectItem(withTitle: preferredSource)
        } else if ports.count == 1 {
            source.selectItem(at: 1)
        }
        updateSourceStatus()

    }

    @objc private func sourceChanged() {
        preferredSource = source.titleOfSelectedItem
        updateSourceStatus()
    }

    private func updateSourceStatus() {
        if checkedPort != bridgePath { firmwareMatches = false; checkedPort = nil }
        flashButton.isHidden = bridgePath == nil || firmwareMatches
        if let port = bridgePath {
            ipField.stringValue = "ESP32-C3"
            if checkedPort == port && firmwareMatches {
                setStatus("Firmware aktuell")
            } else if checkedPort == nil && Self.isEspressifUSB(port) {
                checkFirmware(port)
            } else {
                setStatus("USB ausgewählt. Kamera einschalten und auf Verbinden klicken.")
            }
        } else { discover() }
    }

    // Only enter the ROM loader automatically on a native Espressif USB device.
    private static func isEspressifUSB(_ port: String) -> Bool {
        var ports: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &ports) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(ports) }
        while case let service = IOIteratorNext(ports), service != 0 {
            defer { IOObjectRelease(service) }
            let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard path == port else { continue }
            let flags = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            let vid = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault, flags) as? NSNumber
            return vid?.intValue == 0x303a
        }
        return false
    }

    private func checkFirmware(_ port: String) {
        guard !checkingFirmware, !live, !flashing else { return }
        checkingFirmware = true
        checkedPort = port
        source.isEnabled = false
        startButton.isEnabled = false
        flashButton.isEnabled = false
        setStatus("Firmware wird geprüft …")
        DispatchQueue.global(qos: .utility).async {
            let result = C3Installer.check(port: port)
            DispatchQueue.main.async {
                self.checkingFirmware = false
                self.source.isEnabled = true
                self.startButton.isEnabled = true
                self.flashButton.isEnabled = true
                self.firmwareMatches = result == .matches
                self.flashButton.isHidden = self.firmwareMatches
                switch result {
                case .matches: self.setStatus("Firmware aktuell")
                case .differs: self.setStatus("Andere Firmware installiert.")
                case .unavailable: self.setStatus("Firmwareprüfung nicht möglich. USB-Verbindung prüfen.")
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (flashing || checkingFirmware) ? .terminateCancel : .terminateNow
    }

    @objc private func installFirmware() {
        guard !flashing, !checkingFirmware else { return }
        guard !live, !connectRequested else {
            setStatus("Bitte zuerst das Livebild stoppen.")
            return
        }
        guard let port = bridgePath else {
            setStatus("SuperMini per USB anschließen und seinen USB-Anschluss auswählen.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Firmware auf das C3 SuperMini schreiben?"
        alert.informativeText = "Das Programm auf dem Board an \(port) wird durch die Kamerabrücke für Soulear-79144 ersetzt. Lass das USB-Kabel bis zum Abschluss eingesteckt."
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Installieren")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        flashing = true
        window.standardWindowButton(.closeButton)?.isEnabled = false
        source.isEnabled = false
        startButton.isEnabled = false
        flashButton.isEnabled = false
        setStatus("SuperMini wird verbunden …")
        DispatchQueue.global(qos: .userInitiated).async {
            let error = C3Installer.write(port: port) { message in
                DispatchQueue.main.async { self.setStatus(message) }
            }
            DispatchQueue.main.async {
                self.flashing = false
                self.window.standardWindowButton(.closeButton)?.isEnabled = true
                self.source.isEnabled = true
                self.startButton.isEnabled = true
                self.flashButton.isEnabled = true
                self.checkedPort = nil
                self.firmwareMatches = false
                self.refreshSources()
                self.setStatus(error == nil ? "Firmware installiert. Kamera einschalten und verbinden." : "Installation fehlgeschlagen.")
                if error == nil, self.bridgePath == port { self.checkFirmware(port) }
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Firmware konnte nicht installiert werden"
                    alert.informativeText = error + "\n\nFalls das Board nicht antwortet: BOOT gedrückt halten, RESET kurz drücken und BOOT loslassen. Dann den USB-Anschluss erneut auswählen."
                    alert.runModal()
                }
            }
        }
    }

    @objc private func toggleLive() {
        if live {
            if bridgePath != nil { usb.stop() } else { transport.stop() }
            return
        }
        if let path = bridgePath {
            live = true
            source.isEnabled = false
            sensorAngle = nil
            latestJPEG = nil
            captureButton.isEnabled = false
            imageView.image = nil
            placeholder.isHidden = false
            frameCount = 0
            startButton.title = "Livebild stoppen"
            setStatus("Warte auf Kamera über USB …")
            usb.start(path)
            return
        }
        source.isEnabled = false
        connectRequested = true
        startButton.isEnabled = false
        discover()
    }

    private func discover() {
        guard !flashing, bridgePath == nil, !live, !probing else { return }
        probing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = CameraDiscovery.lookup()
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard self.bridgePath == nil, !self.live else { self.connectRequested = false; return }
                self.ipField.stringValue = result.host ?? "—"
                self.setStatus(result.message)
                self.startButton.isEnabled = true
                if self.connectRequested, let host = result.host {
                    self.mountAngle = result.inverted ? .pi : 0
                    self.sensorAngle = nil
                    self.beginStream(host)
                }
                self.connectRequested = false
                self.source.isEnabled = !self.live
            }
        }
    }

    private func beginStream(_ address: String) {
        latestJPEG = nil
        captureButton.isEnabled = false
        imageView.image = nil
        placeholder.isHidden = false
        frameCount = 0
        frameLabel.stringValue = "UDP · \(address)"
        live = true
        startButton.title = "Livebild stoppen"
        ipField.isEnabled = false
        setStatus("Verbinde mit \(address) …")
        transport.start(host: address, videoPort: 22789)
    }

    @objc private func updateOrientation() { applyImageTransform() }
    @objc private func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc private func rotateImage() { rotation += .pi / 2; applyImageTransform() }
    @objc private func mirrorImage() { mirrored.toggle(); applyImageTransform() }
    private func updateZoom() {
        scaleLabel.stringValue = String(format: "%.2g×", zoom)
        applyImageTransform()
    }
    private func changeZoom(_ factor: CGFloat, at point: NSPoint) {
        let next = min(max(zoom * factor, 1), 4)
        imageView.adjustOffset(from: zoom, to: next, at: point)
        zoom = next
        updateZoom()
    }
    @objc private func zoomIn() { changeZoom((zoom + 0.25) / zoom, at: imageView.centerPoint) }
    @objc private func zoomOut() { changeZoom((zoom - 0.25) / zoom, at: imageView.centerPoint) }

    @objc private func savePhoto() {
        guard let latestJPEG else { return }
        // Capture before opening the dialog so a moving live stream cannot
        // change either choice while the user picks a destination.
        let rendered = imageView.renderedJPEG()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "MR-Linse-Foto.jpg"
        let format = NSPopUpButton()
        format.addItems(withTitles: ["Aktuelle Ansicht", "Kameraoriginal"])
        format.setAccessibilityLabel("Bildversion")
        panel.accessoryView = format
        format.sizeToFit()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = format.indexOfSelectedItem == 1 ? latestJPEG : rendered else {
                setStatus("Die aktuelle Ansicht konnte nicht gespeichert werden.")
                return
            }
            try data.write(to: url, options: .atomic)
            setStatus("Foto gespeichert")
        } catch {
            setStatus("Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

private final class CameraTransport {
    let light = LampChannel()
    var onStatus: ((String) -> Void)?
    var onFrame: ((Data, CGFloat?) -> Void)?
    var onStopped: ((String) -> Void)?

    private let queue = DispatchQueue(label: "SoulearLupe.udp", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private let cameraPort: UInt16 = 10006

    func start(host: String, videoPort: UInt16) {
        lock.lock(); running = true; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.receive(host: host, videoPort: videoPort)
        }
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func receive(host: String, videoPort: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { onStopped?("UDP-Socket konnte nicht geöffnet werden."); return }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(videoPort.bigEndian)
        local.sin_addr = in_addr(s_addr: in_addr_t(INADDR_ANY))
        let bindResult = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            onStopped?("UDP-Port \(videoPort) belegt. Schließe andere Kamera-Apps.")
            return
        }

        var camera = sockaddr_in()
        camera.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        camera.sin_family = sa_family_t(AF_INET)
        camera.sin_port = in_port_t(cameraPort.bigEndian)
        let addressResult = host.withCString { inet_pton(AF_INET, $0, &camera.sin_addr) }
        guard addressResult == 1 else {
            Darwin.close(fd)
            onStopped?("Ungültige Kamera-IP-Adresse.")
            return
        }

        var assembler = FrameAssembler()
        var buffer = [UInt8](repeating: 0, count: 65535)
        var commandSequence: UInt16 = 1
        var lastOpen = Date.distantPast
        let started = Date()
        var lastFrame = started
        var attempts = 0
        var sawVideo = false

        while isRunning() {
            if let command = light.take() {
                var destination = camera
                destination.sin_port = UInt16(10005).bigEndian
                command.withUnsafeBytes { raw in
                    withUnsafePointer(to: &destination) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            if Date().timeIntervalSince(lastFrame) > 1.5 || attempts == 0 {
                if Date().timeIntervalSince(lastOpen) > 1.5 {
                let packet = makeOpenVideo(sequence: commandSequence, receivePort: videoPort, compact: attempts % 2 == 0)
                commandSequence &+= 1
                _ = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &camera) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                attempts += 1
                lastOpen = Date()
                }
            }
            let count = buffer.withUnsafeMutableBytes { raw in recvfrom(fd, raw.baseAddress, raw.count, 0, nil, nil) }
            if count >= 15 && buffer[0] == 0xee && buffer[6] == 10 {
                light.reply?(Data(buffer.prefix(count)))
            } else if count > 16 {
                let packet = Data(buffer[0..<count])
                if packet.first == 1 || packet.first == 6 { sawVideo = true }; if let jpeg = assembler.append(packet) { lastFrame = Date(); onFrame?(jpeg, assembler.completedRoll) }
            }
            if Date().timeIntervalSince(lastFrame) > 12 {
                Darwin.close(fd)
                onStopped?(sawVideo ? "Kamera sendet Daten, aber kein vollständiges Bild." : "Kamera erkannt, aber kein Videobild. Handy-App schließen und erneut verbinden.")
                return
            }
        }
        Darwin.close(fd)
        onStopped?("Livebild gestoppt")
    }

    private func makeOpenVideo(sequence: UInt16, receivePort: UInt16, compact: Bool) -> Data {
        var data = Data()
        appendLE(0xFFEEFFEE, bytes: 4, to: &data)
        appendLE(UInt32(sequence), bytes: 2, to: &data)
        appendLE(0x0004, bytes: 2, to: &data)
        data.append(0x01)
        data.append(0x00)
        if compact { appendLE(0, bytes: 2, to: &data); return data }
        appendLE(8, bytes: 2, to: &data)
        appendLE(UInt32(receivePort), bytes: 2, to: &data)
        appendLE(0, bytes: 2, to: &data)
        appendLE(0, bytes: 4, to: &data)
        return data
    }

    private func appendLE(_ value: UInt32, bytes: Int, to data: inout Data) {
        for index in 0..<bytes { data.append(UInt8((value >> (index * 8)) & 0xff)) }
    }
}

private struct FrameAssembler {
    private(set) var completedRoll: CGFloat?
    private var pendingRoll: CGFloat?
    private var frameID: UInt8?
    private var firstChunk: UInt8?
    private var expectedChunks = 0
    private var pieces: [UInt8: Data] = [:]

    mutating func append(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        let header = bytes.first == 6 ? 28 : 16
        guard bytes.count > header, bytes[0] == 1 || bytes[0] == 6 else { return nil }
        let incomingFrame = bytes[2]
        if let frameID, frameID != incomingFrame { reset() }
        if frameID == nil {
            frameID = incomingFrame
            firstChunk = bytes[1]
            expectedChunks = Int(bytes[4])
        }
        if expectedChunks == 0 { expectedChunks = Int(bytes[4]) }
        if bytes[5] & 1 != 0 {
            let sample = bytes[6..<10].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            func component(_ shift: Int) -> CGFloat {
                let field = (sample >> shift) & 1023
                return CGFloat(field & 511) * (field & 512 == 0 ? 1 : -1)
            }
            let y = component(10), z = component(0)
            if hypot(y, z) >= 20 { pendingRoll = atan2(y, z) }
        }
        if bytes.count >= header + 2 && bytes[header] == 0xff && bytes[header + 1] == 0xd8 {
            firstChunk = bytes[1]
        }
        pieces[bytes[1]] = Data(bytes[header...])
        guard expectedChunks > 0, expectedChunks < 256, pieces.count >= expectedChunks else { return nil }
        guard let firstChunk else { return nil }
        var jpeg = Data()
        jpeg.reserveCapacity(expectedChunks * 1400)
        for offset in 0..<expectedChunks {
            guard let fragment = pieces[firstChunk &+ UInt8(offset)] else { return nil }
            jpeg.append(fragment)
        }
        completedRoll = pendingRoll
        reset()
        guard jpeg.starts(with: [0xff, 0xd8]), let end = jpeg.range(of: Data([0xff, 0xd9]), options: .backwards) else { return nil }
        return Data(jpeg.prefix(end.upperBound))
    }

    private mutating func reset() {
        frameID = nil
        pendingRoll = nil
        firstChunk = nil
        expectedChunks = 0
        pieces.removeAll(keepingCapacity: true)
    }
}

private enum CameraDiscovery {
    static func lookup() -> (host: String?, message: String, inverted: Bool) {
        guard let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName,
              let store = SCDynamicStoreCreate(nil, "Soulear Lupe" as CFString, nil, nil),
              let services = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray) as? [String: [String: Any]],
              let service = services.values.first(where: { ($0["InterfaceName"] as? String) == name }),
              let local = (service["Addresses"] as? [String])?.first else {
            return (nil, "Mac mit dem WLAN Soulear-79144 verbinden.", false)
        }
        let ssid = wifi.ssid() ?? ""
        let bridgeHint = "Für USB das SuperMini anschließen und USB auswählen. Für Direktbetrieb Soulear-79144 wählen."
        if !ssid.isEmpty && !ssid.lowercased().hasPrefix("soulear-") {
            return (nil, bridgeHint, false)
        }
        guard let host = service["Router"] as? String else {
            return (nil, "Das WLAN hat noch keine Router-Adresse zugewiesen.", false)
        }
        // macOS can withhold the SSID. Only probe the known camera gateway in that case.
        if ssid.isEmpty && host != "192.168.1.1" { return (nil, bridgeHint, false) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return (nil, "Netzwerkzugriff fehlgeschlagen.", false) }
        defer { Darwin.close(fd) }
        var source = endpoint(local, port: 0)
        var target = endpoint(host, port: 10005)
        let bound = withUnsafePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return (nil, "WLAN-Adresse hat sich geändert. Erneuter Versuch folgt.", false) }
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return (nil, "WLAN-Zugriff fehlgeschlagen. Lokales Netzwerk für die App erlauben.", false) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request: [UInt8] = [0xee,0xff,0xee,0xff,1,0,1,0,1,0,0,0]
        let sent = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return (nil, "Kein WLAN-Zugriff. Lokales Netzwerk für die App erlauben.", false) }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let n = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard n >= 12, bytes.prefix(8).elementsEqual(request.prefix(8)), bytes[9] == 0 else {
            return (nil, "Keine Kameraantwort von \(host). Kamera-WLAN und lokalen Netzwerkzugriff prüfen.", false)
        }
        let product = n >= 77 ? String(decoding: bytes[45..<77].prefix { $0 != 0 }, as: UTF8.self).uppercased() : ""
        return (host, "Kamera gefunden", product.contains("FBPRO") || product.contains("R1"))
    }

    private static func endpoint(_ host: String, port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        return address
    }
}

private final class LevelImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var angle: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var verticalScale: CGFloat = 1

    var onZoom: ((CGFloat, NSPoint) -> Void)?
    private var offset = NSPoint.zero // In fractions of the aperture diameter
    var centerPoint: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var diameter: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 0 }
        return min(image.size.width, image.size.height) * min(bounds.width/image.size.width, bounds.height/image.size.height)
    }

    func adjustOffset(from old: CGFloat, to new: CGFloat, at point: NSPoint) {
        guard diameter > 0 else { offset = .zero; return }
        let ratio = new / old
        offset.x = offset.x * ratio + (point.x - bounds.midX) / diameter * (1 - ratio)
        offset.y = offset.y * ratio + (point.y - bounds.midY) / diameter * (1 - ratio)
        let length = hypot(offset.x, offset.y)
        let limit = (new - 1) / 2
        if length > limit { offset.x *= limit / length; offset.y *= limit / length }
    }

    private func gestureZoom(_ factor: CGFloat, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x-bounds.midX, point.y-bounds.midY) <= diameter/2 else { return }
        onZoom?(factor, point)
    }
    override func scrollWheel(with event: NSEvent) {
        gestureZoom(exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.12)), event: event)
    }
    override func magnify(with event: NSEvent) {
        gestureZoom(max(0.1, 1 + event.magnification), event: event)
    }

    func renderedJPEG() -> Data? {
        guard let image, diameter > 0 else { return nil }
        let px = image.representations.first.map { min($0.pixelsWide, $0.pixelsHigh) } ?? 0
        let side = max(1, px)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let mapping = NSAffineTransform()
        mapping.scale(by: CGFloat(side) / diameter)
        mapping.translateX(by: diameter/2 - bounds.midX, yBy: diameter/2 - bounds.midY)
        mapping.concat()
        drawLens()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.96])
    }

    override func draw(_ dirtyRect: NSRect) { drawLens() }

    private func drawLens() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = image.size.width * fit, height = image.size.height * fit
        let rect = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        let diameter = min(width, height)
        let aperture = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                              width: diameter, height: diameter)
        // Clip in window coordinates so only the image rotates inside the circle.
        NSBezierPath(ovalIn: aperture).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX + offset.x * diameter, yBy: bounds.midY + offset.y * diameter)
        transform.scaleX(by: horizontalScale, yBy: verticalScale)
        transform.rotate(byRadians: isFlipped ? -angle : angle)
        transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
        transform.concat()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private final class BridgeReader {
    let light = LampChannel()
    var onFrame: ((Data, CGFloat?, Bool) -> Void)?
    var onStopped: ((String) -> Void)?
    private let lock = NSLock()
    private var stopped = true

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
    private var active: Bool {
        lock.lock(); defer { lock.unlock() }; return !stopped
    }
    func start(_ path: String) {
        lock.lock(); stopped = false; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let message = self.receive(path)
            self.onStopped?(message)
        }
    }
    private func receive(_ path: String) -> String {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return "USB-Anschluss lässt sich nicht öffnen." }
        defer { Darwin.close(fd) }
        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else { return "USB-Anschluss nicht verfügbar." }
        let original = tty
        defer { var restore = original; tcsetattr(fd, TCSANOW, &restore) }
        cfmakeraw(&tty)
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&tty, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else { return "USB-Konfiguration fehlgeschlagen." }
        tcflush(fd, TCIFLUSH) // Discard frames buffered before this live session.
        let magic = Data("LPV1".utf8)
        var pending = Data(), assembler = FrameAssembler()
        var input = [UInt8](repeating: 0, count: 8192)
        var last = Date()
        while active {
            if let command = light.take() {
                _ = command.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            }
            if Date().timeIntervalSince(last) > 25 { return "Kein Bild über USB. Brückenfirmware und Kamera-Stromversorgung prüfen." }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 200)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 || event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return "USB-Verbindung getrennt." }
            if ready == 0 { continue }
            let n = input.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard n > 0 else { return "USB-Verbindung getrennt." }
            pending.append(contentsOf: input.prefix(n))
            while let marker = pending.range(of: magic) {
                pending.removeSubrange(pending.startIndex..<marker.lowerBound)
                let start = pending.startIndex
                guard pending.count >= 7 else { break }
                let length = Int(pending[start+4]) + 256 * Int(pending[start+5])
                guard length == 15 || (17...2048).contains(length) else { pending.removeFirst(); continue }
                guard pending.count >= 7 + length else { break }
                let inverted = pending[start+6] != 0
                let packet = Data(pending[(start+7)..<(start+7+length)])
                pending.removeFirst(7+length)
                if length == 15 { light.reply?(packet); continue }
                if let jpeg = assembler.append(packet) {
                    last = Date()
                    onFrame?(jpeg, assembler.completedRoll, inverted)
                }
            }
            if pending.range(of: magic) == nil { pending = Data(pending.suffix(3)) }
        }
        return "Livebild gestoppt"
    }
}

private final class LampChannel {
    var reply: ((Data) -> Void)?
    private let lock = NSLock()
    private var pending: Data?

    func submit(id: UInt16, on: Bool) {
        let packet = Data([0xee,0xff,0xee,0xff,UInt8(truncatingIfNeeded: id),UInt8(id >> 8),
                           10,0,1,0,3,0,0x11,on ? 1 : 0,on ? 100 : 0])
        lock.lock()
        pending = packet
        lock.unlock()
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let packet = pending
        pending = nil
        return packet
    }
}

// A static optical scale sits outside the image. Only the image view
// redraws when frames arrive.
private final class LensStage: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(calibratedRed: 0.115, green: 0.15, blue: 0.165, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.042, alpha: 1))?.draw(in: bounds, relativeCenterPosition: .zero)
        let radius = max(0, min(bounds.width, bounds.height) / 2 - 24)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ticks = NSBezierPath()
        for i in 0..<60 {
            let angle = CGFloat(i) * .pi / 30
            let inner = radius + 3
            let outer = inner + (i.isMultiple(of: 5) ? 6 : 2)
            ticks.move(to: CGPoint(x: center.x + cos(angle)*inner, y: center.y + sin(angle)*inner))
            ticks.line(to: CGPoint(x: center.x + cos(angle)*outer, y: center.y + sin(angle)*outer))
        }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        ticks.lineWidth = 1
        ticks.stroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius,
                                               width: radius*2, height: radius*2))
        NSColor.white.withAlphaComponent(0.09).setStroke()
        ring.stroke()
    }
}
