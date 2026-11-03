import XCTest
@testable import PumpCore

final class PumpGroupTests: XCTestCase {
    private let ids = ["A":"11111111-1111-4111-8111-111111111111","B":"22222222-2222-4222-8222-222222222222"]
    private func request(_ kg: Double = 2, id: String = UUID().uuidString) throws -> PumpGroupRequest {
        try PumpGroupRequest(id:id,devices:ids,strength:PumpStrength(mode:.standard,kg:kg,profile:.pumpPro))
    }
    func testProExtremesAndLegacyRangeRemainDistinct() throws {
        XCTAssertEqual(try PumpStrength(mode:.standard,kg:20,profile:.pumpPro).packet.pumpHex,"54060201c8db")
        XCTAssertEqual(try PumpStrength(mode:.constant,kg:20,profile:.pumpPro).packet.pumpHex,"54060207c8d5")
        XCTAssertEqual(try PumpStrength(mode:.eccentric,kg:20,reduction:25,profile:.pumpPro).packet.pumpHex,"54070205c819bd")
        XCTAssertThrowsError(try PumpStrength(mode:.standard,kg:20))
        for mode in PumpMode.allCases {
            let min = PumpMachineProfile.pumpPro.minimum(mode)
            XCTAssertNoThrow(try PumpStrength(mode:mode,kg:min,profile:.pumpPro))
            XCTAssertNoThrow(try PumpStrength(mode:mode,kg:20,profile:.pumpPro))
            for kg in [min-0.1,20.1,Double.nan,Double.infinity,2.00001] {
                XCTAssertThrowsError(try PumpStrength(mode:mode,kg:kg,profile:.pumpPro))
            }
        }
    }
    func testLateGattAckCannotAcknowledgeNewRequestAfterTimeout() throws {
        var ledger=PumpWriteLedger()
        try ledger.begin("old-request")
        // Timeout/cancel completes application waiting, not the Bluetooth write.
        XCTAssertThrowsError(try ledger.begin("new-request"))
        XCTAssertEqual(ledger.pendingRequestID,"old-request")
        XCTAssertEqual(ledger.acknowledge(),"old-request")
        XCTAssertNil(ledger.acknowledge())
        try ledger.begin("new-request")
        XCTAssertEqual(ledger.acknowledge(),"new-request")
    }
    func testOnlyConfirmedConnectionResetClearsUnresolvedWriter() throws {
        var ledger=PumpWriteLedger();try ledger.begin("unknown-request")
        XCTAssertNotNil(ledger.pendingRequestID)
        ledger.resetConnection()
        try ledger.begin("fresh-generation")
        XCTAssertEqual(ledger.acknowledge(),"fresh-generation")
    }
    func testPairCannotContainMissingRepeatedOrMalformedDevice() throws {
        for pair in [["A":ids["A"]!],["A":ids["A"]!,"B":ids["A"]!],["A":"unknown","B":ids["B"]!],ids.merging(["C":UUID().uuidString]){$1}] {
            XCTAssertThrowsError(try PumpGroupRequest(id:UUID().uuidString,devices:pair,strength:PumpStrength(mode:.standard,kg:2)))
        }
    }
    @MainActor func testBothDevicesReceiveExactlyTheSamePacketOnce() async throws {
        let engine=PumpGroupController(), req=try request();var sent=[String:Data]()
        let result=try await engine.run(req,pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{slot,value,_ in
            XCTAssertNil(sent[slot]);sent[slot]=value.packet;return .responseUnverified
        })
        XCTAssertEqual(sent,["A":req.strength.packet,"B":req.strength.packet])
        XCTAssertEqual(result.status,.bothResponseUnverified)
        XCTAssertFalse(result.physicalConfirmed);XCTAssertFalse(engine.requiresRecovery)
    }
    @MainActor func testGattAcknowledgementWithoutFFCanProceedButNeverClaimsPhysicalSuccess() async throws {
        let engine=PumpGroupController();var calls=[String]()
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{slot,_,_ in calls.append(slot);return .gattAckUnverified})
        XCTAssertEqual(calls,["A","B"]);XCTAssertEqual(result.status,.bothAcknowledgedUnverified)
        XCTAssertFalse(result.physicalConfirmed);XCTAssertFalse(engine.requiresRecovery)
    }
    @MainActor func testAnyInitialPreflightFailurePreventsBothWrites() async throws {
        for failed in ["A","B"] {
            let engine=PumpGroupController();var writes=0
            let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{slot,_ in
                if slot==failed {throw PumpError.rejected("not connected")}
            },record:{_,_ in},send:{_,_,_ in writes += 1;return .responseUnverified})
            XCTAssertEqual(writes,0);XCTAssertEqual(result.status,.notSent)
        }
    }
    @MainActor func testFirstUnknownOrRejectedNeverSendsSecond() async throws {
        for status in [PumpLegResult.unknown,.notSent] {
            let engine=PumpGroupController();var calls=[String]()
            let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{slot,_,_ in calls.append(slot);return status})
            XCTAssertEqual(calls,["A"]);XCTAssertEqual(result.devices["B"],.notSent)
            XCTAssertEqual(result.status,status == .unknown ? .unknown : .notSent)
            XCTAssertEqual(engine.requiresRecovery,status == .unknown)
        }
    }
    @MainActor func testOnlyFirstRespondsAndSecondFailureIsNotHidden() async throws {
        for second in [PumpLegResult.unknown,.notSent] {
            let engine=PumpGroupController();var calls=[String]()
            let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{slot,_,_ in calls.append(slot);return slot=="A" ? .responseUnverified : second})
            XCTAssertEqual(calls,["A","B"]);XCTAssertEqual(result.devices["A"],.responseUnverified)
            XCTAssertEqual(result.status,second == .unknown ? .unknown : .partial)
            XCTAssertTrue(engine.requiresRecovery)
        }
    }
    @MainActor func testExceptionIsUnknownAndNeverRetried() async throws {
        let engine=PumpGroupController();var calls=0
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{_,_,_ in calls += 1;throw PumpError.rejected("transport timeout")})
        XCTAssertEqual(calls,1);XCTAssertEqual(result.status,.unknown)
    }
    @MainActor func testBeforeSecondWritePreflightIsRepeated() async throws {
        let engine=PumpGroupController();var checks=0,calls=[String]()
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{slot,_ in
            checks += 1;if checks>2 && slot=="B" {throw PumpError.rejected("disconnected or changed identity")}
        },record:{_,_ in},send:{slot,_,_ in calls.append(slot);return .responseUnverified})
        XCTAssertEqual(calls,["A"]);XCTAssertEqual(result.status,.partial)
    }
    @MainActor func testJournalFailureBeforeFirstPreventsWriting() async throws {
        let engine=PumpGroupController();var writes=0
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in throw PumpError.rejected("disk full")},send:{_,_,_ in writes += 1;return .responseUnverified})
        XCTAssertEqual(writes,0);XCTAssertEqual(result.status,.persistenceFailed)
    }
    @MainActor func testJournalFailureAfterFirstPreservesFirstAndStopsSecond() async throws {
        let engine=PumpGroupController();var writes=[String]()
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{phase,_ in
            if phase=="group_result_A" {throw PumpError.rejected("disk full")}
        },send:{slot,_,_ in writes.append(slot);return .responseUnverified})
        XCTAssertEqual(writes,["A"]);XCTAssertEqual(result.devices["A"],.responseUnverified)
        XCTAssertEqual(result.devices["B"],.notSent);XCTAssertTrue(engine.requiresRecovery)
        XCTAssertEqual(result.status,.persistenceFailed)
    }
    @MainActor func testCancelDuringFirstNeverDispatchesSecond() async throws {
        let engine=PumpGroupController();var writes=[String]()
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{slot,_,_ in
            writes.append(slot);engine.cancel();return .unknown
        })
        XCTAssertEqual(writes,["A"]);XCTAssertEqual(result.status,.unknown)
    }
    @MainActor func testUnknownRequiresNewExplicitReviewAndSameIDCannotReplay() async throws {
        let engine=PumpGroupController(), req=try request()
        _=try await engine.run(req,pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{_,_,_ in .unknown})
        do { _=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{_,_,_ in XCTFail("blocked");return .notSent});XCTFail("must block") } catch {}
        engine.acknowledgeRecovery()
        do { _=try await engine.run(req,pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{_,_,_ in XCTFail("replay");return .notSent});XCTFail("must reject reused id") } catch {}
    }
    @MainActor func testMissingGroupConfirmationCannotSend() async throws {
        for pair in [(false,true),(true,false)] {
            do { _=try await PumpGroupController().run(request(),pairConfirmed:pair.0,stopConfirmed:pair.1,preflight:{_,_ in},record:{_,_ in},send:{_,_,_ in XCTFail("no confirmation");return .notSent});XCTFail("must reject") } catch {}
        }
    }
    @MainActor func testConcurrentSecondRequestIsRejectedWithoutWriting() async throws {
        let engine=PumpGroupController();var calls=[String]()
        _=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{slot,_,_ in
            calls.append(slot)
            if slot=="A" {
                do { _=try await engine.run(self.request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{_,_ in},send:{_,_,_ in XCTFail("concurrent");return .notSent});XCTFail("must reject") } catch {}
            }
            return .responseUnverified
        })
        XCTAssertEqual(calls,["A","B"])
    }
    func testPairRecoveryDoesNotInventUnknownOrThirdDevice() throws {
        func row(_ slot:String,_ id:String)->String { "{\"event\":\"notification\",\"slot\":\"\(slot)\",\"peripheral_id\":\"\(id)\"}\n" }
        let text=row("A",ids["A"]!)+row("B",ids["B"]!)
        XCTAssertEqual(PumpRememberedPair.decodeLog(Data(text.utf8)),ids)
        XCTAssertNil(PumpRememberedPair.decodeLog(Data(row("A",ids["A"]!).utf8)))
        XCTAssertNil(PumpRememberedPair.decodeLog(Data((text+row("B",UUID().uuidString)).utf8)))
        XCTAssertNil(PumpRememberedPair.decodeLog(Data((row("A",ids["A"]!)+row("B",ids["A"]!)).utf8)))
    }
    @MainActor func testFinalRecordFailurePreservesBothResponsesButRequiresReview() async throws {
        let engine=PumpGroupController()
        let result=try await engine.run(request(),pairConfirmed:true,stopConfirmed:true,preflight:{_,_ in},record:{phase,_ in
            if phase=="group_complete" {throw PumpError.rejected("disk full")}
        },send:{_,_,_ in .responseUnverified})
        XCTAssertEqual(result.devices,["A":.responseUnverified,"B":.responseUnverified])
        XCTAssertEqual(result.status,.persistenceFailed);XCTAssertTrue(engine.requiresRecovery)
    }
    func testGroupRevalidatesProModeMinimumEvenForLegacyStrength() throws {
        let legacy=try PumpStrength(mode:.eccentric,kg:2)
        XCTAssertThrowsError(try PumpGroupRequest(id:UUID().uuidString,devices:ids,strength:legacy))
    }
    func testPairPreferencesRememberOnlyIdentity() throws {
        let name="pump-pair-test-"+UUID().uuidString, defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        PumpPairPreferences.save(ids,defaults:defaults)
        XCTAssertEqual(try PumpPairPreferences.load(captureRoot:URL(fileURLWithPath:"/missing"),defaults:defaults),ids)
        XCTAssertEqual(Set(defaults.persistentDomain(forName:name)!.keys),["PumpKnownPair.v1"])
        PumpPairPreferences.save(["A":"bad"],defaults:defaults)
        XCTAssertEqual(try PumpPairPreferences.load(captureRoot:URL(fileURLWithPath:"/missing"),defaults:defaults),ids)
    }
    func testEmptyStartupLogRecoversLastPairWithoutSavingPermission() throws {
        let (root,defaults,name)=try fixture();defer{try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:name)}
        try log(root,"ipad-old",pair:ids,date:10)
        try log(root,"ipad-new",pair:[:],date:20)
        XCTAssertEqual(try PumpPairPreferences.load(captureRoot:root,defaults:defaults),ids)
        XCTAssertNil(defaults.persistentDomain(forName:name))
    }
    func testIncompleteLatestRealPairDoesNotFallBackToEarlierPair() throws {
        let (root,defaults,name)=try fixture();defer{try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:name)}
        try log(root,"ipad-old",pair:ids,date:10)
        try log(root,"ipad-new",pair:["A":UUID().uuidString],date:20)
        XCTAssertNil(try PumpPairPreferences.load(captureRoot:root,defaults:defaults))
    }
    func testSyntheticOnlyLogDoesNotRegisterDevices() throws {
        let (root,defaults,name)=try fixture();defer{try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:name)}
        try log(root,"ipad-synthetic",pair:ids,date:10,synthetic:true)
        XCTAssertNil(try PumpPairPreferences.load(captureRoot:root,defaults:defaults))
    }
    private func fixture() throws -> (URL,UserDefaults,String) {
        let name="pump-pair-test-"+UUID().uuidString
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return (root,UserDefaults(suiteName:name)!,name)
    }
    private func log(_ root:URL,_ name:String,pair:[String:String],date:TimeInterval,synthetic:Bool=false) throws {
        let folder=root.appendingPathComponent(name),file=folder.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var bytes=Data()
        for (slot,id) in pair { bytes.append(try JSONSerialization.data(withJSONObject:["event":"notification","slot":slot,"peripheral_id":id,"synthetic":synthetic]));bytes.append(10) }
        try bytes.write(to:file)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:date)],ofItemAtPath:file.path)
    }
}

