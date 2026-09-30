import Foundation
import Testing
import ChatterCore
@testable import ChatterEngine

struct DialogueQualityTests {
    @Test(arguments: SpeechQuality.allCases, ["play", "save"])
    func actorTurnsKeepLiveModeAndQuality(quality: SpeechQuality, mode: String) throws {
        let json: [String: Any] = ["id":"dialogue", "text":"Host: Hello", "references":[],
            "mode":mode,"quality":quality.rawValue,"pace":1.25,"directory":"/tmp/Jobs/dialogue","output":"/tmp/final.wav"]
        let parent=try JSONDecoder().decode(SynthesizeCommand.self,from:JSONSerialization.data(withJSONObject:json))
        for kind in VoiceKind.allCases {
            let config=QwenVoiceConfiguration(kind:kind,speaker:kind == .preset ? "Aiden" : nil,description:kind == .designed ? "Warm voice" : nil)
            let turn=EngineDialogueTurn(actor:"Host",voiceID:"voice",text:"Hello",configuration:config,references:[],language:"English",instruction:nil,toneCue:"")
            let child=DialogueSynthesis.turnCommand(parent,turn:turn,index:3)
            #expect(child.mode == mode && child.quality == quality.rawValue)
            #expect(child.pace == 1) // Playback and final assembly each apply the parent's pace once.
            #expect(child.dialogueTurns == nil && child.text == "Hello" && child.voiceConfiguration == config)
            #expect(child.directory == "/tmp/Jobs/dialogue/turn-3")
            #expect(child.output == "/tmp/Jobs/dialogue/turn-3/speech.wav")
            let expected = kind == .preset ? "custom" : kind == .designed ? "design" : mode == "save" || quality == .studio ? "quality" : "fast"
            #expect(quality.modelProfile(for:kind,mode:child.mode) == expected)
        }
    }

    @Test func qualityHasTwoBufferingPoliciesAndCorrectModelFamilies() {
        #expect(SpeechQuality.responsive.streamsChunks)
        #expect(!SpeechQuality.balanced.streamsChunks && !SpeechQuality.studio.streamsChunks)
        #expect(SpeechQuality.responsive.modelProfile(for:.cloned,mode:"play") == SpeechQuality.balanced.modelProfile(for:.cloned,mode:"play"))
        #expect(SpeechQuality.studio.modelProfile(for:.cloned,mode:"play") != SpeechQuality.balanced.modelProfile(for:.cloned,mode:"play"))
    }

    @Test func oldDialogueTimingsDecodeAndNewTimingsRetainModelEvidence() throws {
        let old=try JSONDecoder().decode(DialogueTiming.self,from:Data(#"{"actor":"Host","start":0,"duration":2}"#.utf8))
        #expect(old.modelID == nil)
        let timing=DialogueTiming(actor:"Host",start:2.5,duration:3,modelID:"Qwen3/fast")
        let saved=try JSONDecoder().decode(DialogueTiming.self,from:JSONEncoder().encode(timing))
        #expect(saved.actor == "Host" && saved.start == 2.5 && saved.duration == 3 && saved.modelID == "Qwen3/fast")
    }
}
