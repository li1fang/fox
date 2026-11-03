import XCTest
@testable import PumpCore

final class PumpControlApprovalTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"
    private func strength(_ kg: Double = 2, mode: PumpMode = .standard, reduction: Int = 0) throws -> PumpStrength {
        try PumpStrength(mode:mode, kg:kg, reduction:reduction)
    }
    private func approved(_ value: PumpStrength) throws -> PumpControlApproval {
        var permit = PumpControlApproval()
        try permit.approve(slot:"A", peripheralID:a, strength:value, identityConfirmed:true, stopMethodConfirmed:true, now:10)
        return permit
    }
    func testStartsLockedAndRejectsMissingPhysicalConfirmations() throws {
        var permit = PumpControlApproval()
        XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:10))
        for confirmations in [(false,false), (true,false), (false,true)] {
            XCTAssertThrowsError(try permit.approve(slot:"A", peripheralID:a, strength:strength(), identityConfirmed:confirmations.0, stopMethodConfirmed:confirmations.1, now:10))
        }
    }
    func testInvalidIdentityOrTimeCannotAuthorize() throws {
        for (slot,id,time) in [("C",a,10.0),("A","",10),("A","not-a-uuid",10),("A",a,Double.nan),("A",a,Double.infinity),("A",a,-1)] {
            var permit = PumpControlApproval()
            XCTAssertThrowsError(try permit.approve(slot:slot, peripheralID:id, strength:strength(), identityConfirmed:true, stopMethodConfirmed:true, now:time))
        }
    }
    func testRecordBeforeExactlyOneWriteAndNoReplay() throws {
        let value = try strength(); var permit = try approved(value), events = [String](), sent = [Data]()
        try permit.performWrite(slot:"A", peripheralID:a, strength:value, now:11, record:{ events.append("record") }, write:{ events.append("write"); sent.append($0) })
        XCTAssertEqual(events,["record","write"]); XCTAssertEqual(sent,[value.packet])
        XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:11))
        XCTAssertThrowsError(try permit.performWrite(slot:"A", peripheralID:a, strength:value, now:11, record:{}, write:{ sent.append($0) }))
        XCTAssertEqual(sent.count,1)
    }
    func testDeviceSlotAndEveryParameterAreBoundToTheApproval() throws {
        let value = try strength()
        let alternatives = [("B",a,value),("A",b,value),("A",a,try strength(3)),("A",a,try strength(mode:.constant)),("A",a,try strength(mode:.eccentric,reduction:25))]
        for (slot,id,other) in alternatives {
            var permit = try approved(value), writes = 0
            XCTAssertThrowsError(try permit.performWrite(slot:slot, peripheralID:id, strength:other, now:11, record:{ XCTFail("must not record write attempt") }, write:{ _ in writes += 1 }))
            XCTAssertEqual(writes,0)
            XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:11))
        }
        var permit = try approved(strength(mode:.eccentric,reduction:25))
        XCTAssertThrowsError(try permit.performWrite(slot:"A", peripheralID:a, strength:strength(mode:.eccentric,reduction:50), now:11, record:{}, write:{ _ in XCTFail("changed reduction") }))
    }
    func testExpiryClockReversalAndExplicitRevocationBlockWrites() throws {
        for time in [9.0,70,71,Double.nan,Double.infinity] {
            var permit = try approved(strength())
            XCTAssertThrowsError(try permit.performWrite(slot:"A", peripheralID:a, strength:strength(), now:time, record:{}, write:{ _ in XCTFail("expired") }))
        }
        var permit = try approved(strength()); permit.revoke()
        XCTAssertThrowsError(try permit.performWrite(slot:"A", peripheralID:a, strength:strength(), now:11, record:{}, write:{ _ in XCTFail("revoked") }))
    }
    func testJournalFailureNeverWritesOrRestoresPermission() throws {
        var permit = try approved(strength()), writes = 0
        XCTAssertThrowsError(try permit.performWrite(slot:"A", peripheralID:a, strength:strength(), now:11, record:{ throw PumpError.rejected("disk full") }, write:{ _ in writes += 1 }))
        XCTAssertEqual(writes,0); XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:11))
    }
    func testNewApprovalReplacesRatherThanQueuesPreviousDevice() throws {
        var permit = try approved(strength())
        try permit.approve(slot:"B", peripheralID:b, strength:strength(3), identityConfirmed:true, stopMethodConfirmed:true, now:11)
        XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:12))
        XCTAssertTrue(permit.isAuthorized(slot:"B", peripheralID:b, now:12))
    }
    func testDisconnectedOtherSlotDoesNotEraseTheSelectedDeviceApproval() throws {
        var permit = try approved(strength())
        permit.revoke(slot:"B")
        XCTAssertTrue(permit.isAuthorized(slot:"A", peripheralID:a, now:11))
        permit.revoke(slot:"A")
        XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:11))
    }
    func testInvalidNewApprovalRevokesOldOneAndFourModesStillEncode() throws {
        var permit = try approved(strength())
        XCTAssertThrowsError(try permit.approve(slot:"B", peripheralID:b, strength:strength(), identityConfirmed:false, stopMethodConfirmed:true, now:11))
        XCTAssertFalse(permit.isAuthorized(slot:"A", peripheralID:a, now:12))
        for mode in PumpMode.allCases {
            let value = try strength(mode:mode); var next = try approved(value)
            var sent = [Data]()
            try next.performWrite(slot:"A", peripheralID:a, strength:value, now:11, record:{}, write:{ sent.append($0) })
            XCTAssertEqual(sent,[value.packet])
        }
    }
    func testJournalFailureReentryCompletesOnceAndPreservesNotSent() throws {
        var permit = try approved(strength()), outcome = PumpCommandOutcome(), completions = [String](), writes = 0
        func finish() { if let status = outcome.complete(hasError:true) { completions.append(status) } }
        do {
            try permit.performWrite(slot:"A",peripheralID:a,strength:strength(),now:11,record:{
                finish() // session journal failure can finish before throwing
                throw PumpError.rejected("disk full")
            },write:{ _ in outcome.markWriterInvoked(); writes += 1 })
            XCTFail("must fail")
        } catch { finish() }
        XCTAssertEqual(writes,0); XCTAssertEqual(completions,["not_sent"])
        XCTAssertFalse(permit.isAuthorized(slot:"A",peripheralID:a,now:11))
    }
    func testOnlyInvokedWriterMayProduceUnknownOrUnverifiedResponse() {
        var unknown = PumpCommandOutcome(); unknown.markWriterInvoked()
        XCTAssertEqual(unknown.complete(hasError:true),"unknown")
        XCTAssertNil(unknown.complete(hasError:true))
        var response = PumpCommandOutcome(); response.markWriterInvoked()
        XCTAssertEqual(response.complete(hasError:false),"response_unverified")
        var neverSent = PumpCommandOutcome()
        XCTAssertEqual(neverSent.complete(hasError:false),"not_sent")
    }
}
