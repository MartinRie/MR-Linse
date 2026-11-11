import Foundation

struct FrameAssembler {
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

final class LampChannel {
    var reply: ((Data) -> Void)?
    private let lock = NSLock()
    private var pending: Data?

    func submit(id: UInt16, on: Bool?) {
        let packet = Data([0xee,0xff,0xee,0xff,UInt8(truncatingIfNeeded: id),UInt8(id >> 8),
                           10,0,1,0,3,0,on == nil ? 0x01 : 0x11,on == true ? 1 : 0,on == true ? 100 : 0])
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
