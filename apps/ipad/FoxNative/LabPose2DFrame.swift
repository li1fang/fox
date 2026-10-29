import Foundation
import FoxTrainingCore

/// Independent 2D observations; no counter, subject selector, or inferred workout facts.
struct LabPose2DFrame: Codable {
    struct Joint: Codable {
        var name: String
        var x: Double
        var y: Double
        var confidence: Double
    }
    var schema = "fox.lab_pose2d.v1"
    var captureID: String
    var sourceID: String
    var seq: Int
    var pts: LabRationalTime
    var hostReceivedNS: String
    var width: Int
    var height: Int
    /// EXIF .up: AVCapture output already applied image orientation. No second transform.
    var orientation: UInt32 = 1
    var sourceMirrored = false
    var requestRevision: Int
    var state: String
    var reason: String?
    var people: [[Joint]]
    var inferenceNS: String
    enum CodingKeys: String, CodingKey {
        case schema, seq, pts, width, height, orientation, state, reason, people
        case captureID = "capture_id", sourceID = "source_id", hostReceivedNS = "host_received_ns"
        case sourceMirrored = "source_mirrored", requestRevision = "request_revision", inferenceNS = "inference_ns"
    }
    func validate() throws {
        guard schema == "fox.lab_pose2d.v1", !captureID.isEmpty, !sourceID.isEmpty, seq >= 0,
              Int64(pts.value) != nil, pts.timescale > 0, UInt64(hostReceivedNS) != nil, UInt64(inferenceNS) != nil,
              width > 0, height > 0, orientation == 1, !sourceMirrored, requestRevision > 0,
              ["observed", "no_observation", "request_failed", "dropped"].contains(state),
              people.allSatisfy({ person in
                  !person.isEmpty && Set(person.map(\.name)).count == person.count && person.allSatisfy {
                      PoseJoint(rawValue: $0.name) != nil && $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite &&
                      (0...1).contains($0.x) && (0...1).contains($0.y) && (0...1).contains($0.confidence)
                  }
              }), (state == "observed" ? !people.isEmpty : people.isEmpty),
              (["request_failed", "dropped"].contains(state) ? reason?.isEmpty == false : reason == nil) else {
            throw VisionDiagnosticArchive.error("2D 旁路记录无效，未补造观测。")
        }
    }
}
