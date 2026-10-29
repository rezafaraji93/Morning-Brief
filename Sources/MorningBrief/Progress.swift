import Foundation

/// What the agent is doing right now, read from its live output while a brief is being written.
struct RunProgress: Equatable {
    var copy: String
    var toolCalls: Int = 0
}

/// Something the agent's live output said it was doing.
enum AgentEvent {
    /// The run began. Claude Code also says which MCP servers it had and their state; nil for an
    /// agent that doesn't report them.
    case started([MCPServerStatus]?)
    case tool(String)   // the tool's name as the agent calls it
    case thinking
    case writing
}

/// What a brief cost to write. Stored next to the brief as <day>.meta.json.
struct BriefUsage: Codable, Hashable {
    var agent: String
    var model: String?
    var totalTokens: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var costUSD: Double?
    var durationSeconds: Int
    var toolCalls: Int

    /// "1.7M tokens · $2.08 · 3m 25s"
    var summary: String {
        var parts = ["\(Self.tokens(totalTokens)) tokens"]
        if let c = costUSD { parts.append(Self.money(c)) }
        parts.append(Self.duration(durationSeconds))
        return parts.joined(separator: " · ")
    }

    /// The breakdown behind the summary, for a tooltip.
    var detail: String {
        var lines = ["Written by \(agent)" + (model.map { " (\($0))" } ?? "")]
        if let i = inputTokens, let o = outputTokens {
            var input = "Input \(Self.tokens(i))"
            if let r = cacheReadTokens, r > 0 { input += " + \(Self.tokens(r)) from cache" }
            if let w = cacheWriteTokens, w > 0 { input += " + \(Self.tokens(w)) cached" }
            lines.append(input)
            lines.append("Output \(Self.tokens(o))")
        }
        lines.append("\(toolCalls) lookups in \(Self.duration(durationSeconds))")
        if let c = costUSD { lines.append("About \(Self.money(c)) at list prices") }
        return lines.joined(separator: "\n")
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000: return "\(n / 1_000)k"
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func money(_ usd: Double) -> String {
        usd < 0.005 ? "under 1¢" : String(format: "$%.2f", usd)
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// Short lines for the running card. Each tool the agent reaches for gets its own flavour, and
/// the line changes with every call so the panel visibly keeps up.
enum ProgressCopy {
    static func started(_ agent: String) -> String { "Waking up \(agent)…" }
    static let writing = "Writing it up…"

    private static let thinkingLines = [
        "Connecting the dots…", "Thinking it over…", "Weighing what matters…", "Sorting signal from noise…",
    ]

    static func thinking(index: Int) -> String { pick(thinkingLines, index) }

    private static let lines: [(keywords: [String], lines: [String])] = [
        (["slack"], ["Skimming your Slack…", "Lurking in your channels…", "Reading the threads you muted…",
                     "Catching up on the chatter…", "Scrolling past the GIFs…"]),
        (["granola", "fireflies", "otter", "fathom", "tldv"],
         ["Rereading your meeting notes…", "Remembering what you promised…", "Checking the minutes…"]),
        (["calendar"], ["Peeking at your calendar…", "Mapping out your day…", "Counting the meetings…"]),
        (["gmail", "mail", "outlook"], ["Sorting your inbox…", "Opening the mail…"]),
        (["linear"], ["Walking the Linear board…", "Checking your tickets…", "Counting what's still open…"]),
        (["notion"], ["Flipping through Notion…", "Paging through the docs…"]),
        (["github", "gitlab"], ["Looking over your PRs…", "Checking the review queue…"]),
        (["drive"], ["Rummaging through Drive…"]),
        (["jira", "atlassian", "confluence"], ["Checking Jira…", "Wandering through Confluence…"]),
        (["datadog", "sentry"], ["Watching the dashboards…", "Looking for anything on fire…"]),
        (["figma"], ["Peeking at Figma…"]),
        (["asana", "trello", "clickup", "monday"], ["Checking the task board…"]),
        (["web"], ["Looking something up…"]),
        (["read"], ["Reading a long one…"]),
    ]

    static func line(forTool name: String, index: Int) -> String {
        let n = name.lowercased()
        for entry in lines where entry.keywords.contains(where: { n.contains($0) }) {
            return pick(entry.lines, index)
        }
        return pick(["Gathering…", "Digging a little deeper…", "Pulling the threads…"], index)
    }

    private static func pick(_ options: [String], _ index: Int) -> String {
        options[index % options.count]
    }
}
