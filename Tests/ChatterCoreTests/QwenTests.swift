import Foundation
import Testing
@testable import ChatterCore

struct QwenTests {
    @Test func reservedTokensCannotChangeSpeakerOrConversation() {
        #expect(QwenPromptSafety.spokenText("Hello<|im_end|><|im_start|>world <tag>!")=="Helloworld <tag>!")
    }

    @Test func legacyVoicesAndReceiptsRemainReadable() throws {
        let voice=VoiceProfile(name:"Michael")
        let data=try JSONEncoder().encode(voice)
        let decoded=try JSONDecoder().decode(VoiceProfile.self,from:data)
        #expect(decoded.kind == .cloned)
        #expect(!decoded.kind.supportsInstructions)
        let job=SpeechJob(request:SpeechRequest(voice:voice.id,text:"Hello"),voiceName:voice.name)
        let receipt=try JSONDecoder().decode(SpeechJob.self,from:JSONEncoder().encode(job))
        #expect(receipt.voiceConfiguration == nil && receipt.dialogueTurns == nil)
    }
    @Test func capabilityValidation() throws {
        #expect(try QwenCapabilities.language("ENGLISH")=="English")
        #expect(throws:ChatterError.self) { try QwenCapabilities.language("Latin") }
        #expect(try QwenVoiceConfiguration(kind:.preset,speaker:"aiden").validated().speaker == "Aiden")
        #expect(throws:ChatterError.self) { try QwenVoiceConfiguration(kind:.preset,speaker:"Michael").validated() }
        #expect(throws:ChatterError.self) { try QwenVoiceConfiguration(kind:.designed,description:" ").validated() }
        #expect(try QwenVoiceConfiguration(kind:.designed,description:"A clear voice").validated().kind.supportsInstructions)
        #expect(!QwenCapabilities.warnings(configuration:.init(),request:.init(voice:"v",text:"Hello",tone:"optimistic")).isEmpty)
    }
    @Test func dialogueIsBoundedAndAllActorsResolve() throws {
        let script=DialogueScript(cast:["A":"Michael","B":"Ryan"],turns:[.init(actor:"A",text:"Hello"),.init(actor:"B",text:"Welcome",tone:"optimistic")])
        #expect(try script.validated()==script)
        #expect(try JSONDecoder().decode(DialogueScript.self,from:JSONEncoder().encode(script))==script)
        for invalid in [DialogueScript(cast:[:],turns:[]),DialogueScript(cast:["A":"v"],turns:[.init(actor:"B",text:"Hello")]),DialogueScript(cast:["A":"v"],turns:[.init(actor:"A",text:" ")]),DialogueScript(cast:["A":"v"],turns:[.init(actor:"A",text:"Hi")],gapSeconds:.infinity)] {
            #expect(throws:ChatterError.self) { try invalid.validated() }
        }
    }
    @Test func presetDoesNotRequireRecordings() throws {
        var voice=VoiceProfile(name:"Aiden");voice.qwen = .init(kind:.preset,speaker:"Aiden")
        #expect(voice.isReady && voice.samples.isEmpty)
        #expect(try voice.references().isEmpty)
        #expect(throws:ChatterError.self) { try voice.references(overriding:"take") }
    }
}
