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
    private let lamp = NSSwitch()
    private let lampStatus = NSTextField(labelWithString: "Nicht verbunden")
    private var confirmedLamp: Bool?
    private var lampQuerySent = false
    private let preview = PreviewPipeline()
    private var processingMS: Double = 0
    private var lastStatistics = Date.distantPast
    private var lastStatsFrames = 0
    private var reconnect = ReconnectPolicy()
    private var retryUSB = false
    private var retryPort: String?
    private var profiles = [CameraProfile.standard]
    private var profileIndex = 0
    private var profile: CameraProfile { profiles[profileIndex] }
    private let profilePicker = NSPopUpButton()
    private let profileButton = NSButton(title: "Profil bearbeiten …", target: nil, action: nil)
    private var lampID: UInt16 = 0
    private var awaitingLamp: UInt16?
    private let scaleLabel = NSTextField(labelWithString: "1×")
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
        restoreSettings()
        preview.deliver = { [weak self] frame, image, elapsed in
            guard let self, self.live else { return }
            self.processingMS = elapsed
            if let inverted = frame.inverted { self.mountAngle = inverted ? .pi : 0 }
            self.showFrame(frame.jpeg, image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), roll: frame.roll)
        }
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
            self?.preview.submit(jpeg, roll: roll, inverted: nil)
        }
        transport.onStopped = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.live = false
                self.preview.reset()
                self.latestJPEG = nil
                self.captureButton.isEnabled = false
                self.resetFreeze()
                self.resetLamp()
                if message.contains("Firmware aktualisieren") {
                    self.reconnect.stop(); self.firmwareMatches = false; self.checkedPort = nil
                    self.flashButton.isHidden = false
                }
                if self.reconnect.wanted { self.reconnect.failed() }
                self.source.isEnabled = !self.reconnect.wanted
                self.profilePicker.isEnabled = !self.reconnect.wanted
                self.profileButton.isEnabled = !self.reconnect.wanted
                self.startButton.isEnabled = true
                self.startButton.title = self.reconnect.wanted ? "Verbindung beenden" : "Verbinden"
                self.placeholder.stringValue = self.reconnect.wanted ? "Verbindung wird wiederhergestellt …" : "Noch kein Kamerabild"
                self.placeholder.isHidden = false
                self.frameLabel.stringValue = "Kein Livebild"
                self.setStatus(message + (self.reconnect.wanted ? " Neuer Versuch folgt automatisch." : ""))
            }
        }
        usb.onFrame = { [weak self] jpeg, roll, inverted in
            self?.preview.submit(jpeg, roll: roll, inverted: inverted)
        }
        let reply: (Data) -> Void = { [weak self] packet in
            DispatchQueue.main.async { self?.receiveLampReply(packet) }
        }
        transport.light.reply = reply
        usb.light.reply = reply
        usb.onStopped = transport.onStopped
        refreshSources()
        discover()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.connectionTick() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MR-Linse"
        window.minSize = NSSize(width: 780, height: 710)
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
        section("Kamera")
        profilePicker.target = self
        profilePicker.action = #selector(profileChanged)
        profilePicker.setAccessibilityLabel("Kameraprofil")
        add(profilePicker)
        profileButton.target = self
        profileButton.action = #selector(editProfile)
        profileButton.bezelStyle = .rounded
        add(profileButton)
        rule()
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
        lamp.target = self
        lamp.action = #selector(setLamp)
        lamp.isEnabled = false
        lamp.setAccessibilityLabel("Kameralicht")
        let lightRow = NSStackView(views: [NSTextField(labelWithString: "Kameralicht"), spacer(), lamp])
        add(lightRow)
        lampStatus.font = .systemFont(ofSize: 11)
        lampStatus.textColor = .secondaryLabelColor
        add(lampStatus)
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

    private func showFrame(_ jpeg: Data, image: NSImage, roll: CGFloat?) {
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
        reconnect.succeeded()
        let elapsed = Date().timeIntervalSince(lastStatistics)
        if elapsed >= 1 {
            let received = preview.snapshot().received
            let fps = lastStatistics == .distantPast ? 0 : Double(received - lastStatsFrames) / elapsed
            frameLabel.stringValue = String(format: "%.0f fps · Verarbeitung %.0f ms", fps, processingMS)
            frameLabel.toolTip = "Zeit vom vollständigen JPEG am Mac bis zur Übergabe an die Ansicht. Keine Messung der gesamten Kameraverzögerung. Verworfen für ein aktuelleres Bild: \(preview.snapshot().replaced)."
            lastStatsFrames = received; lastStatistics = Date()
        }
        if frameCount == 1 {
            updateFreezeButton()
            setStatus("Livebild empfangen")
            queryLamp()
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
        preview.setPaused(false)
        updateFreezeButton()
    }

    @objc private func toggleFreeze() {
        guard live, latestJPEG != nil else { return }
        frozen.toggle()
        preview.setPaused(frozen)
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

    private func resetLamp() {
        awaitingLamp = nil; confirmedLamp = nil; lampQuerySent = false
        lamp.state = .off; lamp.isEnabled = false; lampStatus.stringValue = "Nicht verbunden"
        _ = transport.light.take(); _ = usb.light.take()
    }

    private func queryLamp() {
        guard !lampQuerySent else { return }
        lampQuerySent = true
        sendLamp(nil)
    }

    @objc private func setLamp() { sendLamp(lamp.state == .on) }

    private func sendLamp(_ on: Bool?) {
        guard live, awaitingLamp == nil else { return }
        lampID &+= 1
        let id = lampID
        awaitingLamp = id; lamp.isEnabled = false
        lampStatus.stringValue = on == nil ? "Zustand wird gelesen …" : "Wird geschaltet …"
        let channel = bridgePath == nil ? transport.light : usb.light
        channel.submit(id: id, on: on)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.awaitingLamp == id else { return }
            self.awaitingLamp = nil
            self.lamp.state = self.confirmedLamp == true ? .on : .off
            self.lamp.isEnabled = self.live
            self.lampStatus.stringValue = "Zustand unbestätigt"
        }
    }

    private func receiveLampReply(_ data: Data) {
        guard data.count >= 15, data.prefix(4) == Data([0xee,0xff,0xee,0xff]),
              data[6] == 10, data[7] == 0, data[9] == 0, data[10] >= 3, data[13] <= 1,
              awaitingLamp == UInt16(data[4]) | (UInt16(data[5]) << 8) else { return }
        awaitingLamp = nil
        confirmedLamp = data[13] == 1
        lamp.state = confirmedLamp == true ? .on : .off
        lampStatus.stringValue = confirmedLamp == true ? "Licht an" : "Licht aus"
        lamp.isEnabled = live
    }

    private func refreshSources() {
        guard !checkingFirmware, !flashing, !live, !connectRequested, !reconnect.wanted else { return }
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
        UserDefaults.standard.set(preferredSource, forKey: "PreferredSource")
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
        guard !live, !connectRequested, !reconnect.wanted else {
            setStatus("Bitte zuerst das Livebild stoppen.")
            return
        }
        guard let port = bridgePath else {
            setStatus("SuperMini per USB anschließen und seinen USB-Anschluss auswählen.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Firmware auf das C3 SuperMini schreiben?"
        alert.informativeText = "Das Programm auf dem Board an \(port) wird durch die Kamerabrücke für das ausgewählte Kameraprofil ersetzt. Lass das USB-Kabel bis zum Abschluss eingesteckt."
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
        if reconnect.wanted || live || connectRequested {
            reconnect.stop(); connectRequested = false
            if live {
                startButton.isEnabled = false
                if retryUSB { usb.stop() } else { transport.stop() }
            } else {
                startButton.title = "Verbinden"
                source.isEnabled = true; profilePicker.isEnabled = true; profileButton.isEnabled = true
                setStatus("Verbindung beendet")
            }
            return
        }
        guard !checkingFirmware, !flashing else { return }
        preferredSource = source.titleOfSelectedItem
        UserDefaults.standard.set(preferredSource, forKey: "PreferredSource")
        retryUSB = bridgePath != nil; retryPort = bridgePath
        reconnect.start()
        attemptConnection()
    }

    private func attemptConnection() {
        guard reconnect.wanted, !live, !probing, !checkingFirmware, !flashing else { return }
        source.isEnabled = false; profilePicker.isEnabled = false; profileButton.isEnabled = false
        startButton.title = "Verbindung beenden"; startButton.isEnabled = true
        if retryUSB {
            var path = retryPort
            if path == nil || !FileManager.default.fileExists(atPath: path!) {
                let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
                    .filter { $0.hasPrefix("cu.usbmodem") }.map { "/dev/" + $0 }.filter { Self.isEspressifUSB($0) }
                if ports.count == 1 { path = ports[0] } else {
                    reconnect.failed(); setStatus("Warte auf den C3 am USB-Anschluss …"); return
                }
            }
            guard let path else { return }
            retryPort = path
            if bridgePath != path {
                source.addItem(withTitle: "USB · " + URL(fileURLWithPath: path).lastPathComponent)
                source.lastItem?.representedObject = path
                source.selectItem(at: source.numberOfItems - 1)
            }
            prepareStream()
            setStatus("Verbinde C3 mit \(profile.ssid) …")
            usb.start(path, profile: profile)
        } else {
            connectRequested = true
            discover()
        }
    }

    private func prepareStream() {
        preview.reset(); resetLamp(); latestJPEG = nil; captureButton.isEnabled = false
        imageView.image = nil; placeholder.stringValue = "Warte auf Kamerabild …"; placeholder.isHidden = false
        frameCount = 0; lastStatistics = .distantPast; lastStatsFrames = 0; sensorAngle = nil
        live = true; resetFreeze()
    }

    private func connectionTick() {
        if live {
            let last = preview.snapshot().lastReceived
            if last > 0 && ProcessInfo.processInfo.systemUptime - last > 3 {
                placeholder.stringValue = "Kein aktuelles Kamerabild …"; placeholder.isHidden = false
                lamp.isEnabled = false; captureButton.isEnabled = false
                setStatus("Kamera antwortet nicht. Verbindung wird geprüft …")
            } else if last > 0 {
                if frozen { placeholder.isHidden = true }
                captureButton.isEnabled = latestJPEG != nil
                lamp.isEnabled = awaitingLamp == nil
            }
            return
        }
        if reconnect.due() { attemptConnection() }
        else if !reconnect.wanted { refreshSources() }
    }

    private func discover() {
        guard !flashing, bridgePath == nil, !live, !probing else { return }
        probing = true
        let selectedProfile = profile
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = CameraDiscovery.lookup(profile: selectedProfile)
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard self.profile == selectedProfile, self.bridgePath == nil, !self.live else { self.connectRequested = false; return }
                self.ipField.stringValue = result.host ?? "—"
                self.setStatus(result.message)
                self.startButton.isEnabled = true
                if self.connectRequested, let host = result.host {
                    self.mountAngle = result.inverted ? .pi : 0
                    self.sensorAngle = nil
                    self.beginStream(host)
                }
                if self.connectRequested && result.host == nil { self.reconnect.failed() }
                self.connectRequested = false
                self.source.isEnabled = !self.live && !self.reconnect.wanted
            }
        }
    }

    private func beginStream(_ address: String) {
        prepareStream()
        frameLabel.stringValue = "UDP · \(address)"
        startButton.title = "Livebild stoppen"
        ipField.isEnabled = false
        setStatus("Verbinde mit \(address) …")
        transport.start(host: address, videoPort: 22789)
    }

    @objc private func updateOrientation() { applyImageTransform(); saveViewSettings() }
    @objc private func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc private func rotateImage() { rotation = (rotation + .pi / 2).truncatingRemainder(dividingBy: .pi * 2); applyImageTransform(); saveViewSettings() }
    @objc private func mirrorImage() { mirrored.toggle(); applyImageTransform(); saveViewSettings() }
    private func updateZoom() {
        scaleLabel.stringValue = String(format: "%.2g×", zoom)
        applyImageTransform()
    }
    private func changeZoom(_ factor: CGFloat, at point: NSPoint) {
        let next = min(max(zoom * factor, 1), 4)
        imageView.adjustOffset(from: zoom, to: next, at: point)
        zoom = next
        updateZoom()
        saveViewSettings()
    }
    @objc private func zoomIn() { changeZoom((zoom + 0.25) / zoom, at: imageView.centerPoint) }
    @objc private func zoomOut() { changeZoom((zoom - 0.25) / zoom, at: imageView.centerPoint) }

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "CameraProfiles"), let saved = try? JSONDecoder().decode([CameraProfile].self, from: data) {
            let valid = saved.filter { $0.isValid }
            if !valid.isEmpty { profiles = valid }
        }
        profileIndex = profiles.firstIndex { $0.id == defaults.string(forKey: "SelectedProfile") } ?? 0
        preferredSource = defaults.string(forKey: "PreferredSource")
        refreshProfilePicker()
        loadViewSettings()
    }

    private func refreshProfilePicker() {
        profilePicker.removeAllItems()
        profilePicker.addItems(withTitles: profiles.map(\.name))
        profilePicker.selectItem(at: profileIndex)
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "CameraProfiles") }
        UserDefaults.standard.set(profile.id, forKey: "SelectedProfile")
    }

    private func saveViewSettings() {
        let settings = ViewSettings(zoom: Double(zoom), rotation: Double(rotation), mirrored: mirrored,
            automatic: automatic.state == .on, offsetX: Double(imageView.offset.x), offsetY: Double(imageView.offset.y))
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "View." + profile.id) }
    }

    private func loadViewSettings() {
        var settings = UserDefaults.standard.data(forKey: "View." + profile.id)
            .flatMap { try? JSONDecoder().decode(ViewSettings.self, from: $0) } ?? ViewSettings()
        settings.sanitize()
        zoom = CGFloat(settings.zoom); rotation = CGFloat(settings.rotation); mirrored = settings.mirrored
        automatic.state = settings.automatic ? .on : .off
        imageView.offset = NSPoint(x: settings.offsetX, y: settings.offsetY)
        updateZoom()
    }

    @objc private func profileChanged() {
        guard !live, !reconnect.wanted, !checkingFirmware, !flashing else { refreshProfilePicker(); return }
        saveViewSettings()
        profileIndex = profilePicker.indexOfSelectedItem
        saveProfiles(); loadViewSettings(); discover()
    }

    @objc private func editProfile() {
        guard !live, !reconnect.wanted, !checkingFirmware, !flashing else { return }
        let alert = NSAlert()
        alert.messageText = "Kameraprofil"
        alert.informativeText = "Für Kameras mit kompatiblem Soulear/i4season-Protokoll und offenem WLAN. Andere Protokolle werden noch nicht unterstützt. Im USB-Betrieb wird das Profil beim Verbinden an den C3 übertragen."
        let fields = [NSTextField(string: profile.name), NSTextField(string: profile.ssid), NSTextField(string: profile.host)]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 150))
        for (i, label) in ["Name", "Kamera-WLAN (SSID)", "Kamera-IP"].enumerated() {
            let caption = NSTextField(labelWithString: label)
            caption.frame = NSRect(x: 0, y: 128 - i*50, width: 380, height: 18)
            fields[i].frame = NSRect(x: 0, y: 104 - i*50, width: 380, height: 24)
            view.addSubview(caption); view.addSubview(fields[i])
        }
        alert.accessoryView = view
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Als neues Profil")
        alert.addButton(withTitle: "Abbrechen")
        if profiles.count > 1 { alert.addButton(withTitle: "Löschen") }
        alert.window.initialFirstResponder = fields[0]
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
            profiles.remove(at: profileIndex); profileIndex = 0
        } else {
            var edited = CameraProfile(id: profile.id, name: fields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                ssid: fields[1].stringValue, host: fields[2].stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            guard edited.isValid else {
                let error = NSAlert(); error.messageText = "Profil bitte prüfen"
                error.informativeText = "Name: 1–60 Zeichen. WLAN-Name: 1–32 UTF-8-Bytes. Kamera-IP: gültige IPv4-Adresse."
                error.runModal(); return
            }
            if response == .alertSecondButtonReturn {
                edited.id = UUID().uuidString; profiles.append(edited); profileIndex = profiles.count - 1
            } else { profiles[profileIndex] = edited }
        }
        saveProfiles(); refreshProfilePicker(); loadViewSettings(); discover()
    }

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
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
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
            if Date().timeIntervalSince(lastFrame) > 8 {
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

private enum CameraDiscovery {
    static func lookup(profile: CameraProfile) -> (host: String?, message: String, inverted: Bool) {
        guard let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName,
              let store = SCDynamicStoreCreate(nil, "Soulear Lupe" as CFString, nil, nil),
              let services = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray) as? [String: [String: Any]],
              let service = services.values.first(where: { ($0["InterfaceName"] as? String) == name }),
              let local = (service["Addresses"] as? [String])?.first else {
            return (nil, "Mac mit dem WLAN \(profile.ssid) verbinden.", false)
        }
        let ssid = wifi.ssid() ?? ""
        let bridgeHint = "Für USB das SuperMini anschließen und USB auswählen. Für Direktbetrieb \(profile.ssid) wählen."
        if !ssid.isEmpty && ssid != profile.ssid {
            return (nil, bridgeHint, false)
        }
        guard let gateway = service["Router"] as? String else {
            return (nil, "Das WLAN hat noch keine Router-Adresse zugewiesen.", false)
        }
        // macOS can withhold the SSID. Only probe the known camera gateway in that case.
        if ssid.isEmpty && gateway != profile.host { return (nil, bridgeHint, false) }
        let host = profile.host
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
    var offset = NSPoint.zero // In fractions of the aperture diameter
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
