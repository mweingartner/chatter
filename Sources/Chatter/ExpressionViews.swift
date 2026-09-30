import SwiftUI
import ChatterCore

/// The expression notes a job used, for its card.
struct ExpressionSummary: View {
    let job: SpeechJob
    var body: some View {
        if let plan = job.expressionPlan, !plan.isEmpty {
            Label("Notes: " + Self.counted(plan), systemImage: "theatermasks").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        } else if job.expressive == true, job.expressionPlan != nil, job.expressionMessage == nil {
            Label("No sentence called for a note.", systemImage: "theatermasks").font(.caption).foregroundStyle(.secondary)
        }
        if let message = job.expressionMessage {
            Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Each note once, in order of first use, with how often it was used: "empathetic ×3 · calm".
    static func counted(_ plan: ExpressionPlan) -> String {
        var order: [ExpressionNote] = [], counts: [ExpressionNote: Int] = [:]
        for note in plan.notes.map(\.note) {
            if counts[note] == nil { order.append(note) }
            counts[note, default: 0] += 1
        }
        return order.map { counts[$0, default: 1] > 1 ? "\($0.rawValue) ×\(counts[$0, default: 1])" : $0.rawValue }.joined(separator: " · ")
    }
}

/// Qwen handles expression itself; keep directions separate from words to be spoken.
struct ExpressionView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: "Direct the delivery", subtitle: "Qwen understands emotion and phrasing from your text. For built-in and designed voices, add a tone or a plain-language direction without annotating the script.")
                Surface {
                    Label("Native Qwen expression", systemImage: "theatermasks").font(.headline)
                    Text("Choose a tone in Studio, then use Delivery instruction for details such as: Warm and optimistic, with a measured pace. Emphasize the final sentence.")
                    Text("Chatter sends directions separately from the spoken words. No Ollama review, automatic emotion tags, or extra language-model wait is used for speech.").foregroundStyle(.secondary)
                    Text("For precise changes between actors, dialogue API turns accept individual tone and instruction values. Legacy leading notes remain readable, but separate instructions are recommended for new scripts.").font(.callout).foregroundStyle(.secondary)
                }
                Surface {
                    Text("What each voice can do").font(.headline)
                    LabeledContent("Built-in speaker", value: "Tone and delivery instructions")
                    LabeledContent("Designed voice", value: "Voice description plus delivery instructions")
                    LabeledContent("Recorded voice", value: "Delivery from the reference recordings and spoken text")
                    Text(QwenCapabilities.cloneDeliveryNotice).font(.callout).foregroundStyle(.secondary)
                    Text("Natural leaves delivery to Qwen and the voice. Instructions guide generation; their strength and consistency vary by voice and text.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.voices) { voice in
                        LabeledContent(voice.name, value: voice.kind.supportsInstructions ? "Instruction control available" : "Reference-based delivery")
                    }
                }
                Surface {
                    Text("Playback quality and WAV export").font(.headline)
                    ForEach(SpeechQuality.allCases) { quality in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(quality.title).font(.subheadline.bold())
                            Text(quality.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Text(SpeechQuality.sharedNotice).font(.callout).foregroundStyle(.secondary)
                    Text(SpeechQuality.saveNotice).font(.callout).foregroundStyle(.secondary)
                }
            }.padding(30)
        }
    }
}
