import Foundation

struct CameraProfile: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var ssid: String
    var host: String
    static let standard = CameraProfile(id: "soulear-default", name: "Meine Soulear", ssid: "Soulear-79144", host: "192.168.1.1")
    static func ipv4(_ text: String) -> [UInt8]? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        let bytes = fields.compactMap { field -> UInt8? in
            guard !field.isEmpty, (field.count == 1 || field.first != "0"), field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt8(field)
        }
        guard bytes.count == 4, bytes[0] > 0, bytes[0] < 224, bytes[0] != 127 else { return nil }
        return bytes
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60 &&
        (1...32).contains(ssid.utf8.count) && !ssid.utf8.contains(0) && Self.ipv4(host) != nil
    }
    func bridgePacket(sequence: UInt16) -> Data? {
        guard isValid, let ip = Self.ipv4(host) else { return nil }
        let ssidBytes = Array(ssid.utf8)
        return Data(Array("LPC1".utf8) + [UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8), UInt8(ssidBytes.count), 0]
                    + ssidBytes + Array(repeating: 0, count: 32 - ssidBytes.count) + ip)
    }
}

struct ViewSettings: Codable {
    var zoom: Double = 1
    var rotation: Double = 0
    var mirrored = false
    var automatic = true
    var offsetX: Double = 0
    var offsetY: Double = 0
    mutating func sanitize() {
        zoom = zoom.isFinite ? min(4, max(1, zoom)) : 1
        rotation = rotation.isFinite ? rotation.truncatingRemainder(dividingBy: 2 * .pi) : 0
        if !offsetX.isFinite || !offsetY.isFinite { offsetX = 0; offsetY = 0 }
        let length = hypot(offsetX, offsetY), limit = (zoom - 1) / 2
        if length > limit { offsetX *= limit / length; offsetY *= limit / length }
    }
}

struct ReconnectPolicy {
    private(set) var wanted = false
    private(set) var failures = 0
    private(set) var nextAttempt = Date.distantFuture
    mutating func start() { wanted = true; failures = 0; nextAttempt = .distantPast }
    mutating func stop() { wanted = false; nextAttempt = .distantFuture }
    mutating func succeeded() { failures = 0 }
    mutating func failed(now: Date = Date()) {
        failures = min(failures + 1, 4)
        nextAttempt = now.addingTimeInterval(min(15, pow(2, Double(failures))))
    }
    func due(now: Date = Date()) -> Bool { wanted && now >= nextAttempt }
}
