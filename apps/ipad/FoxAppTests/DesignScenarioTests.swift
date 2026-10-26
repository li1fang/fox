import XCTest
@testable import Fox

final class DesignScenarioTests: XCTestCase {
    func testScenarioOwnershipIsCompleteAndDisjoint() {
        XCTAssertEqual(DesignScenario.homeSmokeCases, [.mixed, .receipt, .largeType, .dark])
        let home = DesignScenario.homeRemainingCases + DesignScenario.homeSmokeCases
        XCTAssertEqual(Set(home), Set(DesignScenario.homeCases))
        XCTAssertEqual(home.count, Set(home).count)
        let training = DesignScenario.trainingRemainingCases + DesignScenario.trainingJourneyCases + [.trainingFeedbackRotated]
        XCTAssertEqual(Set(training), Set(DesignScenario.trainingCases))
        XCTAssertEqual(training.count, Set(training).count)
        XCTAssertEqual(DesignScenario.recordCases.count, 6)
        XCTAssertEqual(DesignScenario.projectionCases.count, 5)
    }
}
