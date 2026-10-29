import Foundation

/// At most one in-flight analysis, with no queued camera buffers. Recording never waits on this gate.
final class FreeCaptureAnalysisGate {
    enum Admission: Equatable { case accepted, busy, closed, wrongCapture }
    let captureID: UUID
    private let lock = NSLock()
    private var activeFrame: UInt64?
    private var closed = false
    private var drops = 0
    init(captureID: UUID) { self.captureID = captureID }
    var busyDrops: Int { lock.lock(); defer { lock.unlock() }; return drops }
    func admit(captureID: UUID, frame: UInt64) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard captureID == self.captureID else { return .wrongCapture }
        guard !closed else { return .closed }
        guard activeFrame == nil else { drops += 1; return .busy }
        activeFrame = frame
        return .accepted
    }
    @discardableResult
    func complete(captureID: UUID, frame: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, captureID == self.captureID, activeFrame == frame else { return false }
        activeFrame = nil
        return true
    }
    @discardableResult
    func close() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let pending = activeFrame != nil; closed = true; activeFrame = nil
        return pending
    }
}
