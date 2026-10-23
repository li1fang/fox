import Foundation

public struct PoseVideoRow: Codable {
    public var seconds: Double
    public var width: Double
    public var height: Double
    public var people: [[PoseTraceJoint]]
    public init(seconds: Double, width: Double, height: Double, people: [[PoseTraceJoint]]) {
        self.seconds = seconds; self.width = width; self.height = height; self.people = people
    }
    public func frame() throws -> PoseFrame {
        guard seconds.isFinite, seconds >= 0, width.isFinite, height.isFinite, width > 0, height > 0,
              max(width, height) <= 16384, people.count <= 10 else { throw VisionTrialError.invalidReport }
        let bodies = try people.map { joints -> BodyPose in
            guard Set(joints.map(\.joint)).count == joints.count,
                  joints.allSatisfy({ PosePoint(x: $0.x, y: $0.y, confidence: $0.confidence).isValid }) else {
                throw VisionTrialError.invalidReport
            }
            return BodyPose(points: Dictionary(uniqueKeysWithValues: joints.map {
                ($0.joint, PosePoint(x: $0.x, y: $0.y, confidence: $0.confidence))
            }))
        }
        return PoseFrame(timestamp: seconds, width: width, height: height, people: bodies)
    }
}

public struct PoseEventMatch: Codable, Equatable {
    public var predictedIndex: Int
    public var start: Double
    public var peak: Double
    public var end: Double
    public var candidatePeaks: [Double]
    public var status: String
}
public struct PoseEventEvaluation: Codable {
    public var events: [PoseEventMatch]
    public var unmatchedPeakCandidates: [Double]
    public var labelStatus = "provisional-peak-labels-not-complete-cycle-ground-truth"
}
public enum PoseEventEvaluator {
    public static func evaluate(_ repetitions: [CurlRepetition], origin: Double, peaks: [Double]) throws -> PoseEventEvaluation {
        guard origin.isFinite, peaks.allSatisfy({ $0.isFinite && $0 >= 0 }), Set(peaks).count == peaks.count else {
            throw VisionTrialError.invalidReport
        }
        var claimed = Set<Double>(), previousEnd = -Double.infinity
        var events: [PoseEventMatch] = []
        for (index, rep) in repetitions.enumerated() {
            guard let start = rep.startedAtSeconds, let peak = rep.peakAtSeconds, let end = rep.loweredAtSeconds,
                  [start, peak, end].allSatisfy({ $0.isFinite && $0 >= 0 }), start <= peak, peak <= end,
                  start + origin >= previousEnd else { throw VisionTrialError.invalidReport }
            let contained = peaks.filter { $0 >= start + origin && $0 <= end + origin && !claimed.contains($0) }
            claimed.formUnion(contained); previousEnd = end + origin
            events.append(PoseEventMatch(predictedIndex: index + 1, start: start + origin, peak: peak + origin,
                end: end + origin, candidatePeaks: contained,
                status: contained.count == 1 ? "one-peak-in-observed-cycle" : (contained.isEmpty ? "unmatched-predicted-event" : "merged-peaks")))
        }
        return PoseEventEvaluation(events: events, unmatchedPeakCandidates: peaks.filter { !claimed.contains($0) })
    }
}
