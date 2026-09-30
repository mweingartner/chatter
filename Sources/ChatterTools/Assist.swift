import ChatterCore
import Foundation

/// `chatter-tools assist …`: the expression model's work, for evaluation. Output is one JSON object per line.
/// `--address URL` talks to another (loopback) Ollama address.
///   models                                    local Ollama models
///   notes [--model M] [--file F]              reviews each paragraph (built-in samples, or F split at blank lines)
///   respell [--model M] [--no-think] [term…]  pronunciation suggestions (a built-in reference set when no term is given)
enum AssistCommand {
    static func run(_ arguments: [String]) async throws {
        var rest = arguments.dropFirst()
        var model = Settings().expressionModel, file: String?, think = true, terms: [String] = [], address = OllamaClient.defaultAddress
        while let argument = rest.popFirst() {
            switch argument {
            case "--model": model = rest.popFirst() ?? model
            case "--file": file = rest.popFirst()
            case "--no-think": think = false
            case "--address": address = rest.popFirst() ?? address
            default: terms.append(argument)
            }
        }
        let client = try OllamaClient(address: address), chosen = model
        switch arguments.first {
        case "models":
            for item in try await client.localModels() {
                emit(["name": item.name, "bytes": item.sizeBytes, "capabilities": item.capabilities, "parameters": item.parameterSize ?? ""])
            }
        case "notes":
            let paragraphs = try file.map { try String(contentsOfFile: $0, encoding: .utf8).components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } } ?? samples
            for paragraph in paragraphs {
                let start = ContinuousClock.now
                let outcome = await ExpressionReview.run(paragraph, budget: ExpressionReview.savedBudget) { sentences, left in
                    let reply = try await client.chat(model: chosen, instructions: ExpressionReview.instructions(tone: .natural),
                                                      prompt: ExpressionReview.prompt(sentences), schema: ExpressionReview.schema, think: false, timeout: left)
                    return ExpressionReview.notes(in: reply, count: sentences.count)
                }
                emit(["model": model, "seconds": seconds(ContinuousClock.now - start), "notes": outcome.plan.notes.count,
                      "sentences": outcome.total, "text": outcome.plan.annotate(paragraph).text, "message": outcome.message ?? "",
                      "plan": outcome.plan.notes.map { [$0.sentence, $0.note.rawValue] as [Any] }])
            }
        case "respell":
            let capable = try await client.localModels().first { $0.name == model }?.canThink ?? false
            for term in terms.isEmpty ? references.map(\.term) : terms {
                let start = ContinuousClock.now
                do {
                    let reply = try await client.chat(model: model, instructions: PronunciationSuggestions.instructions,
                                                      prompt: PronunciationSuggestions.prompt(for: term), schema: PronunciationSuggestions.schema,
                                                      think: think && capable, timeout: .seconds(300))
                    let found = PronunciationSuggestions.candidates(in: reply, for: term)
                    let accepted = references.first { $0.term == term }?.accepted ?? []
                    emit(["model": model, "term": term, "suggestions": found, "reference": accepted,
                          "matchesReference": !accepted.isEmpty && found.contains { candidate in accepted.contains { letters($0) == letters(candidate) } },
                          "seconds": seconds(ContinuousClock.now - start)])
                } catch { emit(["model": model, "term": term, "error": error.localizedDescription]) }
            }
        default:
            FileHandle.standardError.write(Data("usage: chatter-tools assist models|notes|respell [--model M] [--file F] [--no-think] [term…]\n".utf8))
            exit(2)
        }
    }

    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func seconds(_ duration: Duration) -> Double {
        ((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 100).rounded() / 100
    }

    /// Letters only, lowercased: a floor for "same respelling" (it misses equivalent spellings).
    static func letters(_ text: String) -> String { String(text.lowercased().filter(\.isLetter)) }

    static let samples = [
        "I am so happy to be here! Thank you all for coming tonight. Get off that roof! You could have been hurt. The meeting starts at noon.",
        "We lost the championship by a single point. Everyone was silent on the bus ride home. But next season, we will be back, stronger than ever.",
        "Quick, the train leaves in two minutes! Grab your bag and run. Don't tell anyone, but I bought her a ring. I think she is going to say yes.",
        "The quarterly report shows revenue of 4.2 million dollars. Operating costs fell by three percent. Headcount remained flat.",
        "Wait, you did what? You deleted the production database? On a Friday? I can't believe this is happening.",
        "We're sorry your order arrived late. We know how much you were counting on it. A full refund is on its way, and your next delivery is free.",
        "Once upon a time, a little fox lived at the edge of a quiet wood. Every night she watched the stars and wondered where they went. One evening, a star fell right into her garden!",
    ]

    /// Terms with how people actually say them (common variants accepted), for judging suggestions.
    static let references: [(term: String, accepted: [String])] = [
        ("Kubernetes", ["koo-ber-NET-eez"]), ("nginx", ["engine X", "engine ex"]), ("SQL", ["sequel", "S Q L"]), ("GIF", ["jif", "gif"]),
        ("Nguyen", ["win", "nwin", "nuh-win"]), ("Worcestershire", ["WUSS-ter-sher", "WOOS-ter-sher"]), ("Hermès", ["air-MEZ", "er-MEZ"]),
        ("Qdrant", ["quadrant", "KWAD-rant"]), ("PyPI", ["pie P I", "pie-pee-eye"]), ("LaTeX", ["LAY-tek", "LAH-tek"]),
        ("Xiaomi", ["SHOW-mee", "shau-mee"]), ("Huawei", ["WAH-way", "HWAH-way"]), ("Porsche", ["PORSH-uh", "PORSH"]),
        ("Azure", ["AZH-er", "AZ-yoor"]), ("Linux", ["LIN-ux", "LIN-uks", "LIN-uhks"]), ("Siobhan", ["shih-VAWN", "shiv-AWN"]),
        ("kubectl", ["KOOB-control", "koob-cuttle", "cube-control", "cube-cuttle"]), ("Grafana", ["gruh-FAH-nuh", "GRAF-uh-nuh"]),
        ("Zsh", ["zee shell", "Z shell", "zed shell"]), ("Chipotle", ["chih-POHT-lay"]), ("Saoirse", ["SEER-shuh", "SER-shuh"]),
        ("gyro", ["YEER-oh", "JY-roh"]), ("SQLite", ["S Q L ite", "sequel-ite"]), ("Ubuntu", ["oo-BOON-too"]), ("Debian", ["DEB-ee-un", "DEB-ee-an"]),
        ("Ghibli", ["JIB-lee", "GIB-lee"]), ("Hyundai", ["HUN-day", "HYUN-day"]), ("Joaquin", ["wah-KEEN"]), ("PostgreSQL", ["POST-gres", "post-gres-Q-L"]),
        ("Coeur d'Alene", ["KOR-duh-LAYN", "core-duh-LANE"]), ("quinoa", ["KEEN-wah"]), ("Moët", ["mo-ET", "moh-WET"]), ("OAuth", ["OH-auth"]), ("JSON", ["JAY-son"]),
    ]
}
