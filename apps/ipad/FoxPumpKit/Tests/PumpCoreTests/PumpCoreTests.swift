import XCTest
@testable import PumpCore

final class PumpCoreTests: XCTestCase {
    func testReadOnlyPolicyRejectsArmingAndCommands() throws {
        for action in ["arm", "command"] {
            XCTAssertThrowsError(try PumpAccessPolicy.readOnly.validate(action: action))
            XCTAssertNoThrow(try PumpAccessPolicy.control.validate(action: action))
        }
    }
    func testReadOnlyPolicyCannotBeEnabledAndKeepsReadActions() throws {
        for requested in [false, true] {
            for foreground in [false, true] {
                XCTAssertFalse(PumpAccessPolicy.readOnly.controlEnabled(requested, foreground: foreground))
                XCTAssertEqual(PumpAccessPolicy.control.controlEnabled(requested, foreground: foreground), requested && foreground)
            }
        }
        for action in ["scan", "connect", "disconnect", "disarm", "observe", "mark", "export", "resume"] {
            XCTAssertNoThrow(try PumpAccessPolicy.readOnly.validate(action: action))
        }
    }
    private func vectors() throws -> [String:Any] {
        let url = Bundle.module.url(forResource:"Vectors",withExtension:"json")!
        return try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    }
    private func data(_ hex: String) -> Data {
        Data(stride(from:0,to:hex.count,by:2).map { i in
            let start = hex.index(hex.startIndex,offsetBy:i)
            return UInt8(hex[start..<hex.index(start,offsetBy:2)],radix:16)!
        })
    }
    func testPythonStrengthParity() throws {
        for v in try vectors()["strength"] as! [[String:Any]] {
            let value = try PumpStrength(mode:PumpMode(rawValue:v["mode"] as! String)!,kg:v["kg"] as! Double,
                reduction:v["reduction"] as! Int,standardLimit:v["limit"] as! Int)
            XCTAssertEqual(value.packet.pumpHex,v["hex"] as? String)
        }
    }
    func testPythonNotificationParity() throws {
        for v in try vectors()["notifications"] as! [[String:Any]] {
            let bytes = data(v["hex"] as! String), frame = try PumpFrame(bytes)
            let expected = v["expected"] as! [String:Any]
            XCTAssertTrue(frame.profileValid)
            for (key,value) in frame.fields { XCTAssertEqual(String(describing:value),String(describing:expected[key]!)) }
            var damaged = bytes; damaged[damaged.count-1] ^= 1
            XCTAssertFalse(try PumpFrame(damaged).profileValid)
        }
        XCTAssertThrowsError(try PumpFrame(Data([0x53,11,2])))
    }
    func testBoundaries() throws {
        for mode in PumpMode.allCases {
            for kg in [-1.0,1.9,2.000000000001,5.01,8.1,Double.nan,Double.infinity] {
                XCTAssertThrowsError(try PumpStrength(mode:mode,kg:kg))
            }
            if mode != .standard { XCTAssertThrowsError(try PumpStrength(mode:mode,kg:8,standardLimit:8)) }
        }
        XCTAssertThrowsError(try PumpStrength(mode:.standard,kg:8))
        XCTAssertThrowsError(try PumpStrength(mode:.standard,kg:5,reduction:25))
        XCTAssertThrowsError(try PumpStrength(mode:.concentric,kg:5,reduction:51))
    }
    func testOneShotFreshnessAndGap() throws {
        var gate = PumpGate()
        XCTAssertThrowsError(try gate.arm(now:1))
        gate.receive(heartbeat:true,working:true,now:1); gate.receive(heartbeat:false,now:1)
        try gate.arm(now:1); try gate.consume(now:2)
        XCTAssertThrowsError(try gate.consume(now:2))
        try gate.arm(now:2)
        gate.receive(heartbeat:true,working:true,now:5) // gap revokes old permission
        gate.receive(heartbeat:false,now:5)
        XCTAssertThrowsError(try gate.consume(now:5))
        try gate.arm(now:5); gate.receive(heartbeat:true,working:false,now:6)
        XCTAssertThrowsError(try gate.consume(now:6))
    }
}
