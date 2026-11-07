import AppKit

final class AppUpdater: NSObject {
    private let defaults = UserDefaults.standard
    private var checking = false
    private var checkItem: NSMenuItem?
    private var automaticItem: NSMenuItem?
    var mayPresent: () -> Bool = { true }
    private var repository: String {
        defaults.string(forKey: "UpdateRepository") ?? (Bundle.main.object(forInfoDictionaryKey: "MRUpdateRepository") as? String ?? "")
    }
    private var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }

    func installMenu() {
        let bar = NSMenu()
        let root = NSMenuItem()
        let app = NSMenu(title: "MR-Linse")
        root.submenu = app; bar.addItem(root)
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self; app.addItem(entry); return entry
        }
        _ = item("Über MR-Linse", #selector(about))
        app.addItem(.separator())
        checkItem = item("Nach Updates suchen …", #selector(manualCheck))
        automaticItem = item("Automatisch nach Updates suchen", #selector(toggleAutomatic))
        automaticItem?.state = defaults.bool(forKey: "AutomaticUpdateChecks") ? .on : .off
        _ = item("Updatequelle …", #selector(configure))
        app.addItem(.separator())
        let quit = NSMenuItem(title: "MR-Linse beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.addItem(quit)
        // Standard edit actions also work in repository and save dialogs.
        let editRoot = NSMenuItem(); let edit = NSMenu(title: "Bearbeiten"); editRoot.submenu = edit; bar.addItem(editRoot)
        for (title, selector, key) in [("Kopieren", "copy:", "c"), ("Einfügen", "paste:", "v"), ("Ausschneiden", "cut:", "x"), ("Alles auswählen", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = bar
    }

    func checkAutomaticallyIfDue() {
        guard defaults.bool(forKey: "AutomaticUpdateChecks"), GitHubRelease.validRepository(repository), mayPresent() else { return }
        let previous = defaults.object(forKey: "LastUpdateAttempt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(previous) >= 86400 else { return }
        check(manual: false)
    }

    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func toggleAutomatic() {
        let enabled = !defaults.bool(forKey: "AutomaticUpdateChecks")
        defaults.set(enabled, forKey: "AutomaticUpdateChecks")
        automaticItem?.state = enabled ? .on : .off
        if enabled { checkAutomaticallyIfDue() }
    }
    @objc private func configure() {
        guard !checking, mayPresent() else { return }
        let alert = NSAlert()
        alert.messageText = "GitHub-Updatequelle"
        alert.informativeText = "Öffentliches Repository als Benutzer/Repository eintragen. GitHub-Builds tragen ihre Quelle bereits automatisch ein. Ein leeres Feld stellt diese Vorgabe wieder her."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        field.stringValue = repository; field.placeholderString = "Benutzer/MR-Linse"
        alert.accessoryView = field; alert.addButton(withTitle: "Speichern"); alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || GitHubRelease.validRepository(value) else { message("Ungültige Updatequelle", "Bitte Benutzer/Repository eintragen, ohne https://github.com/."); return }
        if value.isEmpty { defaults.removeObject(forKey: "UpdateRepository") } else { defaults.set(value, forKey: "UpdateRepository") }
        defaults.removeObject(forKey: "LastUpdateAttempt")
    }
    @objc private func manualCheck() {
        guard mayPresent() else { return }
        guard GitHubRelease.validRepository(repository) else { configure(); return }
        check(manual: true)
    }
    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.runModal()
    }
    private func check(manual: Bool) {
        guard !checking else { return }
        let repo = repository
        guard GitHubRelease.validRepository(repo), let current = AppVersion(currentVersion),
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        checking = true; checkItem?.title = "Updates werden geprüft …"; checkItem?.isEnabled = false
        defaults.set(Date(), forKey: "LastUpdateAttempt")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MR-Linse/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false; self.checkItem?.title = "Nach Updates suchen …"; self.checkItem?.isEnabled = true
                guard self.mayPresent() else { return }
                func problem(_ text: String) { if manual { self.message("Updateprüfung nicht möglich", text) } }
                if let error { problem("Internetverbindung prüfen. Im direkten Kamera-WLAN ist normalerweise kein Internet verfügbar.\n\n" + error.localizedDescription); return }
                guard let response = response as? HTTPURLResponse else { problem("Keine gültige Antwort von GitHub."); return }
                guard response.statusCode == 200 else {
                    problem(response.statusCode == 404 ? "Noch kein öffentliches Release gefunden. Repository-Namen und Veröffentlichung prüfen. Private Repositories werden nicht unterstützt." : "GitHub antwortet mit HTTP \(response.statusCode). Bitte später erneut versuchen."); return
                }
                guard let data, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                      !release.draft, !release.prerelease, let latest = AppVersion(release.tag_name) else {
                    problem("Das Release benötigt eine stabile Versionsnummer wie v0.2.0."); return
                }
                guard latest > current else {
                    if manual { self.message("MR-Linse ist aktuell", "Installierte Version: \(self.currentVersion)") }; return
                }
                guard let download = release.downloadURL(repository: repo) else {
                    problem("Eine neue Version ist angekündigt, aber das passende Mac-Paket ist noch nicht bereit. Bitte nach Abschluss des GitHub-Builds erneut prüfen."); return
                }
                let alert = NSAlert(); alert.messageText = "MR-Linse \(release.tag_name) ist verfügbar"
                let notes = String((release.body ?? "").prefix(1600))
                alert.informativeText = "Installiert: \(self.currentVersion)\n\n\(notes)\n\nDer Download öffnet sich im Browser. Danach MR-Linse beenden, das ZIP entpacken und die App im Programme-Ordner ersetzen."
                alert.addButton(withTitle: "Update herunterladen"); alert.addButton(withTitle: "Später")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(download) }
            }
        }.resume()
    }
}
