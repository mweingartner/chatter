import Foundation
import SQLite3

/// Durable, indexed receipts. Only active work and a bounded recent page are hydrated.
/// Legacy fsynced JSON receipts migrate individually; each is removed only after SQL commit.
public final class JobDatabase {
    private var database: OpaquePointer?
    public let maximumPendingBytes: Int64
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL = ChatterPaths.root, maximumPendingBytes: Int64 = 64_000_000) throws {
        self.maximumPendingBytes = maximumPendingBytes
        try PrivateStorage.directory(root)
        let url = root.appending(path: "jobs.sqlite3")
        if !FileManager.default.fileExists(atPath: url.path) { try PrivateStorage.write(Data(), to: url) }
        try PrivateStorage.protectFile(url)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA busy_timeout=5000;")
        try execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, owner TEXT NOT NULL, request TEXT, sequence INTEGER NOT NULL, terminal INTEGER NOT NULL, created REAL NOT NULL, hidden INTEGER NOT NULL DEFAULT 0, body BLOB NOT NULL);")
        try execute("CREATE INDEX IF NOT EXISTS retry ON jobs(owner, request); CREATE INDEX IF NOT EXISTS history ON jobs(terminal, sequence DESC);")
        for folder in ["Queue", "ArchivedReceipts"] {
            let directory = root.appending(path: folder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            try PrivateStorage.directory(directory)
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let bytes = try ChatterPaths.readRegularFile(at: url, upTo: 8_000_000)
                guard bytes.count <= 8_000_000 else { throw ChatterError.invalid("A legacy job receipt exceeds the safety limit.") }
                let job = try decoder.decode(SpeechJob.self, from: bytes)
                guard UUID(uuidString: job.id) != nil, url.deletingPathExtension().lastPathComponent == job.id else { throw ChatterError.invalid("Invalid legacy job ID.") }
                if try find(id: job.id) == nil { try save(job, hidden: folder == "ArchivedReceipts", enforceBudget: false) }
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    deinit { sqlite3_close(database) }
    public func save(_ job: SpeechJob, hidden: Bool = false, enforceBudget: Bool = true) throws {
        let bytes = try encoder.encode(job)
        guard bytes.count <= 8_000_000 else { throw ChatterError.invalid("Job receipt exceeds the safety limit. Reduce the number of dialogue turns.") }
        if enforceBudget, !job.isTerminal, try find(id: job.id) == nil {
            let size = try prepare("SELECT COALESCE(SUM(length(body)),0) FROM jobs WHERE terminal=0 AND id<>?")
            defer { sqlite3_finalize(size) }
            bind(job.id, to: size, at: 1)
            guard sqlite3_step(size) == SQLITE_ROW else { throw failure() }
            guard sqlite3_column_int64(size, 0) + Int64(bytes.count) <= maximumPendingBytes else { throw ChatterError.queueFull }
        }
        let stmt = try prepare("INSERT INTO jobs(id,owner,request,sequence,terminal,created,hidden,body) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET terminal=excluded.terminal,body=excluded.body;")
        defer { sqlite3_finalize(stmt) }
        bind(job.id, to: stmt, at: 1); bind(job.clientID ?? "", to: stmt, at: 2)
        if let request = job.requestID { bind(request, to: stmt, at: 3) } else { sqlite3_bind_null(stmt, 3) }
        guard job.sequence <= UInt64(Int64.max) else { throw ChatterError.invalid("Job sequence exhausted.") }
        sqlite3_bind_int64(stmt, 4, Int64(job.sequence)); sqlite3_bind_int(stmt, 5, job.isTerminal ? 1 : 0)
        sqlite3_bind_double(stmt, 6, job.createdAt.timeIntervalSince1970); sqlite3_bind_int(stmt, 7, hidden ? 1 : 0)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 8, $0.baseAddress, Int32($0.count), Self.transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func recent(limit: Int = 1000) throws -> [SpeechJob] {
        try query("SELECT body FROM (SELECT body FROM jobs WHERE terminal=0 ORDER BY sequence ASC) UNION ALL SELECT body FROM (SELECT body FROM jobs WHERE terminal=1 AND hidden=0 ORDER BY sequence DESC LIMIT ?)", number: max(1, limit), maximumBytes: maximumPendingBytes + 16_000_000).sorted { $0.sequence > $1.sequence }
    }
    public func find(id: String) throws -> SpeechJob? { try query("SELECT body FROM jobs WHERE id=?", strings: [id]).first }
    public func find(requestID: String, owner: String?) throws -> SpeechJob? {
        try query("SELECT body FROM jobs WHERE owner=? AND request=? LIMIT 1", strings: [owner ?? "", requestID]).first
    }
    public func activeCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM jobs WHERE terminal=0"); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    public func maximumSequence() throws -> UInt64 {
        let stmt = try prepare("SELECT COALESCE(MAX(sequence),0) FROM jobs"); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return UInt64(max(0, sqlite3_column_int64(stmt, 0)))
    }
    public func archiveFinished() throws { try execute("UPDATE jobs SET hidden=1 WHERE terminal=1") }
    /// Returns one bounded cleanup page. Active jobs are never eligible.
    public func expired(days: Int, keep: Int, now: Date = .now) throws -> [SpeechJob] {
        let threshold = now.addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
        return try query("SELECT body FROM jobs WHERE terminal=1 AND (created < \(threshold) OR id IN (SELECT id FROM jobs WHERE terminal=1 ORDER BY sequence DESC LIMIT -1 OFFSET \(max(1,keep)))) LIMIT 100", maximumBytes: 16_000_000)
    }
    public func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    public func remove(id: String) throws {
        let stmt = try prepare("DELETE FROM jobs WHERE id=? AND terminal=1"); defer { sqlite3_finalize(stmt) }
        bind(id, to: stmt, at: 1); guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func query(_ sql: String, strings: [String] = [], number: Int? = nil, maximumBytes: Int64 = 8_000_000) throws -> [SpeechJob] {
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        for (i, value) in strings.enumerated() { bind(value, to: stmt, at: Int32(i + 1)) }
        if let number { sqlite3_bind_int64(stmt, 1, Int64(number)) }
        var jobs: [SpeechJob] = []
        var bytesRead: Int64 = 0
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return jobs }
            guard result == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard let pointer = sqlite3_column_blob(stmt, 0), count <= 8_000_000 else { throw failure() }
            if !jobs.isEmpty, bytesRead + Int64(count) > maximumBytes { return jobs }
            bytesRead += Int64(count)
            jobs.append(try decoder.decode(SpeechJob.self, from: Data(bytes: pointer, count: count)))
        }
    }
    private func bind(_ value: String, to stmt: OpaquePointer?, at index: Int32) { _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.transient) } }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        return stmt
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func failure() -> ChatterError { .unavailable("The job database could not be read or saved. Check disk space and permissions.") }
}
