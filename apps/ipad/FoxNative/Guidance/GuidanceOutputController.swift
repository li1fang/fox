import Foundation
import FoxTrainingCore
import Combine

enum SpeechPlaybackEvent: Sendable { case started, finished, cancelled, failed(String) }

@MainActor
protocol SpeechOutputDriver: AnyObject {
    var evidenceKind: String { get }
    var onEvent: ((String, SpeechPlaybackEvent) -> Void)? { get set }
    func speak(_ cue: GuidanceCue) -> Bool
    func stop()
}

extension SpeechOutputDriver { var evidenceKind: String { "test_double_not_audio" } }

struct GuidanceDeliveryEvent: Codable {
    var schema = "fox.guidance_delivery.v1"
    var policyVersion: String? = nil
    var cueID: String
    var context: GuidanceContext
    var time: Double
    var state: String
    var outputKind: String
    var reason: String?
    var cue: GuidanceCue?
}

/// Owns effects only. Both visual entry points feed this same adapter; it never calls a
/// counting, training-transition or repository method. Audio success is not training success.
@MainActor
final class GuidanceOutputController: ObservableObject {
    @Published private(set) var presentation = GuidancePresentation.unavailable
    @Published private(set) var speechEnabled = true
    @Published var overlayEnabled = true
    @Published private(set) var error: String?
    private(set) var events: [GuidanceDeliveryEvent] = []
    private(set) var droppedEvents = 0
    var onEvent: ((GuidanceDeliveryEvent) -> Void)?
    private let driver: SpeechOutputDriver
    private let now: () -> Double
    private var policy = GuidancePolicy()
    private var queue = GuidanceQueue()
    private var input: GuidanceInput?
    private var speaking: GuidanceCue?
    private var started = false
    private var speechSuspended = false

    init(driver: SpeechOutputDriver? = nil, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver ?? NativeSpeechOutput()
        self.now = now
        self.driver.onEvent = { [weak self] id, event in self?.received(id, event) }
    }

    func update(_ next: GuidanceInput) {
        if input?.context != next.context {
            cancel(reason: "context_changed"); queue = GuidanceQueue()
        }
        input = next
        let result = policy.update(next)
        presentation = result.presentation
        for cue in result.cues {
            record(cue, "candidate", includeCue: true)
            if speechEnabled && !speechSuspended {
                for evicted in queue.enqueue(cue) { record(evicted, "cancelled", reason: "queue_capacity") }
            } else { record(cue, "suppressed", reason: speechSuspended ? "system_interruption" : "muted") }
        }
        if next.mode == .off { cancel(reason: "guidance_off") }
        tick()
    }

    func setSpeechEnabled(_ enabled: Bool) {
        speechEnabled = enabled
        if !enabled { cancel(reason: "muted") }
    }

    func suspendSpeech(_ suspended: Bool) {
        speechSuspended = suspended
        if suspended { cancel(reason: "system_interruption") }
    }

    func interrupt(reason: String) {
        cancel(reason: reason)
        input = nil; presentation = .unavailable
    }

    func tick() {
        guard let input else { return }
        let time = now()
        let observationAvailable = input.motion?.isFresh(at: time) == true
        if input.mode == .observed && input.stage == .active && !observationAvailable {
            presentation = .unavailable
        }
        let token = presentation.phaseToken
        for expired in queue.discardInvalid(at: time, context: input.context, stage: input.stage, phaseToken: token, observationAvailable: observationAvailable) {
            record(expired, "cancelled", reason: "expired_or_context_changed")
        }
        if let speaking {
            if !speaking.isCurrent(context: input.context, stage: input.stage, phaseToken: token, observationAvailable: observationAvailable) {
                stopSpeaking(reason: "context_or_phase_changed")
            } else if !started && time > speaking.expiresAt {
                stopSpeaking(reason: "start_timeout")
            } else if let next = queue.pending.first, next.priority > speaking.priority {
                stopSpeaking(reason: "higher_priority")
            }
        }
        guard speechEnabled, !speechSuspended, input.mode != .off, speaking == nil else { return }
        guard let cue = queue.takeNext(at: time, context: input.context, stage: input.stage, phaseToken: token, observationAvailable: observationAvailable) else { return }
        speaking = cue; started = false
        record(cue, "submitted")
        if !driver.speak(cue) {
            record(cue, "failed", reason: "voice_unavailable")
            error = "语音暂不可用，画面与记录不受影响。"
            speaking = nil
        }
    }

    private func received(_ id: String, _ event: SpeechPlaybackEvent) {
        guard let cue = speaking, cue.id == id else { return }
        switch event {
        case .started:
            record(cue, "started")
            guard let input, cue.isValid(at: now(), context: input.context, stage: input.stage, phaseToken: presentation.phaseToken,
                observationAvailable: input.motion?.isFresh(at: now()) == true) else {
                stopSpeaking(reason: "late_start"); return
            }
            started = true; error = nil
        case .finished:
            record(cue, "finished"); speaking = nil; started = false; tick()
        case .cancelled:
            record(cue, "cancelled", reason: "system_cancelled"); speaking = nil; started = false
        case .failed(let reason):
            record(cue, "failed", reason: reason); speaking = nil; started = false
            error = "语音暂不可用，画面与记录不受影响。"
        }
    }

    private func cancel(reason: String) {
        for cue in queue.cancelAll() { record(cue, "cancelled", reason: reason) }
        stopSpeaking(reason: reason)
    }

    private func stopSpeaking(reason: String) {
        guard let cue = speaking else { return }
        speaking = nil; started = false
        record(cue, "cancelled", reason: reason)
        driver.stop()
    }

    private func record(_ cue: GuidanceCue, _ state: String, reason: String? = nil, includeCue: Bool = false) {
        let event = GuidanceDeliveryEvent(policyVersion: GuidancePolicy.version, cueID: cue.id, context: cue.context, time: now(), state: state,
            outputKind: driver.evidenceKind, reason: reason, cue: includeCue ? cue : nil)
        if events.count < 4096 { events.append(event) } else { droppedEvents += 1 }
        onEvent?(event)
    }
}
