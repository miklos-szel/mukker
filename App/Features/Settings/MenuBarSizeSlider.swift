import SwiftUI

/// The one "menu bar size" control. Shown in both the Calendar and Network
/// panes because it sizes the date glyph and the bandwidth badge together —
/// both bind the same `CalendarSettings` value, so they can't disagree.
struct MenuBarSizeSlider: View {
    @ObservedObject private var settings = CalendarSettings.shared

    var body: some View {
        LabeledContent("Menu bar size") {
            HStack(spacing: 8) {
                Slider(value: $settings.menuBarGlyphHeight,
                       in: CalendarSettings.glyphHeightRange, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .frame(width: 180)
                Text("\(Int(settings.menuBarGlyphHeight)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
