import SwiftUI
import ChatterCore

struct DialogueView: View {
    @Environment(AppModel.self) private var model
    @State private var cast = [CastMember(actor:"Host"),CastMember(actor:"Guest")]
    @State private var script="Host: Welcome. Let's explore what is possible.\nGuest: Thanks for having me. I am excited to get started."
    @State private var gap=0.35
    @State private var pace=1.0
    @State private var quality="responsive"
    @State private var tone:SpeechTone = .natural
    struct CastMember: Identifiable { let id=UUID();var actor:String;var voice="" }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                PageTitle(title:"Give every actor a voice",subtitle:"Create a conversation, interview, or narrated scene. Each actor keeps their assigned voice, and the full script runs as one queued job.")
                Surface {
                    Text("Cast").font(.headline)
                    ForEach($cast) { $member in
                        HStack {
                            TextField("Actor name",text:$member.actor).textFieldStyle(.roundedBorder)
                            Picker("Voice for \(member.actor)",selection:$member.voice) {
                                Text("Choose voice").tag("")
                                ForEach(model.voices.filter(\.isReady)) { Text($0.name).tag($0.id) }
                            }
                            Button("Remove actor",systemImage:"minus.circle") { cast.removeAll { $0.id == member.id } }.labelStyle(.iconOnly).disabled(cast.count<=1)
                        }
                    }
                    Button("Add actor",systemImage:"plus") { cast.append(CastMember(actor:"Actor \(cast.count+1)")) }.disabled(cast.count>=20)
                }
                Surface {
                    Text("Script").font(.headline)
                    Text("Use Actor: dialogue on each line. Actor labels select voices and are not spoken. API clients can also set tone, language, and delivery instructions per turn.").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text:$script).frame(minHeight:230).accessibilityLabel("Dialogue script")
                    TonePicker(selection:$tone)
                    Text("Tone applies to built-in and designed voices. Recorded voices keep the delivery of their reference recordings.").font(.caption).foregroundStyle(.secondary)
                    Picker("Live quality", selection: $quality) {
                        ForEach(SpeechQuality.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text((SpeechQuality(rawValue:quality) ?? .responsive).detail).font(.caption).foregroundStyle(.secondary)
                    Text(SpeechQuality.sharedNotice).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Turn spacing: \(gap.formatted(.number.precision(.fractionLength(2)))) s")
                        Slider(value:$gap,in:0...3,step:0.05).accessibilityLabel("Turn spacing")
                    }
                    HStack { Text("Pace: \(pace.formatted(.number.precision(.fractionLength(2))))×");Slider(value:$pace,in:0.5...2,step:0.05).accessibilityLabel("Dialogue pace") }
                    HStack {
                        Button("Play dialogue",systemImage:"play.fill") { submit(mode:"play") }.buttonStyle(.borderedProminent)
                        Button("Save WAV",systemImage:"square.and.arrow.down") { submit(mode:"save") }
                        if model.activeJobs > 0 { Button("Stop speech",systemImage:"stop.fill") { model.cancelAll() } }
                    }.disabled(!model.engine.ready)
                    Text("Play begins as audio is generated on this Mac. Model switching can create gaps between actors. " + SpeechQuality.saveNotice).font(.caption).foregroundStyle(.secondary)
                }
                if let job=model.jobs.first(where:{ $0.request.dialogue != nil }) { JobCard(job:job) }
            }.padding(30)
        }
        .onAppear {
            quality=model.settings.liveQuality
            if let voice=model.defaultVoice { for i in cast.indices where cast[i].voice.isEmpty { cast[i].voice=voice.id } }
        }
    }
    private func submit(mode: String) {
        do {
            var assignments:[String:String]=[:]
            for member in cast {
                let actor=member.actor.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !actor.contains(":"),assignments[actor] == nil else { throw ChatterError.invalid("Actor names must be unique and contain no colon.") }
                assignments[actor]=member.voice
            }
            let turns=try script.split(separator:"\n").map { line -> DialogueLine in
                guard let colon=line.firstIndex(of:":") else { throw ChatterError.invalid("Each script line must start with Actor: followed by dialogue.") }
                return DialogueLine(actor:String(line[..<colon]).trimmingCharacters(in:.whitespaces),text:String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces))
            }
            let dialogue=try DialogueScript(cast:assignments,turns:turns,gapSeconds:gap).validated()
            var request=SpeechRequest(voice:assignments[turns[0].actor]!,text:script,pace:pace,mode:mode,quality:quality,tone:tone.rawValue,expressive:false)
            request.dialogue=dialogue
            _ = try model.submit(request)
        } catch { model.error=error.localizedDescription }
    }
}
