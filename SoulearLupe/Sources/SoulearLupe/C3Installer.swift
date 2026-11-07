import Foundation

enum C3Installer {
    // Board layout used by the Arduino ESP32-C3 PlatformIO target.
    static let segments = [("0x0", "bootloader.bin"), ("0x8000", "partitions.bin"),
                           ("0xe000", "boot_app0.bin"), ("0x10000", "firmware.bin")]

    enum Check { case matches, differs, unavailable }

    static func check(port: String) -> Check {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("C3") else { return .unavailable }
        let tool = Process()
        tool.executableURL = folder.appendingPathComponent("esptool")
        tool.arguments = ["--chip", "esp32c3", "--port", port, "--connect-attempts", "2",
                          "--after", "hard_reset", "verify_flash", "0x10000",
                          folder.appendingPathComponent("firmware.bin").path]
        let pipe = Pipe()
        tool.standardOutput = pipe
        tool.standardError = pipe
        do { try tool.run() } catch { return .unavailable }
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tool.waitUntilExit()
        if tool.terminationStatus == 0 && log.contains("digest matched") { return .matches }
        return log.contains("digest mismatch") ? .differs : .unavailable
    }

    static func write(port: String, progress: (String) -> Void) -> String? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("C3") else {
            return "Firmware-Ressourcen fehlen."
        }
        let process = Process()
        process.executableURL = folder.appendingPathComponent("esptool")
        var args = ["--chip", "esp32c3", "--port", port, "--baud", "460800",
                    "--before", "default_reset", "--after", "hard_reset", "write_flash"]
        for (offset, name) in segments {
            let path = folder.appendingPathComponent(name).path
            guard FileManager.default.isReadableFile(atPath: path) else { return "Datei fehlt: " + name }
            args += [offset, path]
        }
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        var tail = ""
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            let text = String(decoding: data, as: UTF8.self)
            tail = String((tail + text).suffix(1800))
            if text.contains("Writing at"), let line = text.components(separatedBy: .newlines).last(where: { $0.contains("Writing at") }) {
                progress(line.trimmingCharacters(in: .whitespaces))
            }
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : tail
    }
}
