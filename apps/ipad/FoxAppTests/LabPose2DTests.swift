import XCTest
import FoxTrainingCore
@testable import Fox

final class LabPose2DTests: XCTestCase {
    private func row() -> LabPose2DFrame {
        .init(captureID: "synthetic-capture", sourceID: "synthetic-camera", seq: 4,
              pts: .init(value: "6000001", timescale: 60000), hostReceivedNS: "1234567890123",
              width: 64, height: 96, requestRevision: 1, state: "no_observation", people: [], inferenceNS: "100")
    }
    func testMissingPeopleAndRequestFailureAreDistinctAndRoundTripKeepsExactTime() throws {
        let original = row(); try original.validate()
        let bytes = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, "fox.lab_pose2d.v1")
        XCTAssertEqual((json["pts"] as? [String: Any])?["value"] as? String, "6000001")
        XCTAssertNil(json["automatic_count"])
        let decoded = try JSONDecoder().decode(LabPose2DFrame.self, from: bytes)
        XCTAssertEqual(decoded.pts.value, original.pts.value)
        var failure = original; failure.state = "request_failed"
        XCTAssertThrowsError(try failure.validate())
        failure.reason = "synthetic_failure"; try failure.validate()
    }
    func testEmptySuccessNonfiniteJointAndSilentMirrorAreRejected() throws {
        var value = row(); value.state = "observed"
        XCTAssertThrowsError(try value.validate())
        value.people = [[.init(name: "leftElbow", x: .nan, y: 0.5, confidence: 0.8)]]
        XCTAssertThrowsError(try value.validate())
        value.people[0][0].x = 0.2; try value.validate()
        value.sourceMirrored = true
        XCTAssertThrowsError(try value.validate())
    }
}
