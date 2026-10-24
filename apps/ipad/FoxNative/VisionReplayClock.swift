#if DEBUG
import Foundation

@MainActor
final class VisionReplayClock {
    var uptime: TimeInterval = 1000
    private let origin: Date
    init(origin: Date = Date()) { self.origin = origin }
    var date: Date { origin.addingTimeInterval(uptime - 1000) }
}
#endif
