import Foundation

/// A user's review of an observation is not a visual ground-truth label.
public enum TrialCountChoice: String, Codable {
    case confirmedObserved = "confirmed_observed"
    case corrected
    case unconfirmed
}

public struct TrialCountReview: Codable, Equatable {
    public var schema = "fox.trial_count_review.v1"
    public let choice: TrialCountChoice
    public let observedCount: Int?
    public let confirmedCount: Int?
    public var observationProtocol = "apple-2d-source-pts-cadence-v1"
    public var guidanceProtocol = "squat-side-guide-v1"
    public var strategyID = "squat-side-joint-floor-25-h1-v1"

    public init(choice: TrialCountChoice, observedCount: Int?, confirmedCount: Int?) throws {
        self.choice=choice;self.observedCount=observedCount;self.confirmedCount=confirmedCount
        try validate()
    }
    public func validate() throws {
        guard schema == "fox.trial_count_review.v1", observationProtocol == "apple-2d-source-pts-cadence-v1",
              guidanceProtocol == "squat-side-guide-v1", strategyID == "squat-side-joint-floor-25-h1-v1",
              observedCount.map({$0 >= 0}) ?? true,
              confirmedCount.map({(0...1000).contains($0)}) ?? true else { throw TrainingError.invalidRecord }
        switch choice {
        case .confirmedObserved:
            guard let observedCount, confirmedCount == observedCount else {throw TrainingError.invalidRecord}
        case .corrected: guard confirmedCount != nil else {throw TrainingError.invalidRecord}
        case .unconfirmed: guard confirmedCount == nil else {throw TrainingError.invalidRecord}
        }
    }
}
