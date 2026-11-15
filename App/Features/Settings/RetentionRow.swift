import SwiftUI

/// One "Keep X" row: the retention period and the switch that enables keeping
/// that kind at all. The period is disabled while the switch is off.
struct RetentionRow: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var period: RetentionPeriod

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Picker("", selection: $period) {
                    ForEach(RetentionPeriod.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!isOn)
                .accessibilityLabel("\(title) for")
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(title)
            }
        }
    }
}
