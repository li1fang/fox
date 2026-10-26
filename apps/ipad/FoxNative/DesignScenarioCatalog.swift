import Foundation

enum DesignScenario: String, CaseIterable, Identifiable {
    case empty = "home-empty", mixed = "home-mixed", longText = "home-long-text"
    case portrait = "home-portrait-photo", landscape = "home-landscape-photo", receipt = "home-long-photo"
    case missing = "home-missing-photo", keyboard = "home-keyboard", loading = "home-loading"
    case failure = "home-save-failure", pagination = "home-pagination", largeType = "home-large-type"
    case dark = "home-dark", rotated = "home-rotated"
    case recordLongPhoto = "record-long-photo", recordMulti = "record-multiple-photos", recordText = "record-long-text"
    case recordMissing = "record-missing-photo", recordConflict = "record-editor-conflict", recordBackup = "record-backup"
    case homePlan = "projection-plan", homeCurrent = "projection-current", homeConfirmed = "projection-confirmed"
    case homeNoTraining = "projection-missing", homeCorruptTraining = "projection-corrupt"
    case trainingReady = "training-ready", trainingWaiting = "training-waiting", trainingActive = "training-active"
    case trainingPaused = "training-paused", trainingRest = "training-rest", trainingFeedback = "training-feedback"
    case trainingSummary = "training-summary", trainingDiagnostic = "training-diagnostic-review"
    case trainingRotated = "training-active-rotated", trainingLargeType = "training-large-type"
    case trainingFeedbackRotated = "training-feedback-rotated"
    var id: String { rawValue }
    var usesLargeType: Bool { self == .largeType || self == .trainingLargeType }
    var usesDarkAppearance: Bool { self == .dark }
    var isLandscape: Bool { self == .rotated || self == .trainingRotated || self == .trainingFeedbackRotated }
    var section: String {
        if rawValue.hasPrefix("record-") { return "records" }
        if rawValue.hasPrefix("projection-") { return "projections" }
        if rawValue.hasPrefix("training-") { return "training" }
        return "home"
    }
    static var homeCases: [Self] { allCases.filter { $0.section == "home" } }
    // Full review is the union of these disjoint partitions, not full + smoke replayed twice.
    static let homeSmokeCases: [Self] = [.mixed, .receipt, .largeType, .dark]
    static var homeRemainingCases: [Self] { homeCases.filter { !homeSmokeCases.contains($0) } }
    static var recordCases: [Self] { allCases.filter { $0.section == "records" } }
    static var projectionCases: [Self] { allCases.filter { $0.section == "projections" } }
    static var trainingCases: [Self] { allCases.filter { $0.section == "training" } }
    static let trainingJourneyCases: [Self] = [.trainingReady, .trainingWaiting, .trainingActive, .trainingPaused,
                                             .trainingRest, .trainingSummary, .trainingRotated, .trainingLargeType]
    static var trainingRemainingCases: [Self] {
        trainingCases.filter { $0 != .trainingFeedbackRotated && !trainingJourneyCases.contains($0) }
    }
    var hasPhoto: Bool { [.mixed, .portrait, .landscape, .receipt, .missing, .dark, .recordLongPhoto, .recordMulti, .recordMissing].contains(self) }
    static var active: DesignScenario? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" else { return nil }
        return ProcessInfo.processInfo.environment["FOX_DESIGN_SCENARIO"].flatMap(Self.init(rawValue:))
        #else
        return nil
        #endif
    }
}
