// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import Testing

@Suite("JSON values behave like Python's json module")
struct JSONValueTests {
    @Test("Compact encoding matches json.dumps byte for byte")
    func compactEncoding() throws {
        let value = try JSONValue.parse(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true,"n":null,"list":[1,2.5,[]],"obj":{}}}"#)
        #expect(value.encoded() == #"{"jsonrpc": "2.0", "id": 1, "result": {"ok": true, "n": null, "list": [1, 2.5, []], "obj": {}}}"#)
    }

    @Test("Indented encoding matches json.dumps(indent=2)")
    func indentedEncoding() {
        let value: JSONValue = ["a": 1, "b": ["x", 1.0], "c": [:], "d": []]
        #expect(value.encoded(.indented) == "{\n  \"a\": 1,\n  \"b\": [\n    \"x\",\n    1.0\n  ],\n  \"c\": {},\n  \"d\": []\n}")
    }

    @Test("ensure_ascii escapes non-ASCII with lowercase hex and surrogate pairs")
    func asciiEscaping() {
        let value: JSONValue = .string("é—🎙\u{7F}\u{01}\"\\/\n\t")
        #expect(value.encoded() == #""\u00e9\u2014\ud83c\udf99\u007f\u0001\"\\/\n\t""#)
        #expect(value.encoded(asciiOnly: false) == "\"é—🎙\u{7F}\\u0001\\\"\\\\/\\n\\t\"")
    }

    @Test("Integers and floats stay distinct; floats print like Python repr")
    func numbers() throws {
        #expect(try JSONValue.parse("30") == .int(30))
        #expect(try JSONValue.parse("30.0").intValue == nil)
        #expect(try JSONValue.parse("-0.5e1") == .double(-5))
        #expect(JSONValue.double(1).encoded() == "1.0")
        #expect(JSONValue.double(44101.0 / 44100).encoded() == "1.0000226757369615")
        #expect(JSONValue.double(1e16).encoded() == "1e+16")
        #expect(try JSONValue.parse("123456789012345678901234567890") == .double(1.2345678901234568e29))
    }

    @Test("Object key order is preserved; a repeated key keeps its first position and last value")
    func keyOrder() throws {
        let value = try JSONValue.parse(#"{"z":1,"a":2,"z":3}"#)
        #expect(value.objectValue?.keys == ["z", "a"])
        #expect(value.encoded() == #"{"z": 3, "a": 2}"#)
    }

    @Test("Escapes, surrogate pairs and lone surrogates decode")
    func stringEscapes() throws {
        #expect(try JSONValue.parse(#""\u00e9\ud83c\udf99\/\b\f""#) == .string("é🎙/\u{08}\u{0C}"))
        #expect(try JSONValue.parse(#""\ud800x""#) == .string("\u{FFFD}x"))
    }

    @Test(
        "Parse errors carry Python's wording and position",
        arguments: [
            ("", "Expecting value: line 1 column 1 (char 0)"),
            ("not json", "Expecting value: line 1 column 1 (char 0)"),
            ("{\"a\" 1}", "Expecting ':' delimiter: line 1 column 6 (char 5)"),
            ("[1 2]", "Expecting ',' delimiter: line 1 column 4 (char 3)"),
            ("{1:2}", "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"),
            ("\"abc", "Unterminated string starting at: line 1 column 1 (char 0)"),
            ("{}\n{}", "Extra data: line 2 column 1 (char 3)"),
            ("\"a\u{01}\"", "Invalid control character at: line 1 column 3 (char 2)"),
            ("\"\\q\"", "Invalid \\escape: line 1 column 2 (char 1)"),
            ("NaN", "Expecting value: line 1 column 1 (char 0)"),
        ])
    func parseErrors(input: String, message: String) {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(input) }
        do {
            _ = try JSONValue.parse(input)
        } catch {
            #expect(error.description == message)
        }
    }

    @Test("Deep nesting is rejected instead of overflowing the stack")
    func depthLimit() throws {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(String(repeating: "[", count: 10_000)) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(String(repeating: #"{"a":"#, count: 129) + "1" + String(repeating: "}", count: 129)) }
        let deepest = String(repeating: #"{"a":["#, count: 64) + "1" + String(repeating: "]}", count: 64)
        let value = try JSONValue.parse(deepest)
        #expect(try JSONValue.parse(value.encoded()) == value && value.pythonRepr.count > 0)
    }

    @Test("Equality follows Python: numbers by value, objects ignore order, bools are not numbers")
    func equality() throws {
        #expect(JSONValue.int(1) == .double(1.0))
        #expect(try JSONValue.parse(#"{"a":1,"b":2}"#) == JSONValue.parse(#"{"b":2,"a":1}"#))
        #expect(JSONValue.bool(true) != .int(1))
        #expect(JSONValue.null != .bool(false))
    }

    @Test("Python repr and truthiness")
    func pythonViews() {
        let health: JSONValue = ["status": "ok", "ready": true, "depth": 0, "note": .null, "who": "it's"]
        #expect(health.pythonRepr == #"{'status': 'ok', 'ready': True, 'depth': 0, 'note': None, 'who': "it's"}"#)
        #expect(JSONValue.string("a\nb").pythonRepr == "'a\\nb'")
        #expect(JSONValue.string("queued").pythonDescription == "queued")
        #expect(!JSONValue.int(0).isTruthy && !JSONValue.string("").isTruthy && !JSONValue.object([:]).isTruthy)
        #expect(JSONValue.array([.null]).isTruthy && JSONValue.double(0.1).isTruthy)
    }

    @Test("Round trip of arbitrary documents is stable", arguments: [
        #"{"a":[1,-2,3.25,true,false,null,"s"],"b":{"c":{"d":[]}}}"#,
        #"[" \u00e9 ", 1e-07, 0.0001, -0.0]"#,
    ])
    func roundTrip(input: String) throws {
        let value = try JSONValue.parse(input)
        #expect(try JSONValue.parse(value.encoded()) == value)
        #expect(try JSONValue.parse(value.encoded(.indented, asciiOnly: false)) == value)
        #expect(try JSONValue.parse(value.encoded()).encoded() == value.encoded())
    }
}
