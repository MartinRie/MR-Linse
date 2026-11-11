import Foundation
import Darwin

final class BridgeReader {
    let light = LampChannel()
    var onFrame: ((Data, CGFloat?, Bool) -> Void)?
    var onStopped: ((String) -> Void)?
    private let lock = NSLock()
    private var stopped = true
    private let queue = DispatchQueue(label: "MRLinse.usb", qos: .userInitiated)

    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var active: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func start(_ path: String, profile: CameraProfile) {
        lock.lock(); stopped = false; lock.unlock()
        queue.async { self.onStopped?(self.receive(path, profile: profile)) }
    }
    private func receive(_ path: String, profile: CameraProfile) -> String {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return "USB-Anschluss lässt sich nicht öffnen." }
        defer { Darwin.close(fd) }
        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else { return "USB-Anschluss nicht verfügbar." }
        let original = tty
        defer { var restore = original; tcsetattr(fd, TCSANOW, &restore) }
        cfmakeraw(&tty); tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&tty, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else { return "USB-Konfiguration fehlgeschlagen." }
        tcflush(fd, TCIFLUSH)
        let sequence = UInt16.random(in: 1...UInt16.max)
        guard let configuration = profile.bridgePacket(sequence: sequence) else { return "Ungültiges Kameraprofil." }
        var configured = false
        var outgoing = configuration
        var lastConfig = Date()
        let opened = Date()
        let magic = Data("LPV1".utf8)
        var pending = Data(), assembler = FrameAssembler()
        var input = [UInt8](repeating: 0, count: 16384)
        var last = Date()
        while active {
            if !configured && Date().timeIntervalSince(opened) > 6 { return "C3-Firmware aktualisieren: Das Kameraprofil wurde nicht bestätigt." }
            if !configured && outgoing.isEmpty && Date().timeIntervalSince(lastConfig) > 1 {
                outgoing = configuration; lastConfig = Date()
            }
            if configured && outgoing.isEmpty, let command = light.take() { outgoing = command }
            if !outgoing.isEmpty {
                let n = outgoing.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 { outgoing.removeFirst(n) }
                else if n < 0 && errno != EAGAIN && errno != EINTR { return "USB-Verbindung getrennt." }
            }
            if configured && Date().timeIntervalSince(last) > 10 { return "Kein Bild über USB. Kamera und WLAN-Namen prüfen." }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 30)
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
                guard length == 8 || length == 15 || (17...2048).contains(length) else { pending.removeFirst(); continue }
                guard pending.count >= 7 + length else { break }
                let inverted = pending[start+6] != 0
                let packet = Data(pending[(start+7)..<(start+7+length)])
                pending.removeFirst(7+length)
                if length == 8 {
                    if packet.prefix(4) == Data("LPC1".utf8),
                       UInt16(packet[4]) | UInt16(packet[5]) << 8 == sequence,
                       packet[6] == 0, packet[7] == 1 {
                        configured = true; last = Date()
                    }
                    continue
                }
                guard configured else { continue }
                if length == 15 { light.reply?(packet); continue }
                if let jpeg = assembler.append(packet) { last = Date(); onFrame?(jpeg, assembler.completedRoll, inverted) }
            }
            if pending.range(of: magic) == nil { pending = Data(pending.suffix(3)) }
        }
        return "Livebild gestoppt"
    }
}
