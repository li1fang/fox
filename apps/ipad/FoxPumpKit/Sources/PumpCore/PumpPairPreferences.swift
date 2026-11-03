import Foundation

/// Persist membership only, never settings, requests or sending permission.
public enum PumpPairPreferences {
    private static let key = "PumpKnownPair.v1"
    public static func save(_ pair: [String:String], defaults: UserDefaults = .standard) {
        if let valid=PumpRememberedPair.validated(pair) { defaults.set(valid,forKey:key) }
    }
    public static func load(captureRoot: URL, defaults: UserDefaults = .standard) throws -> [String:String]? {
        if let stored=defaults.dictionary(forKey:key) as? [String:String],let pair=PumpRememberedPair.validated(stored) { return pair }
        guard FileManager.default.fileExists(atPath:captureRoot.path) else { return nil }
        let folders=try FileManager.default.contentsOfDirectory(at:captureRoot,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        var logs=[(URL,Date)]()
        for folder in folders where folder.lastPathComponent.hasPrefix("ipad-") {
            let meta=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard meta.isDirectory == true,meta.isSymbolicLink != true else { continue }
            let file=folder.appendingPathComponent("events.jsonl")
            guard let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey]),values.isRegularFile == true,values.isSymbolicLink != true else { continue }
            logs.append((file,values.contentModificationDate ?? .distantPast))
        }
        for (url,_) in logs.sorted(by:{$0.1>$1.1}).prefix(8) {
            let file=try FileHandle(forReadingFrom:url);defer {try? file.close()}
            let end=try file.seekToEnd();try file.seek(toOffset:end>2_000_000 ? end-2_000_000 : 0)
            let bytes=try file.read(upToCount:2_000_000) ?? Data()
            let hasNotification=bytes.split(separator:10).contains { line in
                guard let row=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] else {return false}
                return row["event"] as? String == "notification" && row["synthetic"] as? Bool != true
            }
            // Skip an empty startup log, not an ambiguous latest real pair.
            if hasNotification { return PumpRememberedPair.decodeLog(bytes) }
        }
        return nil
    }
}
