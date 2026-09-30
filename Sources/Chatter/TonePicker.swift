import SwiftUI
import ChatterCore

struct TonePicker: View {
    @Binding var selection: SpeechTone
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Tone", selection: $selection) {
                ForEach(SpeechTone.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(SpeechTone.allCases.filter { $0.category == category }) { tone in Text(tone.title).tag(tone) }
                    }
                }
            }
            Text(selection.detail).font(.callout).foregroundStyle(.secondary)
            if selection != .natural {
                Text("Guides expression using the selected voice. Strength varies with the text and recordings; preview before saving a final take.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
