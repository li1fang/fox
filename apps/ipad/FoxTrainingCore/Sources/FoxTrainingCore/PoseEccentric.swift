import Foundation

public struct PoseEccentricPolicy: Codable, Equatable {
    public var schema = "fox.eccentric_policy.v1"
    public var noiseBandDegrees = 2.0
    public var reversalDegrees = 6.0
    public var confirmationSeconds = 0.2
    public var minimumExcursionDegrees = 20.0
    public var maximumObservationGapSeconds = 0.25
    public init() {}
    public func validate() throws {
        guard schema == "fox.eccentric_policy.v1", (0.5...4).contains(noiseBandDegrees),
              (4...15).contains(reversalDegrees), reversalDegrees > noiseBandDegrees,
              (0.1...0.5).contains(confirmationSeconds), (15...45).contains(minimumExcursionDegrees),
              (0.15...0.4).contains(maximumObservationGapSeconds),
              minimumExcursionDegrees > reversalDegrees else { throw PoseConfigurationError.invalid }
    }
}

public enum PoseEccentricStatus: String, Codable {
    case measured, trackingGap, insufficientMotion, nonMonotonic
}

public enum PoseReturnPhaseStatus: String, Codable { case waiting, returning, unavailable }

/// Current causal signal, not a finished duration. Detection uses the tracker's relative clock;
/// adapters must not use a retrospectively estimated onset as the cue's emission time.
public struct PoseReturnPhaseObservation: Codable, Equatable {
    public var status: PoseReturnPhaseStatus
    public var detectedAtSeconds: Double?
    public var failure: PoseEccentricStatus?
}

public struct PoseEccentricMeasurement: Codable, Equatable {
    public var schema = "fox.eccentric_measurement.v1"
    public var status: PoseEccentricStatus
    public var startedAtSeconds: Double?
    public var detectedAtSeconds: Double?
    public var endedAtSeconds: Double?
    public var durationSeconds: Double?
    // Start is the first sustained reversal sample; the earlier bound is the last near-peak sample.
    public var onsetUncertaintySeconds: Double?
    public func validate(start: Double, end: Double, gap: Double) throws {
        guard schema == "fox.eccentric_measurement.v1" else { throw VisionTrialError.invalidReport }
        if status == .measured {
            guard gap == 0, let a = startedAtSeconds, let b = detectedAtSeconds, let c = endedAtSeconds, let d = durationSeconds,
                  let uncertainty = onsetUncertaintySeconds,
                  [a,b,c,d,uncertainty].allSatisfy({ $0.isFinite }), uncertainty >= 0, start <= a - uncertainty,
                  a <= b, b <= c, c <= end,
                  d > 0, abs(c - a - d) < 0.000001 else { throw VisionTrialError.invalidReport }
        } else if startedAtSeconds != nil || detectedAtSeconds != nil || endedAtSeconds != nil || durationSeconds != nil || onsetUncertaintySeconds != nil {
            throw VisionTrialError.invalidReport
        }
    }
}

/// Causal angular reversal estimate, ending at the observed counting endpoint.
/// This is neither muscle activation nor a claim of complete anatomical extension.
public struct PoseEccentricEstimator {
    public let policy: PoseEccentricPolicy
    private var minimum: Double?
    private var nearPeakAt: Double?
    private var candidateAt: Double?
    private var onsetAt: Double?
    private var onsetEarliestAt: Double?
    private var detectedAt: Double?
    private var lastTime: Double?
    private var lastAngle: Double?
    private var failure: PoseEccentricStatus?
    private var maximumAfterOnset: Double?
    public var currentPhaseObservation: PoseReturnPhaseObservation {
        if let failure { return .init(status: .unavailable, failure: failure) }
        return .init(status: detectedAt == nil ? .waiting : .returning, detectedAtSeconds: detectedAt)
    }
    public init(policy: PoseEccentricPolicy) {
        precondition((try? policy.validate()) != nil)
        self.policy = policy
    }
    public mutating func markGap() { failure = .trackingGap }
    public mutating func observe(angle: Double, at time: Double) {
        guard angle.isFinite, (0...180).contains(angle), time.isFinite, time >= 0,
              lastTime.map({ time > $0 }) ?? true else { markGap(); return }
        if let lastTime, time - lastTime > policy.maximumObservationGapSeconds { markGap() }
        lastTime = time; lastAngle = angle
        if detectedAt != nil {
            if let high = maximumAfterOnset, high - angle > policy.reversalDegrees { failure = failure ?? .nonMonotonic }
            maximumAfterOnset = max(maximumAfterOnset ?? angle, angle)
            return
        }
        if minimum == nil || angle < minimum! {
            minimum = angle; nearPeakAt = time; candidateAt = nil
        } else if angle <= minimum! + policy.noiseBandDegrees {
            nearPeakAt = time; candidateAt = nil
        } else if angle >= minimum! + policy.reversalDegrees {
            if candidateAt == nil { candidateAt = time }
            if time - candidateAt! >= policy.confirmationSeconds - 0.000001 {
                onsetEarliestAt = nearPeakAt; onsetAt = candidateAt; detectedAt = time; maximumAfterOnset = angle
            }
        } else { candidateAt = nil }
    }
    public func finish(at end: Double) -> PoseEccentricMeasurement {
        if let failure { return PoseEccentricMeasurement(status: failure) }
        guard let start = onsetAt, let earliest = onsetEarliestAt, let detected = detectedAt, let minimum, let lastAngle, let lastTime,
              end.isFinite, start < detected, detected <= end, end <= lastTime,
              lastAngle - minimum >= policy.minimumExcursionDegrees else {
            return PoseEccentricMeasurement(status: .insufficientMotion)
        }
        return PoseEccentricMeasurement(status: .measured, startedAtSeconds: start,
            detectedAtSeconds: detected, endedAtSeconds: end, durationSeconds: end - start,
            onsetUncertaintySeconds: start - earliest)
    }
}
