import Foundation

/// User-authored review, never an instruction to edit a profile or prescribe training.
/// The containing set/trial supplies identity; empty categories remain absent rather than inferred.
public struct TrialReview: Codable, Equatable {
    public let schema: String
    public let information: String?
    public let softwareIssue: String?
    public let trainingFeeling: String?
    public let recordedAt: Date

    public static func make(information: String, softwareIssue: String, trainingFeeling: String, at date: Date) throws -> Self? {
        let values = [information, softwareIssue, trainingFeeling].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.contains(where: { !$0.isEmpty }) else { return nil }
        let review = Self(schema: "fox.trial_review.v1", information: values[0].isEmpty ? nil : values[0],
            softwareIssue: values[1].isEmpty ? nil : values[1], trainingFeeling: values[2].isEmpty ? nil : values[2], recordedAt: date)
        try review.validate()
        return review
    }

    public func validate() throws {
        let values = [information, softwareIssue, trainingFeeling].compactMap { $0 }
        guard schema == "fox.trial_review.v1", recordedAt.timeIntervalSince1970.isFinite, !values.isEmpty,
              values.allSatisfy({ !$0.isEmpty && $0.count <= 4000 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw TrainingError.invalidRecord
        }
    }
}

public struct WeightConfirmation: Codable, Equatable {
    public enum Source: String, Codable { case beforeSet = "before_set", setReview = "set_review", summaryCorrection = "summary_correction" }
    public let attemptID: UUID
    public let weight: Double?
    public let unit: String?
    public let source: Source
    public let confirmedAt: Date

    public func validate(attemptID: UUID, weight: Double?, unit: String?) throws {
        guard self.attemptID == attemptID, self.weight == weight, self.unit == unit,
              confirmedAt.timeIntervalSince1970.isFinite else { throw TrainingError.invalidRecord }
    }
}
