import XCTest
@testable import FoxTrainingCore

final class Pose3DContractTests: XCTestCase {
    private let identity: [Double] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    private func context(_ index: Int = 0, value: Int64 = 0, scale: Int32 = 30, segment: String = "segment") -> Pose3DFrameContext {
        .init(streamID: "capture", segmentID: segment, frameIndex: index, pts: .init(value: value, timescale: scale), width: 640, height: 480)
    }
    private func skeleton(_ joints: [Pose3DJoint]? = nil, height: Double = 1.8) -> Pose3DSkeleton {
        .init(joints: joints ?? Pose3DJointName.allCases.map { .init(name: $0, modelTransform: identity) },
              cameraOriginMatrix: identity, bodyHeightMeters: height, heightSource: .reference)
    }
    func testRejectsMissingDuplicateNonfiniteAndMalformedJoints() throws {
        let all = Pose3DJointName.allCases.map { Pose3DJoint(name: $0, modelTransform: identity) }
        try skeleton().validate()
        XCTAssertThrowsError(try skeleton(Array(all.dropLast())).validate())
        XCTAssertThrowsError(try skeleton(Array(all.dropLast()) + [all[0]]).validate())
        var nan = all; nan[0] = .init(name: .root, modelTransform: [.nan] + Array(identity.dropFirst()))
        XCTAssertThrowsError(try skeleton(nan).validate())
        var malformed = all; malformed[0] = .init(name: .root, modelTransform: [0])
        XCTAssertThrowsError(try skeleton(malformed).validate())
        XCTAssertThrowsError(try skeleton(height: .infinity).validate())
    }
    func testRejectsInvalidTimeDimensionsAndOrientation() throws {
        XCTAssertThrowsError(try context(scale: 0).validate())
        XCTAssertThrowsError(try context(-1).validate())
        XCTAssertThrowsError(try Pose3DFrameContext(streamID: "", segmentID: "s", frameIndex: 0, pts: nil, width: 0, height: 1, orientation: 9).validate())
        XCTAssertTrue(Pose3DTime(value: Int64.min, timescale: 30).sameInstant(as: .init(value: Int64.min, timescale: 30)))
    }
    func testFrameGapsAreExplicitAndResetDoesNotJoinStreams() throws {
        XCTAssertEqual(try context(3, value: 3).missingFrames(after: context()), 2)
        XCTAssertThrowsError(try context().missingFrames(after: context()))
        XCTAssertThrowsError(try context(1, value: 0).missingFrames(after: context()))
        XCTAssertThrowsError(try context(1, value: 1, segment: "new").missingFrames(after: context()))
    }
    func testResultStatesCannotMixFailureSkeletonAndSuccess() throws {
        let valid = Pose3DFrame(context: context(), requestedRevision: 1, actualRevision: 1, outcome: .observed, skeleton: skeleton())
        try valid.validate()
        XCTAssertEqual(try JSONDecoder().decode(Pose3DFrame.self, from: JSONEncoder().encode(valid)), valid)
        let stamp = Pose3DTime(value: Int64.max, timescale: 30000, epoch: 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp)) as? [String:Any])
        XCTAssertEqual(json["value"] as? String, String(Int64.max))
        XCTAssertThrowsError(try Pose3DFrame(context: context(), requestedRevision: 1, outcome: .observed).validate())
        XCTAssertThrowsError(try Pose3DFrame(context: context(), requestedRevision: 1, outcome: .noObservation, skeleton: skeleton()).validate())
        XCTAssertThrowsError(try Pose3DFrame(context: context(), requestedRevision: 1, outcome: .requestFailed).validate())
        XCTAssertThrowsError(try Pose3DFrame(context: context(), requestedRevision: 1, actualRevision: 2, outcome: .observed, skeleton: skeleton()).validate())
    }
    func testComparisonRequiresSourceIdentityAndNeverConfirmsPersonOrAccuracy() throws {
        let matched = Pose3DComparison(twoDArtifactID: "2d", twoD: context(1,value: 1), threeDArtifactID: "3d", threeD: context(1,value: 2,scale: 60))
        XCTAssertTrue(matched.sameSourceFrame)
        XCTAssertEqual(matched.subjectCorrespondence, "unverified")
        XCTAssertFalse(Pose3DComparison(twoDArtifactID: "2d", twoD: context(), threeDArtifactID: "3d", threeD: context(1,value: 1)).sameSourceFrame)
    }
}
