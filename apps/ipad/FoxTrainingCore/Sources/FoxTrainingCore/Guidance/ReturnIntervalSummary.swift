import Foundation

public struct ReturnIntervalRow: Codable, Equatable, Identifiable {
    public var repetition: Int
    public var seconds: Double?
    public var reason: String?
    public var coverage = "observed_interval_not_full_eccentric"
    public var observationID: UUID? = nil
    public var id: Int { repetition }
}

public enum ReturnIntervalSummary {
    /// Return links use segment-local indexes. Never flatten before resolving them:
    /// the next segment must not fill the previous segment's unobserved terminal return.
    public static func make(segments: [(UUID, [CurlRepetition])], exercise: VisionExercise) -> [ReturnIntervalRow] {
        var rows: [ReturnIntervalRow] = []
        for (id, repetitions) in segments {
            let offset = rows.count
            rows += make(repetitions, exercise: exercise).map { row in
                var result = row; result.repetition += offset; result.observationID = id
                return result
            }
        }
        return rows
    }

    public static func make(evidence: WorkoutVisualEvidence) -> [ReturnIntervalRow] {
        make(segments: evidence.segments.map { ($0.id, $0.repetitions) }, exercise: evidence.settings.exercise)
    }

    /// Keep this separate from legacy rhythm scores: none of the current strategies supports
    /// comparing these visible intervals with a full physiological eccentric-duration target.
    public static func make(_ repetitions: [CurlRepetition], exercise: VisionExercise) -> [ReturnIntervalRow] {
        repetitions.indices.map { index in
            if exercise == .latPulldown && index == repetitions.count - 1 {
                return .init(repetition: index + 1, reason: "terminal_return_unpublished")
            }
            let measurement: PoseEccentricMeasurement?
            if exercise == .latPulldown {
                measurement = repetitions.dropFirst(index + 1).compactMap(\.precedingReturn)
                    .first { $0.repetitionIndex == index }?.measurement
            } else { measurement = repetitions[index].eccentric }
            guard let measurement else { return .init(repetition: index + 1, reason: "not_recorded") }
            guard measurement.status == .measured else {
                return .init(repetition: index + 1, reason: measurement.status.rawValue)
            }
            guard let seconds = measurement.durationSeconds, seconds.isFinite, seconds > 0 else {
                return .init(repetition: index + 1, reason: "invalid_interval")
            }
            return .init(repetition: index + 1, seconds: seconds)
        }
    }
}
