import SwiftUI

/// One "Keep X" box with an enable toggle and a retention-period picker.
struct RetentionBox: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var period: RetentionPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
            Picker("", selection: $period) {
                ForEach(RetentionPeriod.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .labelsHidden()
            .disabled(!isOn)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
