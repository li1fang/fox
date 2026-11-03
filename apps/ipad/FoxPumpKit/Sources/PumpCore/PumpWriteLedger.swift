import Foundation

/// A timed-out continuation is not a completed CoreBluetooth write. Keep the
/// request until its callback drains or a disconnect is actually confirmed.
public struct PumpWriteLedger {
    public private(set) var pendingRequestID: String?
    public init() {}
    public mutating func begin(_ id: String) throws {
        guard pendingRequestID == nil else { throw PumpError.rejected("上一条蓝牙写入回调未结束，等待或重连受影响设备") }
        pendingRequestID=id
    }
    public mutating func acknowledge() -> String? {
        let id=pendingRequestID;pendingRequestID=nil;return id
    }
    public mutating func resetConnection() { pendingRequestID=nil }
}

