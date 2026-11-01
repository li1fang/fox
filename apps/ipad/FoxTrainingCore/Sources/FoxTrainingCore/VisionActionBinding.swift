import Foundation

/// One resource is consumed by the App, portable replay and vision:batch.
/// A binding describes implemented code; it does not enable a user capability.
public struct VisionActionBinding: Codable, Equatable {
    public struct Implementation: Codable, Equatable { public let path: String; public let sha256: String }
    public let action: String
    public let label: String
    public let strategyID: String
    public let strategyVersion: Int
    public let algorithm: String
    public let consumerMode: String
    public let bodyView: String
    public let phaseStatus: String
    public let eventTimeMeaning: String
    public let implementation: [Implementation]
    public let jointConfidenceFloor: Double?
    public let developmentOnly: Bool?
    var squatJointConfidenceFloor: SquatJointConfidenceFloor? { SquatJointConfidenceFloor(rawValue:jointConfidenceFloor ?? 0.5) }

    public static func load(_ action: String, strategyID: String? = nil) throws -> Self {
        let registry=try VisionActionRegistry.load()
        let entries = strategyID == nil ? registry.actions : registry.actions+(registry.variants ?? [])
        guard let value=entries.first(where:{$0.action==action && (strategyID == nil || $0.strategyID==strategyID)}) else {throw TrainingError.invalidRecord}
        return value
    }
    func validate() throws {
        guard strategyVersion==1, bodyView=="side", !implementation.isEmpty,
              implementation.allSatisfy({!$0.path.contains("..") && $0.sha256.count==64}),
              eventTimeMeaning=="count_confirmation_not_anatomical_return_endpoint" else {throw TrainingError.invalidRecord}
        switch action {
        case "squat":
            guard consumerMode=="countOnly",phaseStatus=="not_provided",let floor=SquatJointConfidenceFloor(rawValue:jointConfidenceFloor ?? 0.5) else {throw TrainingError.invalidRecord}
            if strategyID=="squat-side-selected-b587-v1" {
                guard algorithm==CountOnlyAction.squat.algorithm,floor == .baseline,developmentOnly != true else {throw TrainingError.invalidRecord}
            } else {
                guard floor != .baseline,developmentOnly==true,algorithm=="squat-selected-count-only-h1-joint-floor-v1",
                    strategyID=="squat-side-joint-floor-\(Int(floor.rawValue*100))-h1-v1" else {throw TrainingError.invalidRecord}
            }
        case "curl":
            let original=try MotionStrategy.load(.curl)
            guard algorithm==original.algorithm, strategyID==original.id, consumerMode=="controller",
                  phaseStatus=="existing_observed_fields_only" else {throw TrainingError.invalidRecord}
        default: throw TrainingError.invalidRecord
        }
    }
}
public struct VisionActionRegistry: Codable {
    public let schema: String
    public let version: Int
    public let formalOffsetSeconds: Double
    public let actions: [VisionActionBinding]
    public let variants: [VisionActionBinding]?
    public static func load() throws -> Self {
        guard let url=Bundle.module.url(forResource:"vision-actions",withExtension:"json") else {throw TrainingError.invalidRecord}
        let value=try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.schema=="fox.vision_actions.v1", value.version==1, value.formalOffsetSeconds==2,
              Set(value.actions.map(\.action)).count==value.actions.count else {throw TrainingError.invalidRecord}
        try value.actions.forEach {try $0.validate()}
        let all=value.actions+(value.variants ?? [])
        guard Set(all.map(\.strategyID)).count==all.count,(value.variants ?? []).allSatisfy({$0.action=="squat" && $0.developmentOnly==true}) else {throw TrainingError.invalidRecord}
        try value.variants?.forEach {try $0.validate()}
        return value
    }
}
public struct VisionWorkflowBinding: Codable, Equatable {
    public let schema: String
    public let registryVersion: Int
    public let action: String
    public let label: String
    public let strategyID: String
    public let strategyVersion: Int
    public let algorithm: String
    public let consumerMode: String
    public let bodyView: String
    public let phaseStatus: String
    public let eventTimeMeaning: String
    public let implementation: [VisionActionBinding.Implementation]
    public let formalOffsetSeconds: Double
    public let acceptance: String
    public let jointConfidenceFloor: Double?
    public let developmentOnly: Bool?
    public static func load(_ action:String,strategyID:String? = nil) throws -> Self {
        let r=try VisionActionRegistry.load(),a=try VisionActionBinding.load(action,strategyID:strategyID)
        return .init(schema:"fox.vision_workflow_binding.v1",registryVersion:r.version,action:a.action,label:a.label,
            strategyID:a.strategyID,strategyVersion:a.strategyVersion,algorithm:a.algorithm,consumerMode:a.consumerMode,
            bodyView:a.bodyView,phaseStatus:a.phaseStatus,eventTimeMeaning:a.eventTimeMeaning,implementation:a.implementation,
            formalOffsetSeconds:r.formalOffsetSeconds,acceptance:"not_assessed",jointConfidenceFloor:a.jointConfidenceFloor,developmentOnly:a.developmentOnly)
    }
    public func validate(allowDevelopmentVariants: Bool = false) throws {
        let registry=try VisionActionRegistry.load(), expected=try VisionActionBinding.load(action,strategyID:strategyID)
        guard schema=="fox.vision_workflow_binding.v1",registryVersion==registry.version,
              (developmentOnly != true || allowDevelopmentVariants),jointConfidenceFloor==expected.jointConfidenceFloor,developmentOnly==expected.developmentOnly,
              formalOffsetSeconds==registry.formalOffsetSeconds,acceptance=="not_assessed",
              strategyID==expected.strategyID,strategyVersion==expected.strategyVersion,algorithm==expected.algorithm,
              consumerMode==expected.consumerMode,bodyView==expected.bodyView,phaseStatus==expected.phaseStatus,
              eventTimeMeaning==expected.eventTimeMeaning,implementation==expected.implementation,label==expected.label
        else {throw TrainingError.invalidRecord}
    }
}

public enum VisionWorkflowDigest { public static func sha256(_ data:Data)->String {TrainingArchiveDigest.sha256(data)} }
public enum VisionWorkflowCache {
    public struct ClockAsset: Codable {
        public let path:String
        public let timebase:String
        public let role:String
    }
    public static func validateClock(_ data:Data,frames:[PoseFrame]) throws {
        struct Row:Decodable {let value:String;let timescale:Int;let epoch:String}
        guard data.count<=64*1024*1024,let text=String(data:data,encoding:.utf8) else {throw TrainingError.invalidRecord}
        let lines=text.split(whereSeparator:\.isNewline)
        guard !lines.isEmpty,lines.count<=100000,lines.count==frames.count else {throw TrainingError.invalidRecord}
        let rows=try lines.map{try JSONDecoder().decode(Row.self,from:Data($0.utf8))}
        var clock:[Double]=[]
        for row in rows {
            guard let value=Int64(row.value),value>=0,value<=9_007_199_254_740_991,row.timescale>0,row.timescale<=2_147_483_647,
                  Int64(row.epoch) != nil,row.epoch==rows[0].epoch else {throw TrainingError.invalidRecord}
            let seconds=Double(value)/Double(row.timescale)
            guard clock.last.map({seconds>$0}) ?? true else {throw TrainingError.invalidRecord}
            clock.append(seconds)
        }
        guard zip(frames,clock).allSatisfy({abs($0.timestamp-$1)<=1e-9}) else {throw TrainingError.invalidRecord}
    }
    public static func validateHeader(_ header:[String:String]) throws {
        guard ["fox.count_only_pose_input.v1","fox.pose_workflow_input.v1"].contains(header["schema"] ?? ""),
              header["visionRevision"]=="1",header["timebase"]=="source_pts_seconds",
              header["coordinateConvention"]=="vision-normalized-bottom-left-pixel-up-v1",
              ["unknown","known_unmirrored","known_mirrored"].contains(header["pixelMirror"] ?? ""),
              (header["inputClass"]=="public" && header["source"]=="apple_vision_2d" || header["inputClass"]=="public_synthetic" && header["source"]=="synthetic_fixture"),
              let hash=header["sourceSHA256"],hash.count==64,hash.allSatisfy({$0.isHexDigit && !$0.isUppercase})
        else {throw TrainingError.invalidRecord}
    }
}
