import Foundation
import ChatterCore

extension AppModel {
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.1.0" }
    func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        do { return HTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) }
        catch { return HTTPResponse(status: 500, body: Data("{\"error\":\"JSON encoding failed\"}".utf8)) }
    }
    func object<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? JSONSerialization.jsonObject(with: encoder.encode(value))) ?? [:]
    }
    func voiceList(access: ClientAccess = ClientAccess()) -> [[String: Any]] {
        voices.filter { access.allowsVoice($0.id) }.map { voice in
            let active = Set(voice.referenceSamples.map(\.id))
            return ["id":voice.id, "name":voice.name, "ready":voice.isReady, "kind":voice.kind.rawValue, "language":voice.synthesisConfiguration.language,
                    "supportsInstructions":voice.kind.supportsInstructions, "configuration":object(voice.synthesisConfiguration),
                    "sampleCount":voice.samples.count, "isDefault":voice.id == settings.defaultVoiceID,
                    "referenceMode":voice.usesReferenceSet ? "set" : "single",
                    "referenceSampleIDs":voice.referenceSamples.map(\.id),
                    "referenceDuration":voice.referenceSamples.reduce(0) { $0 + $1.metrics.duration },
                    "samples":voice.samples.map { ["id":$0.id,"label":$0.label,"duration":$0.metrics.duration,"included":active.contains($0.id)] as [String: Any] }]
        }
    }
    func toneList() -> [[String: String]] {
        SpeechTone.allCases.map { ["id":$0.rawValue, "name":$0.title, "category":$0.category, "description":$0.detail] }
    }
    func capabilitiesObject() -> [String: Any] {
        ["engine":QwenCapabilities.engine, "languages":QwenCapabilities.languages,
         "models":["fast":"0.6B Base 8-bit", "quality":"1.7B Base BF16", "custom":"1.7B CustomVoice BF16", "design":"1.7B VoiceDesign BF16"],
         "sampleRate":QwenCapabilities.sampleRate, "wavBits":24, "speakers":object(QwenCapabilities.speakers),
         "voiceKinds":VoiceKind.allCases.map { ["id":$0.rawValue,"name":$0.title,"supportsInstructions":$0.supportsInstructions] as [String: Any] },
         "expression":["provider":"qwen-native","automaticAnnotation":false,"instructionsSeparateFromText":true],
         "qualities":SpeechQuality.allCases.map { quality in
             ["id":quality.rawValue,"name":quality.title,"description":quality.detail,"streamsChunks":quality.streamsChunks,
              "models":Dictionary(uniqueKeysWithValues:VoiceKind.allCases.map { ($0.rawValue,quality.modelProfile(for:$0,mode:"play")) })] as [String:Any]
         },
         "saveQuality":SpeechQuality.saveNotice,
         "cloneDeliveryNotice":QwenCapabilities.cloneDeliveryNotice, "maximumReferenceSeconds":QwenCapabilities.maximumReferenceSeconds,
         "dialogue":["maximumActors":20,"maximumTurns":500,"atomicQueueJob":true,"turnTimings":true,"streamingPlayback":true,"qualitySelection":true],
         "training":"Reference conditioning locally; reviewed dataset export for the official CUDA fine-tuning recipe."]
    }
    func statusObject() -> [String: Any] {
        ["app":"Chatter", "version":Self.appVersion, "engine":engine.state, "detail":engine.detail,
         "expression":["provider":"qwen-native", "state":"native", "requestsDefault":false,"automaticAnnotation":false],
         "queueDepth":activeJobs, "queueCapacity":settings.queueCapacity, "warmProfiles":engine.ready ? engine.loadedProfiles : [],
         "engineFootprintBytes":engine.footprintBytes ?? NSNull(),
         "launchAtLoginStatus":loginStatus, "sampleRate":QwenCapabilities.sampleRate, "speechModel":QwenCapabilities.engine, "wavBits":24]
    }
    func jobObject(_ job: SpeechJob) -> [String: Any] {
        var result = object(job) as? [String: Any] ?? [:]
        result.removeValue(forKey: "references")
        result.removeValue(forKey: "dialogueTurns")
        result.removeValue(forKey: "toneCue")
        result.removeValue(forKey: "respell")
        result.removeValue(forKey: "expressionPlan")
        if let plan = job.expressionPlan {
            result["expressionNotes"] = plan.notes.map { ["sentence": $0.sentence + 1, "note": $0.note.rawValue] as [String: Any] }
            if !plan.isEmpty { result["expressionText"] = plan.annotate(job.request.text).text }
        }
        result["referenceSampleIDs"] = job.references?.map(\.sampleID) ?? job.request.sampleID.map { [$0] } ?? []
        result["queuePosition"] = job.isTerminal ? 0 : jobs.count { !$0.isTerminal && $0.sequence <= job.sequence }
        if job.state == "completed", job.path != nil { result["audioURL"] = "/v1/jobs/\(job.id)/audio" }
        return result
    }
    func requestFromJSON(_ value: [String: Any]) throws -> SpeechRequest {
        guard let text = value["text"] as? String, let voice = value["voice"] as? String else { throw ChatterError.invalid("voice and text are required strings.") }
        for field in ["mode", "quality", "sampleID", "requestID", "tone", "language", "instruction"] {
            if let supplied = value[field], !(supplied is String) { throw ChatterError.invalid("\(field) must be a string.") }
        }
        if let pace = value["pace"], CFGetTypeID(pace as CFTypeRef) == CFBooleanGetTypeID() { throw ChatterError.invalid("pace must be a number.") }
        if let pace = value["pace"], !(pace is NSNumber) { throw ChatterError.invalid("pace must be a number.") }
        return try SpeechRequest(voice: voice, text: text, pace: (value["pace"] as? Double) ?? 1,
                                 mode: (value["mode"] as? String) ?? "play", quality: value["quality"] as? String,
                                 sampleID: value["sampleID"] as? String, tone: value["tone"] as? String,
                                 language: value["language"] as? String, instruction: value["instruction"] as? String).validated()
    }
    func dialogueFromJSON(_ value: [String:Any]) throws -> SpeechRequest {
        let data=try JSONSerialization.data(withJSONObject:value)
        let script=try JSONDecoder().decode(DialogueScript.self,from:data).validated()
        var input=value
        input["voice"]=script.cast[script.turns[0].actor]!
        input["text"]=script.turns.map { $0.actor+": "+$0.text }.joined(separator:"\n")
        var request=try requestFromJSON(input)
        request.dialogue=script
        return request
    }
    func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Reject browser-origin requests. Native/CLI clients don't send Origin.
        if request.headers["origin"] != nil { return json(["error":"Browser origins are not enabled. Use an MCP client or native API client."], status: 403) }
        guard let access = access(for: request) else { var response = json(["error":"Bearer token required"], status: 401); response.headers["WWW-Authenticate"] = "Bearer"; return response }
        guard requestRate.allow(access.ownerID ?? "local", limit: 600) else { return HTTPResponse(status: 429, headers: ["Retry-After":"60"]) }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        if path == "/mcp" {
            if let version = request.headers["mcp-protocol-version"], !["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) { return json(["error":"Unsupported MCP protocol version"], status:400) }
            guard request.method == "POST" else { return HTTPResponse(status: 405, headers: ["Allow":"POST"]) }
            return handleMCP(request.body, access: access)
        }
        do {
            let required: ClientScope = request.method == "DELETE" ? .cancel : request.method == "POST" ? .speak : .read
            guard access.allows(required) else { return json(["error":"Client permission denied."], status:403) }
            if ["/v1/health", "/v1/status"].contains(path), request.method == "GET" { return json(statusObject()) }
            if path == "/v1/capabilities", request.method == "GET" { return json(capabilitiesObject()) }
            if path == "/v1/tones", request.method == "GET" { return json(["tones":toneList()]) }
            if path == "/v1/voices", request.method == "GET" { return json(["voices":voiceList(access: access)]) }
            if path == "/v1/dialogue", request.method == "POST" {
                guard let input=try JSONSerialization.jsonObject(with:request.body) as? [String:Any] else { throw ChatterError.invalid("Expected a JSON object") }
                return json(jobObject(try submit(dialogueFromJSON(input),requestID:(input["requestID"] as? String) ?? request.headers["idempotency-key"], access: access)),status:202)
            }
            if path == "/v1/speech", request.method == "POST" {
                guard let input = try JSONSerialization.jsonObject(with: request.body) as? [String:Any] else { throw ChatterError.invalid("Expected a JSON object") }
                return json(jobObject(try submit(requestFromJSON(input), requestID: (input["requestID"] as? String) ?? request.headers["idempotency-key"], access: access)), status: 202)
            }
            if path == "/v1/jobs", request.method == "GET" { return json(["jobs":jobs.filter { access.canRead($0) }.prefix(100).map(jobObject)]) }
            let pieces = path.split(separator: "/")
            if pieces.count >= 3, pieces[0] == "v1", pieces[1] == "jobs", let job = try job(id: String(pieces[2]), access: access) {
                if pieces.count == 3, request.method == "GET" { return json(jobObject(job)) }
                if pieces.count == 3, request.method == "DELETE" { cancelJob(job.id); return json(["id":job.id,"state":jobs.first(where: {$0.id == job.id})?.state ?? job.state]) }
                if pieces.count == 4, pieces[3] == "audio", request.method == "GET", job.state == "completed", let path = job.path {
                    var response = HTTPResponse(contentType: "audio/wav", headers: ["Content-Disposition":"attachment; filename=\"Chatter-\(job.id).wav\""])
                    response.fileURL = URL(filePath: path)
                    return response
                }
            }
            return json(["error":"Route or completed audio not found"], status: 404)
        } catch let error as ChatterError {
            let code: Int; if case .queueFull = error { code = 429 } else if case .unavailable = error { code = 503 } else { code = 400 }
            var response = json(["error":error.localizedDescription], status: code)
            if code == 429 { response.headers["Retry-After"] = "5" }; return response
        } catch { return json(["error":error.localizedDescription], status: 400) }
    }
    func handleMCP(_ data: Data, access: ClientAccess = ClientAccess()) -> HTTPResponse {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return json(["jsonrpc":"2.0","id":NSNull(),"error":["code":-32700,"message":"Parse error"]]) }
        let id: Any = value["id"] ?? NSNull()
        func result(_ result: Any) -> HTTPResponse { json(["jsonrpc":"2.0","id":id,"result":result]) }
        func failure(_ code: Int, _ message: String) -> HTTPResponse { json(["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]]) }
        guard value["jsonrpc"] as? String == "2.0", let method = value["method"] as? String else { return failure(-32600, "Invalid Request") }
        if value["id"] == nil { return HTTPResponse(status: 202) }
        let params = value["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-11-25"
            let negotiated = ["2024-11-05","2025-03-26","2025-06-18","2025-11-25"].contains(requested) ? requested : "2025-11-25"
            return result(["protocolVersion":negotiated,"capabilities":["tools":["listChanged":false]],"serverInfo":["name":"chatter","version":Self.appVersion],
                           "instructions":"Chatter speaks on its host Mac or saves a local WAV. List voices, call chatter_speak, then poll chatter_job until completed or failed. Submission only queues a job. mode=save uses full precision; mode=play speaks aloud. Qwen3-TTS runs locally. Check chatter_capabilities and each voice's supportsInstructions. Built-in and designed voices accept natural-language instructions; recorded clones inherit reference delivery. Qwen handles expression directly; no Ollama annotation runs before speech. Use chatter_dialogue for a cast and ordered turns, with mode=play and quality=responsive for chunk streaming or mode=save for a studio WAV. Use the returned audioURL with the same bearer token to retrieve audio over the LAN. Never claim a queued job is finished."])
        case "ping": return result([:])
        case "tools/list": return result(["tools":Self.mcpTools])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602,"Tool name required") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let required: ClientScope = ["chatter_speak","chatter_dialogue"].contains(name) ? .speak : name == "chatter_cancel" ? .cancel : .read
                guard access.allows(required) else { throw ChatterError.invalid("Client permission denied.") }
                let output: Any
                switch name {
                case "chatter_status": output = statusObject()
                case "chatter_capabilities": output = capabilitiesObject()
                case "chatter_tones": output = ["tones":toneList()]
                case "chatter_voices": output = ["voices":voiceList(access: access)]
                case "chatter_dialogue": output = jobObject(try submit(dialogueFromJSON(args), requestID:args["requestID"] as? String, access: access))
                case "chatter_speak": output = jobObject(try submit(requestFromJSON(args), requestID: args["requestID"] as? String, access: access))
                case "chatter_job":
                    guard let id = args["id"] as? String, let job = try job(id: id, access: access) else { throw ChatterError.invalid("Unknown job ID") }; output = jobObject(job)
                case "chatter_cancel":
                    guard let id = args["id"] as? String, let job = try job(id: id, access: access) else { throw ChatterError.invalid("Unknown job ID") }
                    cancelJob(id); output = ["id":id,"state":jobs.first(where: { $0.id == id })?.state ?? job.state]
                default: return failure(-32602,"Unknown tool")
                }
                let data = try JSONSerialization.data(withJSONObject: output, options: .sortedKeys)
                return result(["content":[["type":"text","text":String(decoding: data, as: UTF8.self)]],"structuredContent":output,"isError":false])
            } catch { return result(["content":[["type":"text","text":error.localizedDescription]],"isError":true]) }
        default: return failure(-32601,"Method not found")
        }
    }
    static var mcpTools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], _ required: [String] = [], readOnly: Bool = true) -> [String: Any] {
            ["name":name,"description":description,"inputSchema":["type":"object","properties":properties,"required":required,"additionalProperties":false],
             "annotations":["readOnlyHint":readOnly,"destructiveHint":name == "chatter_cancel","idempotentHint":readOnly,"openWorldHint":false]]
        }
        return [tool("chatter_status","Check model readiness and queue size."), tool("chatter_voices","List locally saved voice IDs and recordings."),
                tool("chatter_capabilities","List Qwen voice kinds, languages, speakers, models and instruction support."),
                tool("chatter_tones","List natural-language delivery presets for built-in and designed voices. Recorded clones inherit their reference delivery; unsupported tone requests return a warning."),
                tool("chatter_speak","Queue speech in a saved voice with pace and tone. mode=play speaks on the host Mac; mode=save creates a studio WAV for Remotion or editors such as Borumi. Poll chatter_job to completion before using the file.", [
                    "requestID":["type":"string","description":"Unique retry key; reuse only for the same speech", "maxLength":128],
                    "voice":["type":"string","description":"Saved voice ID or unique name"],"text":["type":"string","maxLength":100000],
                    "tone":["type":"string","enum":SpeechTone.allCases.map(\.rawValue),"default":"natural","description":"Delivery preset for built-in and designed voices. Cloned voices do not support instruction control."],
                    "language":["type":"string","enum":QwenCapabilities.languages,"description":"Language override; otherwise uses the voice profile"],
                    "instruction":["type":"string","maxLength":2000,"description":"Natural-language delivery instruction, only for built-in and designed voices"],
                    "pace":["type":"number","minimum":0.5,"maximum":2.0,"default":1],
                    "mode":["type":"string","enum":["play","save"],"default":"play"],
                    "quality":["type":"string","enum":SpeechQuality.allCases.map(\.rawValue),"description":"Responsive streams chunks; Balanced buffers passages with the same clone model; Studio uses the larger clone model. Built-in/designed voices use 1.7B at every level. Save always uses studio."],
                    "sampleID":["type":"string","description":"Optional single-take override; omit to use the configured voice set"]], ["voice","text"], readOnly:false),
                tool("chatter_dialogue","Play or save an ordered multi-actor script as one FIFO job. Responsive playback streams generated chunks on the host Mac. Saved output is a combined studio WAV. Completed jobs include dialogueTiming in seconds for editor alignment.",[
                    "cast":["type":"object","additionalProperties":["type":"string"],"description":"Actor name to saved voice ID or unique name"],
                    "turns":["type":"array","minItems":1,"maxItems":500,"items":["type":"object","required":["actor","text"],"properties":["actor":["type":"string"],"text":["type":"string"],"tone":["type":"string","enum":SpeechTone.allCases.map(\.rawValue)],"language":["type":"string","enum":QwenCapabilities.languages],"instruction":["type":"string"]]]],
                    "gapSeconds":["type":"number","minimum":0,"maximum":10,"default":0.35],
                    "mode":["type":"string","enum":["play","save"]],"pace":["type":"number","minimum":0.5,"maximum":2],
                    "quality":["type":"string","enum":SpeechQuality.allCases.map(\.rawValue),"description":"Live quality for every actor; save always uses studio. See chatter_capabilities for model and buffering details."],
                    "tone":["type":"string","enum":SpeechTone.allCases.map(\.rawValue)],"language":["type":"string","enum":QwenCapabilities.languages],
                    "requestID":["type":"string","maxLength":128]], ["cast","turns"],readOnly:false),
                tool("chatter_job","Read job state and errors. Completed saved jobs include an absolute WAV path, duration in seconds and authenticated audio URL for editor handoff.",["id":["type":"string"]],["id"]),
                tool("chatter_cancel","Cancel a queued or running job and stop its playback.",["id":["type":"string"]],["id"],readOnly:false)]
    }
}
