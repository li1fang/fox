import Foundation

/// A read-only, prefix-causal observer. It has no tracker, repository, timer or audio dependency.
/// Losing a point silences phase coaching; it must not reset the independent motion counter.
public struct GuidancePolicy {
    public static let version = "guidance-policy-v1.2"
    private var context: GuidanceContext?
    private var lastTime: Double?
    private var lastCount = 0
    private var lastStage: GuidanceStage?
    private var lastCountdown: Int?
    private var candidatePhase: CurlPhase?
    private var stableSince: Double?
    private var phaseEpisode = 0
    private var lastSpokenPhase: String?
    private var cueSequence = 0
    private var unavailableSince: Double?
    private var reportedLoss = false
    private var lastRestRemaining: Double?
    public init() {}

    public mutating func update(_ input: GuidanceInput) -> GuidanceUpdate {
        guard input.time.isFinite, input.count >= 0 else { return .init(presentation: .unavailable, cues: []) }
        if context != input.context {
            self = GuidancePolicy(); context = input.context; lastCount = input.count
        }
        guard lastTime.map({ input.time > $0 }) ?? true else { return .init(presentation: .unavailable, cues: []) }
        if let lastTime, input.time - lastTime > 0.35 { stableSince = nil }
        lastTime = input.time
        let presentation = present(input)
        if input.mode == .observed && input.stage == .active {
            if input.motion?.isFresh(at: input.time) != true && unavailableSince == nil { unavailableSince = input.time }
            if input.motion?.isFresh(at: input.time) == true && !reportedLoss { unavailableSince = nil }
        } else { unavailableSince = nil; reportedLoss = false }
        let priorCount = lastCount
        // A decrease is not a new rep; rebind adapters retain the committed cumulative count.
        lastCount = max(lastCount, input.count)
        defer { lastStage = input.stage; lastCountdown = input.countdown; lastRestRemaining = input.restRemainingSeconds }
        guard input.mode != .off else { return .init(presentation: presentation, cues: []) }

        var kind: GuidanceCueKind?
        var text = ""
        var phaseToken: String?
        var requiresObservation: Bool?
        if input.stage == .active && input.count > priorCount {
            kind = .count; text = "\(input.count)"
            if let target = input.targetReps, target > 0 {
                if input.count == target { text += "，目标次数已完成" }
                else if input.count == target - 1 { text += "，还有最后一个" }
                else if input.count == target - 3 { text += "，还剩三个" }
            }
            if text == "\(input.count)" && input.count % 5 == 0 { text += "，加油" }
        } else if input.stage != lastStage || (input.stage == .countdown && input.countdown != lastCountdown) {
            kind = .lifecycle
            switch input.stage {
            case .ready: text = "开始前请确认本组重量"
            case .preparing: text = "准备好后，走回画面中"
            case .countdown:
                text = input.countdown.map(String.init) ?? "准备开始"
                phaseToken = presentation.phaseToken
            case .active: text = lastStage == .countdown || lastStage == .preparing ? "开始" : ""
            case .paused: text = "已暂停"
            case .feedback: text = "这组结束了，感觉怎么样"
            case .rest: text = input.remainingSets == 1 ? "还剩最后一组，休息一下再继续" : "休息一下，准备好后再继续"
            case .summary: text = "本次训练结束了，辛苦了"
            default: text = ""
            }
        }
        if text.isEmpty, input.stage == .rest, let previous = lastRestRemaining, previous > 0,
           input.restRemainingSeconds == 0 {
            kind = .lifecycle; text = "休息时间到了，要再休息一会儿吗"
        }
        if text.isEmpty, let since = unavailableSince, input.time - since >= 1.2, !reportedLoss,
           presentation.source == .unavailable {
            text = "暂时看不清"; kind = .lifecycle; reportedLoss = true; requiresObservation = false
        } else if text.isEmpty, presentation.source == .observed, reportedLoss {
            text = "重新看到了"; kind = .lifecycle; reportedLoss = false; requiresObservation = true
        }
        if presentation.source == .observed { unavailableSince = nil }
        if text.isEmpty, presentation.isMoving, let token = presentation.phaseToken, token != lastSpokenPhase {
            if input.mode == .observed && input.motion?.guidancePhase == .lowering {
                // The observed window can be under one second. Use a phase label, not a
                // sentence that finishes after the motion or claims a measured speed error.
                text = input.exercise == .latPulldown ? "返回" : "放回"
            } else if input.mode == .planned {
                text = presentation.label
            }
            if !text.isEmpty { kind = .phase; phaseToken = token; lastSpokenPhase = token }
        }
        guard let kind, !text.isEmpty else { return .init(presentation: presentation, cues: []) }
        cueSequence += 1
        let cue = GuidanceCue(id: "\(input.context.key)/\(cueSequence)", context: input.context, kind: kind, stage: input.stage,
            text: text, createdAt: input.time, expiresAt: input.time + (kind == .lifecycle ? 2 : 1), phaseToken: phaseToken,
            requiresObservation: requiresObservation)
        return .init(presentation: presentation, cues: [cue])
    }

    private mutating func present(_ input: GuidanceInput) -> GuidancePresentation {
        if input.stage == .countdown && input.mode != .off {
            stableSince = nil
            // A lifecycle stage alone cannot invalidate a previous countdown digit.
            // Bind speech to the currently displayed digit just like a motion phase.
            let digit = input.countdown.map(String.init) ?? "unknown"
            return .init(source: .unavailable, label: input.countdown.map(String.init) ?? "准备开始", scale: 0.8,
                         isMoving: false, phaseToken: "\(input.context.key)/countdown/\(digit)")
        }
        guard input.stage == .active, input.mode != .off else {
            stableSince = nil
            return .init(source: .unavailable, label: input.mode == .off ? "引导已关闭" : "待开始", scale: 0.8, isMoving: false)
        }
        if input.mode == .planned {
            stableSince = nil
            let sample = TempoTimeline.sample(input.tempo, elapsed: input.elapsed)
            guard sample.isValid else { return .unavailable }
            let label = input.exercise == .latPulldown ?
                (sample.phase == "lift" ? "下拉" : sample.phase == "lower" ? "返回" : sample.label) : sample.label
            return .init(source: .planned, label: label, scale: sample.scale, isMoving: true,
                phaseToken: "\(input.context.key)/plan/\(sample.cycle)/\(sample.phaseIndex)")
        }
        guard let motion = input.motion, motion.isFresh(at: input.time), motion.phase != .waitingForExtension else {
            stableSince = nil
            return .unavailable
        }
        let phase = motion.guidancePhase
        if candidatePhase != phase { candidatePhase = phase; phaseEpisode += 1; stableSince = nil }
        if stableSince == nil { stableSince = input.time }
        guard input.time - stableSince! >= 0.15 - 0.000001 else { return .unavailable }
        let label: String
        switch phase {
        case .lowered: label = input.exercise == .latPulldown ? "上方起点" : "放低"
        case .raising: label = input.exercise == .latPulldown ? "下拉" : "上举"
        case .top: label = "顶端停留"
        case .lowering: label = input.exercise == .latPulldown ? "返回" : "放回"
        case .waitingForExtension: label = "等待起点"
        }
        // Observed scale conveys the categorical phase, not an invented phase completion %.
        let scale: Double = phase == .top ? 1 : phase == .lowered ? 0.65 : 0.825
        return .init(source: .observed, label: label, scale: scale, isMoving: true,
            phaseToken: "\(input.context.key)/observed/\(phaseEpisode)/\(phase.rawValue)")
    }
}
