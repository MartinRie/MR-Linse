import Foundation
import ImageIO

/// At most one decode and one pending JPEG, including while the main thread is busy.
final class PreviewPipeline {
    struct Frame {
        let jpeg: Data
        let roll: CGFloat?
        let inverted: Bool?
        let received: TimeInterval
    }
    struct Statistics {
        var received = 0
        var replaced = 0
        var lastReceived: TimeInterval = 0
    }
    var deliver: ((Frame, CGImage, Double) -> Void)? // Called on main.
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MRLinse.decode", qos: .userInitiated)
    private var latest: Frame?
    private var busy = false
    private var generation = 0
    private var paused = false
    private var stats = Statistics()
    func snapshot() -> Statistics { lock.lock(); defer { lock.unlock() }; return stats }
    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; if value { latest = nil }; lock.unlock()
    }
    func reset() {
        lock.lock(); generation += 1; latest = nil; stats = Statistics(); paused = false; lock.unlock()
    }
    func submit(_ jpeg: Data, roll: CGFloat?, inverted: Bool?) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        stats.received += 1; stats.lastReceived = now
        if !paused {
            if latest != nil { stats.replaced += 1 }
            latest = Frame(jpeg: jpeg, roll: roll, inverted: inverted, received: now)
        }
        scheduleLocked()
        lock.unlock()
    }
    private func scheduleLocked() {
        guard !busy, latest != nil else { return }
        busy = true
        queue.async { [weak self] in self?.decode() }
    }
    private func decode() {
        lock.lock(); let frame = latest; latest = nil; let token = generation; lock.unlock()
        let image: CGImage? = autoreleasepool {
            guard let frame,
                  let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = token == self.generation && !self.paused
            self.lock.unlock()
            if valid, let frame, let image {
                self.deliver?(frame, image, (ProcessInfo.processInfo.systemUptime - frame.received) * 1000)
            }
            self.lock.lock(); self.busy = false; self.scheduleLocked(); self.lock.unlock()
        }
    }
}
