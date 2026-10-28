import FoxTrainingCore
import Foundation

enum TrainingEntry: Identifiable {
    enum Intent { case preparation, resume, review, unknown }
    case plan
    case prepare(TrainingActivity, ArmSide, UUID)
    case session(UUID, Intent, UUID, expectedAttemptID: UUID? = nil)
    var id: String {
        switch self {
        case .plan: return "plan"
        case .prepare(_, _, let request), .session(_, _, let request, _): return request.uuidString
        }
    }
    static func open(_ session: TrainingSession) -> Self {
        let intent: Intent = [.feedback, .summary].contains(session.stage) ? .review :
            session.executionStart == .notStarted ? .preparation : session.executionStart == .started ? .resume : .unknown
        return .session(session.id, intent, UUID())
    }
    static func selector(_ session: TrainingSession) -> String {
        let kind = [.feedback, .summary].contains(session.stage) ? "review" :
            session.executionStart == .notStarted ? "preparation" : session.executionStart == .started ? "resume" : "open"
        return "home-\(kind)-\(session.id)"
    }
}

extension TrainingStore {
    @discardableResult
    func enter(_ entry: TrainingEntry) -> Bool {
        switch entry {
        case .plan: return true
        case .prepare(let activity, let arm, let request): return preparePractice(activity, arm: arm, requestID: request)
        case .session(let id, let intent, let request, let expectedAttempt):
            guard let target = archive.sessions.first(where: { $0.id == id && !$0.isFinished }) else {
                errorMessage = "目标训练不可用。"; return false
            }
            guard expectedAttempt == nil || target.currentSetAttemptId == expectedAttempt else {
                errorMessage = "目标组已改变，请从记录查看原组。"; return false
            }
            let valid: Bool
            switch intent {
            case .preparation: valid = target.executionStart == .notStarted
            case .resume: valid = target.executionStart == .started && ![.feedback, .summary].contains(target.stage)
            case .review: valid = [.feedback, .summary].contains(target.stage)
            case .unknown: valid = target.executionStart == .unknown
            }
            guard valid else { errorMessage = "训练状态已改变，请返回首页重新选择。"; return false }
            return activateSession(id, requestID: request)
        }
    }
}
