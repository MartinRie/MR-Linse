import Foundation
import Darwin
import ImageIO

@main enum RuntimeChecks {
    static func main() throws {
        let profile = CameraProfile.standard
        let config = profile.bridgePacket(sequence: 0x1234)!
        precondition(config.count == 44 && Array(config[4...7]) == [0x34,0x12,13,0])
        precondition(Array(config.suffix(4)) == [192,168,1,1])
        for host in ["", "300.1.1.1", "192.1.1", "192..1.1", "127.0.0.1", "224.0.0.1", "192.1.1.x", "192.168.001.1"] {
            precondition(CameraProfile.ipv4(host) == nil)
        }
        precondition(!CameraProfile(name: "a", ssid: String(repeating: "ü", count: 17), host: "192.168.1.1").isValid)
        precondition(!CameraProfile(name: "a", ssid: "bad\0name", host: "192.168.1.1").isValid)
        let restored = try JSONDecoder().decode(CameraProfile.self, from: JSONEncoder().encode(profile))
        precondition(restored == profile)
        var settings = ViewSettings(zoom: 99, rotation: .infinity, offsetX: 99, offsetY: 99)
        settings.sanitize()
        precondition(settings.zoom == 4 && settings.rotation == 0 && hypot(settings.offsetX,settings.offsetY) < 1.501)
        var retry = ReconnectPolicy(); let now = Date()
        precondition(!retry.due()); retry.start(); precondition(retry.due())
        retry.failed(now: now); precondition(!retry.due(now: now.addingTimeInterval(1)))
        precondition(retry.due(now: now.addingTimeInterval(2)))
        retry.stop(); precondition(!retry.due(now: now.addingTimeInterval(100)))
        retry.start(); retry.succeeded(); precondition(retry.failures == 0)
        let lamp = LampChannel(); lamp.submit(id: 5, on: nil)
        precondition(lamp.take()?[12] == 1 && lamp.take() == nil)
        lamp.submit(id: 6, on: true); precondition(lamp.take()?[13] == 1)
        lamp.submit(id: 7, on: false); precondition(lamp.take()?[13] == 0)

        var assembler = FrameAssembler()
        let one = video(frame: 1, chunk: 255, count: 2, payload: [0xff,0xd8,1])
        let two = video(frame: 1, chunk: 0, count: 2, payload: [2,0xff,0xd9,0,0])
        precondition(assembler.append(two) == nil)
        precondition(assembler.append(one) == Data([0xff,0xd8,1,2,0xff,0xd9]))
        precondition(assembler.append(video(frame: 2, chunk: 1, count: 2, payload: [0xff,0xd8])) == nil)
        precondition(assembler.append(video(frame: 3, chunk: 5, count: 1, payload: [0xff,0xd8,0xff,0xd9])) == Data([0xff,0xd8,0xff,0xd9]))
        try usb(profile: profile)
        try preview()
        print("Runtime checks passed: profiles, settings, retry cancellation, light, frame assembly, USB handshake and bounded preview")
    }
    static func video(frame: UInt8, chunk: UInt8, count: UInt8, payload: [UInt8]) -> Data {
        Data([1,chunk,frame,0,count,0,0,0,0,0,0,0,0,0,0,0] + payload)
    }
    static func usb(profile: CameraProfile) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        precondition(openpty(&master, &slave, &name, nil, nil) == 0)
        defer { close(master); close(slave) }
        let bridge = BridgeReader()
        let delivered = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        bridge.onFrame = { jpeg, _, inverted in
            precondition(jpeg == Data([0xff,0xd8,0xff,0xd9]) && !inverted); delivered.signal()
        }
        bridge.onStopped = { _ in stopped.signal() }
        bridge.start(String(cString: name), profile: profile)
        var received = Data()
        let deadline = Date().addingTimeInterval(3)
        while received.count < 44 && Date() < deadline {
            var event = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&event,1,100) > 0 {
                var bytes = [UInt8](repeating: 0,count: 128)
                let n = read(master, &bytes, bytes.count)
                if n > 0 { received.append(contentsOf: bytes.prefix(n)) }
            }
        }
        precondition(received.count >= 44 && received.prefix(4) == Data("LPC1".utf8))
        func send(_ payload: Data) {
            let record = Data(Array("LPV1".utf8) + [UInt8(payload.count),0,0]) + payload
            // Deliberately fragmented: tests partial headers and records.
            for byte in record { var byte = byte; precondition(write(master, &byte, 1) == 1) }
        }
        let frame = video(frame: 7, chunk: 4, count: 1, payload: [0xff,0xd8,0xff,0xd9])
        send(frame)
        precondition(delivered.wait(timeout: .now() + 0.15) == .timedOut)
        send(Data(Array("LPC1".utf8) + [received[4] ^ 1,received[5],0,1]))
        send(frame)
        precondition(delivered.wait(timeout: .now() + 0.15) == .timedOut)
        send(Data(Array("LPC1".utf8) + [received[4],received[5],0,1]))
        send(frame)
        precondition(delivered.wait(timeout: .now() + 2) == .success)
        bridge.stop(); precondition(stopped.wait(timeout: .now() + 2) == .success)
    }
    static func preview() throws {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let pipe = PreviewPipeline()
        var rolls: [CGFloat] = []
        pipe.deliver = { frame, image, ms in precondition(image.width == 16 && ms >= 0); rolls.append(frame.roll!) }
        for n in 0..<100 { pipe.submit(data as Data, roll: CGFloat(n), inverted: false) }
        let deadline = Date().addingTimeInterval(3)
        while rolls.last != 99 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(rolls.last == 99 && rolls.count <= 2 && pipe.snapshot().replaced > 0)
        pipe.setPaused(true); pipe.submit(data as Data, roll: 101, inverted: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1)); precondition(rolls.last == 99)
        pipe.setPaused(false); pipe.submit(data as Data, roll: 102, inverted: nil)
        pipe.reset()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1)); precondition(rolls.last == 99)
    }
}
