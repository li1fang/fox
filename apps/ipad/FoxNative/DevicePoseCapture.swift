import CoreMotion
import FoxTrainingCore
import Foundation

struct TimedGravity {
    let timestamp: Double
    let x: Double
    let y: Double
    let z: Double
}

@MainActor
final class DevicePoseCapture {
    var onReading: ((UUID, TimedGravity) -> Void)?
    var onStatus: ((UUID, VisionMotionStatus) -> Void)?
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "fox.device.pose"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var runID: UUID?

    func start(id: UUID) {
        stop()
        runID = id
        guard manager.isDeviceMotionAvailable else { onStatus?(id, .unavailable); return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            let reading = motion.map { TimedGravity(timestamp: $0.timestamp, x: $0.gravity.x, y: $0.gravity.y, z: $0.gravity.z) }
            DispatchQueue.main.async {
                guard let self, self.runID == id else { return }
                if error != nil { self.onStatus?(id, .failed) }
                else if let reading { self.onReading?(id, reading); self.onStatus?(id, .available) }
            }
        }
    }

    func stop() {
        runID = nil
        manager.stopDeviceMotionUpdates()
    }
}
