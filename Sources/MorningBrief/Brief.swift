import Foundation

enum BriefError: LocalizedError {
    case missingResource(String)
    case noAgent
    case agentFailed(String)
    case timedOut(Int)
    case unparseable(String)
    /// A scheduled run began without connectors that worked last time (agent name, their names).
    case connectorsMissing(agent: String, names: String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let n): return "Missing app resource: \(n)"
        case .noAgent: return "No agent found. Install Claude Code or Codex, or set a binary path in Settings."
        case .agentFailed(let m): return m
        case .timedOut(let m): return "The agent didn't finish within \(m) minutes."
        case .unparseable(let m): return "Couldn't read the agent's answer as a brief. \(m)"
        case .connectorsMissing(let agent, let names): return "\(agent) started without \(names), which worked last time."
        }
    }
}

/// The data contract between the agent and the renderer. Mirrors Resources/brief.schema.json.
/// Encoded/decoded with snake_case keys.
struct Brief: Codable {
    struct Labels: Codable { var needsAttention: String?; var resolved: String? }
    struct Event: Codable { var title: String?; var start: String?; var end: String?; var optional: Bool? }
    struct Motif: Codable { var kind: String?; var act: Int? }
    struct Act: Codable { var label: String?; var start: String?; var end: String?; var text: String? }
    struct Button: Codable { var label: String?; var seed: String? }
    struct Item: Codable {
        var title: String?
        var text: String?
        var sourcePhrase: String?
        var url: String?
        var button: Button?
    }
    struct Section: Codable { var heading: String?; var prose: String?; var items: [Item]? }

    var dateLine: String?
    var direction: String?
    var dayClass: String?
    var headline: String
    var labels: Labels?
    var events: [Event]?
    var motif: Motif?
    var acts: [Act]?
    var needsAttention: [Item]?
    var resolved: [Item]?
    var sections: [Section]?
    var emptyMessage: String?
    var connectNote: String?
    var sourcesUsed: [String]?

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

enum JSONExtract {
    /// Finds the first JSON object in `text` that decodes as a Brief.
    /// Agents sometimes wrap answers in prose or ``` fences; this tolerates both.
    static func brief(from text: String) throws -> Brief {
        var lastError = "No JSON object found in the agent's output."
        for candidate in objects(in: text) {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                let b = try Brief.decoder.decode(Brief.self, from: data)
                if !b.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return b }
                lastError = "The JSON had an empty headline."
            } catch {
                lastError = "JSON didn't match the brief format: \(error)"
            }
        }
        throw BriefError.unparseable(lastError)
    }

    /// Balanced top-level {...} spans, string-aware, in order of appearance.
    static func objects(in text: String) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var depth = 0
                var inString = false
                var escaped = false
                var j = i
                var closed = false
                while j < chars.count {
                    let c = chars[j]
                    if inString {
                        if escaped { escaped = false }
                        else if c == "\\" { escaped = true }
                        else if c == "\"" { inString = false }
                    } else if c == "\"" {
                        inString = true
                    } else if c == "{" {
                        depth += 1
                    } else if c == "}" {
                        depth -= 1
                        if depth == 0 { closed = true; break }
                    }
                    j += 1
                }
                if closed {
                    results.append(String(chars[i...j]))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return results
    }
}
