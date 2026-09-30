import Foundation

/// Portable synthesis provenance. Never copy the full receipt: it contains host paths.
enum NarrationMetadata {
    static func add(to entry: inout JSONObject, request: JSONObject, job: JSONObject,
                    timing: NarrationTiming, fps: Int, scene: String) throws {
        for key in ["language", "instruction", "quality", "sampleID"] {
            if let value = request[key] { entry[key] = value }
        }
        for key in ["voiceName", "engineName", "modelID", "profile", "referenceSampleIDs", "warnings"] {
            if let value = job[key] { entry[key] = value }
        }
        if let configuration = job["voiceConfiguration"]?.objectValue {
            entry["voiceConfiguration"] = filtered(configuration, keys: ["kind", "speaker", "description", "language"])
        }
        guard let dialogue = request["dialogue"]?.objectValue else { return }
        guard let cast = dialogue["cast"]?.objectValue, let turns = dialogue["turns"]?.arrayValue,
              let timings = job["dialogueTiming"]?.arrayValue, turns.count == timings.count,
              !turns.isEmpty else { throw RemotionHandoffError.invalidDialogueTiming(scene: scene) }
        let safeTurns = try turns.map { turn -> JSONValue in
            guard let object = turn.objectValue else { throw RemotionHandoffError.invalidDialogueTiming(scene: scene) }
            return filtered(object, keys: ["actor", "text", "tone", "language", "instruction"])
        }
        var script: JSONObject = ["cast": .object(cast), "turns": .array(safeTurns)]
        if let gap = dialogue["gapSeconds"] { script["gapSeconds"] = gap }
        entry["dialogue"] = .object(script)
        var previousEnd = 0.0
        entry["dialogueTiming"] = .array(try zip(turns, timings).map { turn, stamp in
            guard let actor = turn["actor"]?.stringValue, stamp["actor"] == .string(actor),
                  let voice = cast[actor]?.stringValue, let start = stamp["start"]?.numberValue,
                  let duration = stamp["duration"]?.numberValue,
                  start.isFinite, duration.isFinite, start >= 0, duration > 0,
                  start + 0.001 >= previousEnd, start + duration <= timing.durationSeconds + 0.001
            else { throw RemotionHandoffError.invalidDialogueTiming(scene: scene) }
            previousEnd = start + duration
            let from = min(timing.audioFrames, Int(floor(start * Double(fps))))
            let end = min(timing.audioFrames, Int(ceil((start + duration) * Double(fps))))
            var result: JSONObject = ["actor": .string(actor), "voice": .string(voice),
                "start": .double(start), "duration": .double(duration),
                "from": .int(from), "durationInFrames": .int(end - from)]
            if let model = stamp["modelID"] { result["modelID"] = model }
            return .object(result)
        })
    }

    private static func filtered(_ source: JSONObject, keys: [String]) -> JSONValue {
        var result = JSONObject()
        for key in keys { if let value = source[key] { result[key] = value } }
        return .object(result)
    }
}
