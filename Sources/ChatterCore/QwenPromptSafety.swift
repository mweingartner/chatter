import Foundation

public enum QwenPromptSafety {
    /// Reserved tokenizer controls must not become conversation boundaries in caller text.
    /// Plain punctuation and non-control markup are preserved.
    public static func spokenText(_ text:String) -> String {
        text.replacingOccurrences(of:"<\\|[^<>\\r\\n]*\\|>",with:"",options:.regularExpression)
    }
}
