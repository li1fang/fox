import FoxTrainingCore
import SwiftUI

struct RecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    let record: LocalSetRecord
    let save: (Int?, Double?, String, SideRepetitions?) -> Bool
    @State private var reps = ""
    @State private var leftReps = ""
    @State private var rightReps = ""
    @State private var weight: Double?
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(record.exerciseName) {
                    if record.target.targetReps != nil {
                        if record.repetitionBasis == .perSide {
                            if record.targetSide != .right { TextField("左臂实际次数", text: $leftReps).keyboardType(.numberPad).accessibilityIdentifier("summary-left-reps") }
                            if record.targetSide != .left { TextField("右臂实际次数", text: $rightReps).keyboardType(.numberPad).accessibilityIdentifier("summary-right-reps") }
                        } else {
                        TextField("实际次数", text: $reps).keyboardType(.numberPad).accessibilityIdentifier("summary-reps")
                        }
                    }
                    WeightControl(weight: $weight, unit: record.target.weightUnit)
                    LabeledContent("实际用时", value: durationText(record.durationSeconds))
                    TextField("备注", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle("修改本组记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let sides = record.repetitionBasis == .perSide ? SideRepetitions(left: Int(leftReps), right: Int(rightReps)) : nil
                        if save(record.repetitionBasis == .perSide ? nil : Int(reps), weight, notes, sides) { dismiss() }
                    }
                        .disabled(record.target.targetReps != nil && (record.repetitionBasis == .perSide
                            ? Int(leftReps) == nil && Int(rightReps) == nil : Int(reps) == nil))
                }
            }
            .onAppear {
                reps = record.reps.map(String.init) ?? ""; weight = record.weight; notes = record.notes
                leftReps = record.sideRepetitions?.left.map(String.init) ?? ""
                rightReps = record.sideRepetitions?.right.map(String.init) ?? ""
            }
        }
    }
}
