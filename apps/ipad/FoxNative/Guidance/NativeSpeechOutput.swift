import AVFoundation
import FoxTrainingCore

/// Installed system voices only; no server, microphone or shared recording session.
/// System-managed speech sessions handle brief ducking instead of keeping music ducked all set.
@MainActor
final class NativeSpeechOutput: NSObject, SpeechOutputDriver, AVSpeechSynthesizerDelegate {
    var evidenceKind: String { "system_speech_callback_not_audibility" }
    var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var active: (utterance: AVSpeechUtterance, id: String)?

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    func speak(_ cue: GuidanceCue) -> Bool {
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else { return false }
        stop()
        let utterance = AVSpeechUtterance(string: cue.text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0; utterance.postUtteranceDelay = 0
        active = (utterance, cue.id)
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        active = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        deliver(.started, utteranceID: ObjectIdentifier(utterance))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deliver(.finished, utteranceID: ObjectIdentifier(utterance))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        deliver(.cancelled, utteranceID: ObjectIdentifier(utterance))
    }
    private nonisolated func deliver(_ event: SpeechPlaybackEvent, utteranceID: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, let active = self.active, ObjectIdentifier(active.utterance) == utteranceID else { return }
            switch event { case .finished, .cancelled, .failed: self.active = nil; default: break }
            self.onEvent?(active.id, event)
        }
    }
}

#if DEBUG
@MainActor
final class LayoutTestSpeechOutput: SpeechOutputDriver {
    var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
    func speak(_ cue: GuidanceCue) -> Bool {
        onEvent?(cue.id, .started); onEvent?(cue.id, .finished); return true
    }
    func stop() {}
}
#endif
