import Foundation
import FoxTrainingCore

/// Frozen target-specific capability gate. Empty until independent campaign evidence admits squat.
/// Development/diagnostic access is separate; ordinary admission never enables stopped curl.
enum CountOnlyAvailability {
    private static let qualifiedActions: Set<CountOnlyAction> = []
    static let squatStrategyID = "squat-side-joint-floor-25-h1-v1"
    static var admittedActions: Set<CountOnlyAction> {
        #if DEBUG
        // Existing UI-test namespace only. No user preference or ordinary launch flag opens this gate.
        if ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1",
           ProcessInfo.processInfo.environment["FOX_UI_ADMIT_COUNT_ONLY_SQUAT"] == "1" { return [.squat] }
        #endif
        return qualifiedActions
    }
}
