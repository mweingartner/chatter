import Foundation
import Testing
@testable import ChatterCore

/// Seeded SplitMix64: every generated case replays from its seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The helper's stdin protocol. Every line comes from the app, but a malformed, truncated or hostile
/// line must be rejected with an error (never a crash, never a guessed operation).
struct EngineProtocolTests {
    static let valid = [
        #"{"op":"synthesize","id":"a","text":"Hi","references":[{"reference":"/r.wav","transcript":"t"}],"mode":"play","pace":1,"directory":"/d","output":"/o.wav"}"#,
        #"{"op":"prepare","id":"b","source":"/s.wav","destination":"/d","transcript":"words"}"#,
        #"{"op":"precache","id":"c","references":[]}"#,
        #"{"op":"analyze","id":"d","source":"/s.wav"}"#,
        #"{"op":"configure","id":"e","keepStudioLoaded":true,"studioIdleSeconds":30}"#,
        #"{"op":"status","id":"f"}"#,
        #"{"op":"cancel","target":"a"}"#,
    ]

    static func decode(_ line: String) throws -> EngineCommand { try EngineCommand.decode(Data(line.utf8)) }

    /// A stable description of a decode outcome, for determinism checks (a status line without an
    /// id is given a fresh UUID, so only its kind is compared).
    static func outcome(_ data: Data) -> String {
        do {
            switch try EngineCommand.decode(data) {
            case .synthesize(let c): return "synthesize:\(c.id)"
            case .prepare(let c): return "prepare:\(c.id)"
            case .precache(let c): return "precache:\(c.id)"
            case .analyze(let c): return "analyze:\(c.id)"
            case .configure(let c): return "configure:\(c.id)"
            case .status: return "status"
            case .cancel(let target): return "cancel:\(target)"
            }
        } catch { return "error:\(error.localizedDescription)" }
    }

    @Test func synthesizeFieldsSurviveDecodingExactly() throws {
        let line = #"{"op":"synthesize","id":"job-1","text":"Line one.\nLine two — naïve 中文 😀","references":[{"reference":"/V/a/reference.wav","transcript":"first"},{"reference":"/V/b/reference.wav","transcript":"second"}],"toneCue":"[calm tone]","mode":"save","pace":1.25,"quality":"studio","directory":"/J/job-1","output":"/O/x.wav","seed":18446744073709551615,"temperature":0.5,"unknownField":{"nested":[1,2,3]}}"#
        guard case .synthesize(let c) = try Self.decode(line) else { Issue.record("wrong operation"); return }
        #expect(c.id == "job-1" && c.mode == "save" && c.pace == 1.25 && c.quality == "studio")
        #expect(c.text == "Line one.\nLine two — naïve 中文 😀")
        #expect(c.references == [EngineReference(reference: "/V/a/reference.wav", transcript: "first"),
                                 EngineReference(reference: "/V/b/reference.wav", transcript: "second")])
        #expect(c.toneCue == "[calm tone]" && c.directory == "/J/job-1" && c.output == "/O/x.wav")
        #expect(c.seed == UInt64.max && c.temperature == 0.5)
    }

    @Test func optionalFieldsDefaultToNil() throws {
        guard case .synthesize(let c) = try Self.decode(Self.valid[0]) else { Issue.record("wrong operation"); return }
        #expect(c.toneCue == nil && c.quality == nil && c.seed == nil && c.temperature == nil)
        guard case .configure(let configure) = try Self.decode(#"{"op":"configure","id":"x"}"#) else { Issue.record("wrong operation"); return }
        #expect(configure.keepStudioLoaded == nil && configure.studioIdleSeconds == nil)
        guard case .prepare(let prepare) = try Self.decode(#"{"op":"prepare","id":"x","source":"/s","destination":"/d"}"#) else { Issue.record("wrong operation"); return }
        #expect(prepare.transcript == nil)
    }

    @Test func statusWithoutAnIDGetsAFreshUniqueOne() throws {
        let first = try Self.decode(#"{"op":"status"}"#).id, second = try Self.decode(#"{"op":"status"}"#).id
        #expect(UUID(uuidString: first) != nil && UUID(uuidString: second) != nil && first != second)
    }

    @Test func cancelTargetsTheJobNotItsOwnID() throws {
        guard case .cancel(let target) = try Self.decode(#"{"op":"cancel","id":"ignored","target":"job-7"}"#) else { Issue.record("wrong operation"); return }
        #expect(target == "job-7")
    }

    @Test func errorsNameTheProblem() {
        func message(_ line: String) -> String {
            do { _ = try Self.decode(line); return "" } catch { return error.localizedDescription }
        }
        #expect(message(#"{"op":"shell","id":"x"}"#) == "Unknown worker operation shell")
        #expect(message(#"{"op":"Synthesize","id":"x"}"#) == "Unknown worker operation Synthesize")   // case-sensitive
        #expect(message(#"{"op":"cancel","id":"x"}"#) == "cancel requires a target")
    }

    @Test(arguments: [
        "", " ", "null", "[]", "42", #""status""#, "{", #"{"op":null,"id":"x"}"#, #"{"op":7,"id":"x"}"#,
        #"{"op":"status","id":7}"#, #"{"op":"cancel","target":null}"#, #"{"op":"cancel","target":["a"]}"#,
        #"{"op":"synthesize","id":"x","text":"t","references":[],"mode":"play","pace":"fast","directory":"/d","output":"/o.wav"}"#,
        #"{"op":"synthesize","id":"x","text":"t","references":[],"mode":"play","pace":1,"directory":"/d","output":"/o.wav","seed":-1}"#,
        #"{"op":"synthesize","id":"x","text":"t","references":[],"mode":"play","pace":1,"directory":"/d","output":"/o.wav","seed":1.5}"#,
        #"{"op":"synthesize","id":"x","text":"t","references":[],"mode":"play","pace":1,"directory":"/d","output":"/o.wav","seed":18446744073709551616}"#,
        #"{"op":"synthesize","id":"x","text":"t","references":[{"reference":"/r.wav"}],"mode":"play","pace":1,"directory":"/d","output":"/o.wav"}"#,
        #"{"op":"synthesize","id":"x","text":"t","references":[],"mode":"play","pace":NaN,"directory":"/d","output":"/o.wav"}"#,
        #"{"op":"configure","id":"x","keepStudioLoaded":"true"}"#,
        #"{"op":"prepare","id":"x","source":"/s"}"#,
        #"{"op":"analyze","id":"x"}"#,
        #"{"op":"precache","id":"x"}"#,
        "\u{FEFF}{\"op\":\"status\",\"id\":\"x\"} trailing",
    ])
    func malformedLinesAreRejected(line: String) {
        #expect(throws: (any Error).self) { try Self.decode(line) }
    }

    @Test func largeTextIsPreservedByteForByte() throws {
        let text = String(repeating: "Ünïcödé 中文 😀 \\ \" / \t", count: 40_000)   // ~1.2 MB
        let object: [String: Any] = ["op": "synthesize", "id": "big", "text": text, "references": [], "mode": "play",
                                     "pace": 1, "directory": "/d", "output": "/o.wav"]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .synthesize(let c) = try EngineCommand.decode(data) else { Issue.record("wrong operation"); return }
        #expect(c.text.utf8.elementsEqual(text.utf8))
    }

    /// Deep nesting in an ignored field must fail (or decode) cleanly rather than overflow the stack.
    @Test(arguments: [100, 10_000, 200_000])
    func deeplyNestedJSONDoesNotCrash(depth: Int) {
        let line = #"{"op":"status","id":"x","junk":"# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
        _ = Self.outcome(Data(line.utf8))
    }

    /// Fuzz: truncations, byte flips, insertions and splices of valid lines never crash and decode
    /// deterministically; any line that decodes carries a known operation.
    @Test func mutatedLinesNeverCrashAndAreDeterministic() {
        for seed in UInt64(1)...1500 {
            var rng = SeededGenerator(seed: seed)
            var bytes = Array(Self.valid.randomElement(using: &rng)!.utf8)
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
                case 1 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                case 2:
                    let pieces = [#"""#, "\\", "{", "}", "[", "]", ",", ":", "null", "\u{0}", "\\u0000", "\\ud800", "1e999", "-0", "😀"]
                    bytes.insert(contentsOf: Array(pieces.randomElement(using: &rng)!.utf8), at: Int.random(in: 0...bytes.count, using: &rng))
                case 3:
                    let other = Array(Self.valid.randomElement(using: &rng)!.utf8)
                    bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng))) + other.suffix(Int.random(in: 0...other.count, using: &rng))
                default:
                    if !bytes.isEmpty { bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng)) }
                }
            }
            let data = Data(bytes)
            let first = Self.outcome(data)
            #expect(first == Self.outcome(data), "seed \(seed): \(String(decoding: bytes, as: UTF8.self).debugDescription)")
        }
    }

    /// Metamorphic: key order and insignificant whitespace do not change the decoded command.
    @Test func keyOrderAndWhitespaceAreIrrelevant() throws {
        for (index, line) in Self.valid.enumerated() {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            var rng = SeededGenerator(seed: UInt64(index))
            let keys = object.keys.shuffled(using: &rng)
            let members = try keys.map { key -> String in
                let value = try JSONSerialization.data(withJSONObject: object[key]!, options: [.fragmentsAllowed])
                return "\n\t\(try String(data: JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]), encoding: .utf8)!) :  \(String(decoding: value, as: UTF8.self)) "
            }
            let reordered = "  {" + members.joined(separator: ",") + "}\r\n"
            #expect(try Self.decode(reordered).id == Self.decode(line).id)
        }
    }
}
