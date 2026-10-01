import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    /// Set only by the listener, never by a client header.
    public var isLocal = true
    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
    public static func parse(_ data: Data, maxBody: Int = 2_000_000, headersOnly: Bool = false) throws -> (HTTPRequest, Int)? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw ChatterError.invalid("Headers too large") }; return nil
        }
        guard boundary.lowerBound < 16_384,
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw ChatterError.invalid("Invalid headers") }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw ChatterError.invalid("Invalid HTTP request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ChatterError.invalid("Invalid header") }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) && ![40,41,60,62,64,44,59,58,92,34,47,91,93,63,61,123,125].contains($0) }),
                  line.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { throw ChatterError.invalid("Invalid header characters") }
            guard headers[key] == nil else { throw ChatterError.invalid("Duplicate header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw ChatterError.invalid("Chunked request bodies are not supported") }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0, n <= maxBody else { throw ChatterError.invalid("Invalid or oversized body") }; length = n
        } else { length = 0 }
        if headersOnly { return (HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers), boundary.upperBound) }
        let end = boundary.upperBound + length
        guard data.count >= end else { return nil }
        // Close after one request. Reject smuggled/pipelined surplus data.
        guard data.count == end else { throw ChatterError.invalid("Unexpected trailing data") }
        return (HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: data[boundary.upperBound..<end]), end)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var headers: [String: String]
    public var fileURL: URL?
    public init(status: Int = 200, body: Data = Data(), contentType: String = "application/json", headers: [String:String] = [:]) {
        self.status = status; self.body = body; self.contentType = contentType; self.headers = headers
    }
    public var data: Data {
        head(contentLength: body.count) + body
    }
    public func head(contentLength: Int) -> Data {
        let reason = [200:"OK",202:"Accepted",204:"No Content",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",413:"Payload Too Large",429:"Too Many Requests",500:"Internal Server Error",503:"Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(contentLength)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8)
    }
}
