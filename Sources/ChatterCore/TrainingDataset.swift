import Foundation

/// A portable copy; never edits the user's originals. The external Qwen recipe consumes JSONL.
public enum TrainingDataset {
    public static func export(voice:VoiceProfile,to directory:URL, voicesRoot:URL = ChatterPaths.voices) throws {
        guard voice.kind == .cloned,!voice.referenceSamples.isEmpty else { throw ChatterError.invalid("Choose a recorded voice with enabled takes.") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        var lines:[String]=[]
        for (index,sample) in voice.referenceSamples.enumerated() {
            guard !sample.transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ChatterError.invalid("Every take needs an exact transcript.") }
            let name="take-\(index).wav"
            try FileManager.default.copyItem(at:voicesRoot.appending(path:voice.id).appending(path:sample.id).appending(path:"reference.wav"),to:directory.appending(path:name))
            let data=try JSONSerialization.data(withJSONObject:["audio":name,"text":sample.transcript,"ref_audio":"take-0.wav"],options:.sortedKeys)
            lines.append(String(decoding:data,as:UTF8.self))
        }
        try (lines.joined(separator:"\n")+"\n").write(to:directory.appending(path:"train.jsonl"),atomically:true,encoding:.utf8)
        try """
        # Qwen voice dataset: \(voice.name)
        Exported enabled recordings with exact transcripts; no model weights were trained.
        Copy this entire folder to a compatible CUDA training machine. Review each recording and transcript, reserve separate validation recordings, then follow:
        https://github.com/QwenLM/Qwen3-TTS/tree/022e286b98fbec7e1e916cb940cdf532cd9f488e/finetuning
        Run the recipe's data preparation from this directory so relative audio paths resolve. Use take-0.wav as the consistent speaker reference. The result must be converted and validated before use with this native MLX runtime; Chatter does not claim to import arbitrary checkpoints automatically.
        """.write(to:directory.appending(path:"README.md"),atomically:true,encoding:.utf8)
    }
}
