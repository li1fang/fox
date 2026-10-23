import FoxTrainingCore
import SwiftUI

struct PlanEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var plan: TrainingPlan
    let save: (TrainingPlan) -> Bool
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("计划") {
                    TextField("名称", text: $plan.focus)
                    TextField("预定日期", text: Binding(get: { plan.scheduledDate ?? "" }, set: {
                        plan.scheduledDate = $0.isEmpty ? nil : $0
                        plan.scheduledTimeZone = $0.isEmpty ? nil : (plan.scheduledTimeZone ?? "Asia/Bangkok")
                    })).accessibilityIdentifier("plan-scheduled-date")
                    if plan.scheduledDate != nil {
                        TextField("时区", text: Binding(get: { plan.scheduledTimeZone ?? "Asia/Bangkok" }, set: { plan.scheduledTimeZone = $0 }))
                    }
                    TextField("热身", text: $plan.warmup, axis: .vertical)
                    TextField("结束放松", text: $plan.cooldown, axis: .vertical)
                }
                ForEach(plan.exercises.indices, id: \.self) { exerciseIndex in
                    Section {
                        TextField("动作名称", text: $plan.exercises[exerciseIndex].name)
                        observationEditor(exercise: exerciseIndex)
                        ForEach(plan.exercises[exerciseIndex].tempo.indices, id: \.self) { phaseIndex in
                            let phase = plan.exercises[exerciseIndex].tempo[phaseIndex].phase
                            Stepper("\(phase == "lift" ? "抬起" : phase == "peak" ? "顶部" : phase == "lower" ? "下放" : phase) \(plan.exercises[exerciseIndex].tempo[phaseIndex].seconds.formatted()) 秒",
                                value: $plan.exercises[exerciseIndex].tempo[phaseIndex].seconds, in: 0.5...30, step: 0.5)
                        }
                        ForEach(plan.exercises[exerciseIndex].targetSets.indices, id: \.self) { setIndex in
                            DisclosureGroup("第 \(setIndex + 1) 组") {
                                targetEditor(exercise: exerciseIndex, set: setIndex)
                            }
                        }
                        Button { addSet(to: exerciseIndex) } label: { Label("增加一组", systemImage: "plus") }
                        if plan.exercises[exerciseIndex].targetSets.count > 1 {
                            Button(role: .destructive) { plan.exercises[exerciseIndex].targetSets.removeLast() } label: { Label("移除最后一组", systemImage: "minus") }
                        }
                        Button(role: .destructive) { plan.exercises.remove(at: exerciseIndex) } label: { Label("移除动作", systemImage: "trash") }
                    } header: { Text("动作 \(exerciseIndex + 1)") }
                }
                Section {
                    Button {
                        plan.exercises.append(Exercise(name: "新动作", sets: [SetTarget(setIndex: 1)]))
                    } label: { Label("增加动作", systemImage: "plus") }
                }
            }
            .navigationTitle("编辑计划")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try plan.validate()
                            if save(plan) { dismiss() }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("计划未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func observationEditor(exercise index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("次数口径", selection: Binding(get: { plan.exercises[index].repetitionBasis ?? .total }, set: { plan.exercises[index].repetitionBasis = $0 })) {
                Text("总次数").tag(RepetitionBasis.total); Text("每侧次数").tag(RepetitionBasis.perSide)
            }.disabled(plan.exercises[index].visualObservation != nil)
            Picker("观察动作", selection: Binding(get: { plan.exercises[index].visualObservation?.exercise }, set: { value in
                if let value {
                    plan.exercises[index].visualObservation = WorkoutObservationSettings(exercise: value,
                        arm: value == .curl ? .left : .right, bodyView: value.recommendedBodyView)
                    plan.exercises[index].repetitionBasis = value == .latPulldown ? .total : .perSide
                } else { plan.exercises[index].visualObservation = nil }
            })) {
                Text("人工记录").tag(Optional<VisionExercise>.none)
                Text("侧身弯举").tag(Optional(VisionExercise.curl))
                Text("正面侧平举").tag(Optional(VisionExercise.lateralRaise))
                Text("背面高位下拉 · 实验").tag(Optional(VisionExercise.latPulldown))
            }.disabled(plan.exercises[index].targetSets.contains { $0.targetDurationSeconds != nil })
            if plan.exercises[index].visualObservation != nil {
                Picker("观察侧", selection: Binding(get: { plan.exercises[index].visualObservation?.arm ?? .left }, set: { plan.exercises[index].visualObservation?.arm = $0 })) {
                    Text("左臂").tag(ArmSide.left); Text("右臂").tag(ArmSide.right)
                }.pickerStyle(.segmented)
            }
        }
    }

    private func targetEditor(exercise: Int, set: Int) -> some View {
        let target = Binding(get: { plan.exercises[exercise].targetSets[set] }, set: { plan.exercises[exercise].targetSets[set] = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            Picker("目标", selection: Binding(get: { target.wrappedValue.targetDurationSeconds != nil }, set: { timed in
                var value = target.wrappedValue
                value.targetReps = timed ? nil : 10
                value.targetDurationSeconds = timed ? 30 : nil
                if timed { plan.exercises[exercise].visualObservation = nil }
                target.wrappedValue = value
            })) { Text("次数").tag(false); Text("时长").tag(true) }.pickerStyle(.segmented)
            if target.wrappedValue.targetReps != nil {
                Stepper("\(target.wrappedValue.targetReps ?? 10) 次", value: Binding(get: { target.wrappedValue.targetReps ?? 10 }, set: { target.wrappedValue.targetReps = $0 }), in: 1...100)
            } else {
                Stepper("\(Int(target.wrappedValue.targetDurationSeconds ?? 30)) 秒", value: Binding(get: { target.wrappedValue.targetDurationSeconds ?? 30 }, set: { target.wrappedValue.targetDurationSeconds = $0 }), in: 5...3600, step: 5)
            }
            Picker("重量单位", selection: Binding(get: { target.wrappedValue.weightUnit ?? "kg" }, set: { unit in
                target.wrappedValue.weightUnit = unit
                target.wrappedValue.targetWeight = nil
            })) {
                Text("kg").tag("kg"); Text("lb").tag("lb"); Text("档位").tag("machine_level"); Text("自重").tag("bodyweight")
            }
            WeightControl(weight: Binding(get: { target.wrappedValue.targetWeight }, set: { target.wrappedValue.targetWeight = $0 }), unit: target.wrappedValue.weightUnit)
            Stepper("休息 \(Int(target.wrappedValue.restSeconds)) 秒", value: Binding(get: { target.wrappedValue.restSeconds }, set: { target.wrappedValue.restSeconds = $0 }), in: 0...600, step: 15)
        }.padding(.vertical, 8)
    }

    private func addSet(to index: Int) {
        var target = plan.exercises[index].targetSets.last ?? SetTarget(setIndex: 1)
        target.setIndex = plan.exercises[index].targetSets.count + 1
        plan.exercises[index].targetSets.append(target)
    }
}
