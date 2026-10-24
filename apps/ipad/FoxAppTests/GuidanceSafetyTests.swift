import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class GuidanceSafetyTests: XCTestCase {
    private final class Driver: SpeechOutputDriver {
        var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
        var submitted: [GuidanceCue] = []
        var stops = 0
        func speak(_ cue: GuidanceCue) -> Bool { submitted.append(cue); return true }
        func stop() { stops += 1 }
    }
    private func input(_ time: Double, countdown: Int? = nil, stage: GuidanceStage = .countdown, remaining: Int? = nil) -> GuidanceInput {
        .init(context: .init(sessionID: "s", attemptID: "a", observationID: "o"), time: time,
              stage: stage, exercise: .curl, mode: .observed, count: 0, targetReps: nil,
              motion: nil, tempo: [], elapsed: time, countdown: countdown, remainingSets: remaining)
    }

    func testCountdownCannotSpeakOldNumberAfterNextNumberIsVisible() throws {
        let driver = Driver(); var time = 0.0
        let output = GuidanceOutputController(driver: driver, now: { time })
        output.update(input(0, countdown: 3))
        let old = try XCTUnwrap(driver.submitted.last)
        time = 1; output.update(input(time, countdown: 2))
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(driver.submitted.last?.text, "2")
        driver.onEvent?(old.id, .started)
        driver.onEvent?(old.id, .finished)
        XCTAssertEqual(driver.submitted.count, 2, "Late callbacks cannot restore obsolete countdown")
        time = 2; output.update(input(time, countdown: 1))
        XCTAssertEqual(driver.submitted.last?.text, "1")
        time = 3; output.update(input(time, stage: .active))
        XCTAssertEqual(driver.submitted.last?.text, "开始")
        XCTAssertEqual(output.events.filter { $0.cue?.kind == .count }.count, 0)
    }

    func testDeliveryCarriesPolicyVersionAndOldEventsStillDecode() throws {
        let driver = Driver(), output = GuidanceOutputController(driver: driver, now: { 0 })
        output.update(input(0, countdown: 3))
        let event = try XCTUnwrap(output.events.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(json["policyVersion"] as? String, GuidancePolicy.version)
        json.removeValue(forKey: "policyVersion")
        let old = try JSONDecoder().decode(GuidanceDeliveryEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.cueID, event.cueID)
    }

    func testLastSetEncouragementUsesConfirmedRestProgressOnly() {
        for remaining in [nil, 0, 1, 2] as [Int?] {
            var policy = GuidancePolicy()
            let result = policy.update(input(0, stage: .rest, remaining: remaining))
            XCTAssertEqual(result.cues.first?.text.contains("最后一组"), remaining == 1)
        }
        var policy = GuidancePolicy()
        XCTAssertFalse(policy.update(input(0, stage: .feedback, remaining: 1)).cues.contains { $0.text.contains("最后一组") },
                       "Before feedback saves, remainingSets still includes the current set")
    }
}
