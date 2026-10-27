import FoxTrainingCore
import SwiftUI

// A view may survive feedback/rest transitions. Never carry a UI override into another set.
struct TrainingArmChoice {
    let attemptID: UUID?
    let arm: ArmSide

    static func current(_ choice: Self?, session: TrainingSession) -> ArmSide {
        if let evidence = session.currentVisualEvidence { return evidence.settings.arm }
        if let choice, choice.attemptID == session.currentSetAttemptId { return choice.arm }
        return session.exercise.visualObservation?.arm ?? .left
    }
}

struct TrainingPlanOutline: View {
    let plan: TrainingPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("热身", systemImage: "figure.walk").font(.headline)
            Text(plan.warmup).foregroundStyle(.secondary)
            ForEach(Array(plan.exercises.enumerated()), id: \.element.id) { index, exercise in
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1)).font(.headline).foregroundStyle(.secondary)
                        Text(exercise.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(exercise.targetSets.count) 组 · \(targetSummary(exercise))").font(.body.weight(.medium))
                    Label(exercise.visualObservation == nil ? "手工记录" : "相机辅助 · 试用",
                          systemImage: exercise.visualObservation == nil ? "hand.tap" : "viewfinder")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("每组安排") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(exercise.targetSets.indices, id: \.self) { i in
                                let target = exercise.targetSets[i]
                                Text("第 \(target.setIndex) 组 · \(Self.targetText(target, basis: exercise.repetitionBasis)) · \(weightText(target.targetWeight, unit: target.weightUnit)) · 休息 \(Int(target.restSeconds)) 秒")
                                    .font(.subheadline).monospacedDigit()
                            }
                            if let notes = exercise.notes, !notes.isEmpty { Text(notes).font(.callout).foregroundStyle(.secondary) }
                        }.padding(.top, 8)
                    }
                }
            }
            Divider()
            Text(plan.safetyNotes).font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("结束放松") { Text(plan.cooldown).foregroundStyle(.secondary).padding(.top, 8) }
        }
    }

    private func targetSummary(_ exercise: Exercise) -> String {
        guard let first = exercise.targetSets.first else { return "未设定" }
        let uniform = exercise.targetSets.allSatisfy {
            $0.targetReps == first.targetReps && $0.targetDurationSeconds == first.targetDurationSeconds &&
            $0.targetWeight == first.targetWeight && $0.weightUnit == first.weightUnit
        }
        guard uniform else { return "逐组目标不同" }
        let count = Self.targetText(first, basis: exercise.repetitionBasis)
        return "\(count) · \(weightText(first.targetWeight, unit: first.weightUnit))"
    }

    static func targetText(_ target: SetTarget, basis: RepetitionBasis?) -> String {
        target.targetReps.map { "\($0) 次\(basis == .perSide ? " / 侧" : "")" }
            ?? durationText(target.targetDurationSeconds ?? 0)
    }
}

// A blank is unknown, not zero or the planned target. Only an explicit step creates a value.
enum TrainingCountInput {
    static func valid(_ text: String) -> Bool { Int(text).map { (0...1000).contains($0) } == true }
    static func adjusted(_ text: String, by delta: Int) -> String? {
        guard delta == 1 || delta == -1 else { return nil }
        if text.isEmpty { return delta == 1 ? "1" : nil }
        guard valid(text), let value = Int(text), (0...1000).contains(value + delta) else { return nil }
        return String(value + delta)
    }
    static func canConfirm(_ values: [String]) -> Bool {
        values.contains(where: valid) && values.allSatisfy { $0.isEmpty || valid($0) }
    }
}

struct TrainingCountField: View {
    @Binding var text: String
    let identifier: String
    let label: String
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize = 32
    @ScaledMetric(relativeTo: .largeTitle) private var fieldWidth = 160
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("次数", text: $text).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .font(.system(size: valueSize, weight: .semibold)).accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
            HStack(spacing: 12) {
                step(-1, icon: "minus"); step(1, icon: "plus")
            }
        }.frame(maxWidth: fieldWidth)
    }
    private func step(_ delta: Int, icon: String) -> some View {
        Button { if let value = TrainingCountInput.adjusted(text, by: delta) { text = value } } label: {
            Image(systemName: icon).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered)
            .disabled(TrainingCountInput.adjusted(text, by: delta) == nil)
            .accessibilityLabel("\(delta > 0 ? "增加" : "减少")\(label)")
            .accessibilityIdentifier("\(identifier)-\(delta > 0 ? "plus" : "minus")")
    }
}
