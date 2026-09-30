// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// A JSON value that keeps integers distinct from floats and preserves object key order,
/// so documents round-trip the way Python's `json` module handles them.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Parses one complete JSON document (surrounding whitespace allowed).
    public static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        try parse(Array(text.utf8))
    }

    /// Parses one complete JSON document from UTF-8 bytes.
    public static func parse(_ data: Data) throws(JSONParseError) -> JSONValue {
        try parse([UInt8](data))
    }

    static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSONValue {
        var parser = JSONParser(bytes: bytes)
        return try parser.document()
    }

    /// Member lookup; `nil` for a missing key or a non-object.
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Element lookup; `nil` when out of range or not an array.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var intValue: Int? { if case .int(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: JSONObject? { if case .object(let value) = self { value } else { nil } }

    /// Numeric value of an int or double (booleans excluded).
    public var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// Python truthiness: `None`, `False`, zero, and empty strings/containers are false.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }

    /// Python `==` semantics: numbers compare by value, objects ignore key order.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default:
            if let a = lhs.numberValue, let b = rhs.numberValue { a == b } else { false }
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(Double(value))
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let value): hasher.combine(value)
        case .object(let value): hasher.combine(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

/// A JSON object that preserves insertion order; re-assigning a key keeps its position (like a Python dict).
public struct JSONObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) { self.init(elements) }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func makeIterator() -> some IteratorProtocol<(key: String, value: JSONValue)> {
        keys.lazy.compactMap { key in storage[key].map { (key: key, value: $0) } }.makeIterator()
    }

    /// Order-insensitive equality, as for Python dicts.
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }

    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
}

/// Why a JSON document could not be parsed, positioned like Python's `JSONDecodeError`.
public struct JSONParseError: ChatterToolingFailure, Sendable, Equatable {
    public let reason: String
    public let line: Int
    public let column: Int
    public let offset: Int

    public var description: String { "\(reason): line \(line) column \(column) (char \(offset))" }
}

/// Strict RFC 8259 recursive-descent parser over UTF-8 bytes.
private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    /// Recursion bound that fits the 512 KB stacks of Swift concurrency threads (even in debug builds).
    /// MCP messages and Remotion handoffs nest far less deeply.
    static let maximumDepth = 128

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func document() throws(JSONParseError) -> JSONValue {
        skipWhitespace()
        let value = try value()
        skipWhitespace()
        guard index == bytes.count else { throw failure("Extra data") }
        return value
    }

    func failure(_ reason: String, at position: Int? = nil) -> JSONParseError {
        let position = min(position ?? index, bytes.count)
        let prefix = String(decoding: bytes[..<position], as: UTF8.self)
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let lastLine = prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return JSONParseError(
            reason: reason, line: line, column: lastLine.unicodeScalars.count + 1, offset: prefix.unicodeScalars.count)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws(JSONParseError) -> JSONValue {
        guard index < bytes.count else { throw failure("Expecting value") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
        default: throw failure("Expecting value")
        }
    }

    mutating func literal(_ word: String, _ value: JSONValue) throws(JSONParseError) -> JSONValue {
        let expected = Array(word.utf8)
        guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure("Expecting value")
        }
        index += expected.count
        return value
    }

    mutating func enter() throws(JSONParseError) {
        depth += 1
        guard depth <= Self.maximumDepth else { throw failure("Maximum nesting depth exceeded") }
    }

    mutating func object() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw failure("Expecting property name enclosed in double quotes")
            }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure("Expecting ':' delimiter") }
            index += 1
            skipWhitespace()
            object[key] = try value()
            skipWhitespace()
            guard index < bytes.count else { throw failure("Expecting ',' delimiter") }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            guard bytes[index] == UInt8(ascii: ",") else { throw failure("Expecting ',' delimiter") }
            index += 1
            skipWhitespace()
        }
    }

    mutating func array() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw failure("Expecting ',' delimiter") }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            guard bytes[index] == UInt8(ascii: ",") else { throw failure("Expecting ',' delimiter") }
            index += 1
            skipWhitespace()
        }
    }

    mutating func string() throws(JSONParseError) -> String {
        let start = index
        index += 1
        var scalars = String.UnicodeScalarView()
        var runStart = index
        func flush(_ end: Int) {
            scalars.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).unicodeScalars)
        }
        while true {
            guard index < bytes.count else { throw failure("Unterminated string starting at", at: start) }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                flush(index)
                index += 1
                return String(scalars)
            }
            if byte < 0x20 { throw failure("Invalid control character at") }
            guard byte == UInt8(ascii: "\\") else {
                index += 1
                continue
            }
            flush(index)
            guard index + 1 < bytes.count else { throw failure("Unterminated string starting at", at: start) }
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try hexQuad()
                if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
                    bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                {
                    let save = index
                    index += 2
                    let low = try hexQuad()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                    }
                }
                // Lone surrogates cannot be represented in a Swift String.
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default:
                throw failure("Invalid \\escape", at: index - 2)
            }
            runStart = index
        }
    }

    mutating func hexQuad() throws(JSONParseError) -> UInt32 {
        guard index + 4 <= bytes.count,
            let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16),
            bytes[index..<index + 4].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
        else { throw failure("Invalid \\uXXXX escape", at: index - 1) }
        index += 4
        return code
    }

    mutating func number() throws(JSONParseError) -> JSONValue {
        let start = index
        func digits(_ parser: inout JSONParser) -> Int {
            let first = parser.index
            while parser.index < parser.bytes.count, (0x30...0x39).contains(parser.bytes[parser.index]) {
                parser.index += 1
            }
            return parser.index - first
        }
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
            index = start
            throw failure("Expecting value")
        }
        if bytes[index] == UInt8(ascii: "0") { index += 1 } else { _ = digits(&self) }
        var isInteger = true
        if index < bytes.count, bytes[index] == UInt8(ascii: "."), index + 1 < bytes.count,
            (0x30...0x39).contains(bytes[index + 1])
        {
            index += 1
            _ = digits(&self)
            isInteger = false
        }
        if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
            let save = index
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            if digits(&self) == 0 { index = save } else { isInteger = false }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger, let value = Int(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { throw failure("Number out of range", at: start) }
        return .double(value)
    }
}

// MARK: - Encoding

extension JSONValue {
    /// Layout choices mirroring Python's `json.dumps`.
    public enum Layout: Sendable {
        /// `json.dumps(value)`: one line with `", "` and `": "` separators.
        case compact
        /// `json.dumps(value, indent=2)`.
        case indented
    }

    /// Serializes like Python's `json.dumps(value, indent=…, ensure_ascii=…)`.
    public func encoded(_ layout: Layout = .compact, asciiOnly: Bool = true) -> String {
        var output = ""
        write(to: &output, layout: layout, asciiOnly: asciiOnly, level: 0)
        return output
    }

    private func write(to output: inout String, layout: Layout, asciiOnly: Bool, level: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .int(let value): output += String(value)
        case .double(let value): output += Self.pythonFloat(value)
        case .string(let value): Self.writeString(value, to: &output, asciiOnly: asciiOnly)
        case .array(let items):
            guard !items.isEmpty else { return output += "[]" }
            output += "["
            for (offset, item) in items.enumerated() {
                Self.separate(&output, layout: layout, level: level + 1, first: offset == 0)
                item.write(to: &output, layout: layout, asciiOnly: asciiOnly, level: level + 1)
            }
            Self.close(&output, "]", layout: layout, level: level)
        case .object(let object):
            guard !object.isEmpty else { return output += "{}" }
            output += "{"
            for (offset, member) in object.enumerated() {
                Self.separate(&output, layout: layout, level: level + 1, first: offset == 0)
                Self.writeString(member.key, to: &output, asciiOnly: asciiOnly)
                output += ": "
                member.value.write(to: &output, layout: layout, asciiOnly: asciiOnly, level: level + 1)
            }
            Self.close(&output, "}", layout: layout, level: level)
        }
    }

    private static func separate(_ output: inout String, layout: Layout, level: Int, first: Bool) {
        switch layout {
        case .compact: if !first { output += ", " }
        case .indented: output += (first ? "\n" : ",\n") + String(repeating: "  ", count: level)
        }
    }

    private static func close(_ output: inout String, _ bracket: String, layout: Layout, level: Int) {
        if layout == .indented { output += "\n" + String(repeating: "  ", count: level) }
        output += bracket
    }

    /// Python `repr(float)`; Swift's shortest round-trip description uses the same thresholds.
    static func pythonFloat(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return value.description
    }

    private static func writeString(_ value: String, to output: inout String, asciiOnly: Bool) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 || (asciiOnly && scalar.value > 0x7E) {
                    for unit in String(scalar).utf16 { output += "\\u" + hex4(unit) }
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    private static func hex4(_ unit: UInt16) -> String {
        let digits = String(unit, radix: 16)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// Python `str(value)` for scalars (strings unquoted, `None`/`True`/`False`) and `repr` for containers.
    public var pythonDescription: String {
        if case .string(let value) = self { return value }
        return pythonRepr
    }

    /// Python `repr(value)` of the equivalent `json.loads` result, e.g. `{'status': 'ok', 'ready': True}`.
    public var pythonRepr: String {
        switch self {
        case .null: "None"
        case .bool(let value): value ? "True" : "False"
        case .int(let value): String(value)
        case .double(let value): value.isNaN ? "nan" : value.isInfinite ? (value < 0 ? "-inf" : "inf") : value.description
        case .string(let value): Self.pythonStringRepr(value)
        case .array(let items): "[" + items.map(\.pythonRepr).joined(separator: ", ") + "]"
        case .object(let object):
            "{" + object.map { Self.pythonStringRepr($0.key) + ": " + $0.value.pythonRepr }.joined(separator: ", ") + "}"
        }
    }

    private static func pythonStringRepr(_ value: String) -> String {
        let quote: Character = value.contains("'") && !value.contains("\"") ? "\"" : "'"
        var output = String(quote)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if Character(scalar) == quote {
                    output += "\\" + String(quote)
                } else if scalar.value < 0x20 || (0x7F...0xA0).contains(scalar.value) {
                    let digits = String(scalar.value, radix: 16)
                    output += "\\x" + (digits.count == 1 ? "0" : "") + digits
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append(quote)
        return output
    }
}
