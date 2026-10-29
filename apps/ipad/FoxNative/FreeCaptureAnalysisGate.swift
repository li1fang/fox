import Foundation

/// One laboratory analysis across captures and backend/page instances, without queued buffers.
final class FreeCaptureAnalysisGate {
    enum Admission: Equatable { case accepted, busy, closed, wrongCapture }
    let captureID: UUID
    private let lock = NSLock()
    private static let budgetLock = NSLock()
    private static var budgetOwner: UUID?
    private let owner = UUID()
    private var activeFrame: UInt64?
    private var workerFinished = false
    private var closed = false
    private var drops = 0
    init(captureID: UUID) { self.captureID = captureID }
    deinit { releaseBudget() }
    private func releaseBudget() {
        Self.budgetLock.lock(); defer { Self.budgetLock.unlock() }
        if Self.budgetOwner == owner { Self.budgetOwner = nil }
    }
    var busyDrops: Int { lock.lock(); defer { lock.unlock() }; return drops }
    func admit(captureID: UUID, frame: UInt64) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard captureID == self.captureID else { return .wrongCapture }
        guard !closed else { return .closed }
        guard activeFrame == nil else { drops += 1; return .busy }
        Self.budgetLock.lock(); defer { Self.budgetLock.unlock() }
        guard Self.budgetOwner == nil else { drops += 1; return .busy }
        Self.budgetOwner = owner
        activeFrame = frame; workerFinished = false
        return .accepted
    }
    @discardableResult
    func complete(captureID: UUID, frame: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard captureID == self.captureID, activeFrame == frame else { return false }
        activeFrame = nil; workerFinished = false
        releaseBudget()
        return !closed
    }
    @discardableResult
    func close() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Stop/seal never waits for inference. Keep its slot until the actual
        // worker returns so a new capture cannot accumulate another request.
        let pending = activeFrame != nil; closed = true
        return pending
    }
    private func mayContinue(captureID: UUID, frame: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && !workerFinished && self.captureID == captureID && activeFrame == frame
    }
    private func finishWork(captureID: UUID, frame: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.captureID == captureID, activeFrame == frame, !workerFinished else { return false }
        workerFinished = true
        // Another backend may analyze after this worker returns, but this capture
        // still owns an undelivered result. Stop must account for that missing row.
        releaseBudget()
        return !closed
    }
    /// Check cancellation at each request boundary. Already-running Vision work
    /// finishes on its own queue; a stopped capture never starts its later stage.
    func perform(captureID: UUID, frame: UInt64, first: () -> Void, then second: () -> Void) -> Bool {
        if mayContinue(captureID: captureID, frame: frame) {
            first()
            if mayContinue(captureID: captureID, frame: frame) { second() }
        }
        return finishWork(captureID: captureID, frame: frame)
    }
}
