import Foundation

/// Builds the headless invocation for each agent CLI and pulls the final answer out of its output.
///
/// Safety model: the prompt forbids any write action, and each agent is started in its most
/// restrictive mode that still lets it call read tools on MCP connectors:
///  - Claude Code: `--permission-mode auto` with the shell and file-editing tools disallowed.
///  - Codex: `--sandbox read-only`.
///  - Gemini CLI: `--approval-mode plan` (read-only).
/// Users can override or extend flags with "Extra arguments" in Settings.
struct AgentRunner {
    let kind: AgentKind
    let binary: String
    let settings: AppSettings

    enum Mode { case brief, probe, personalize }

    struct Invocation {
        let args: [String]
        let outputFile: URL?
    }

    func invocation(prompt: String, mode: Mode, claudePermissionMode: String = "auto") throws -> Invocation {
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        let extra = ArgSplitter.split(settings.extraArgs)
        switch kind {
        case .claude:
            var a = ["-p", prompt, "--output-format", "json", "--no-session-persistence"]
            if !extra.contains("--permission-mode") && !extra.contains("--dangerously-skip-permissions") {
                a += ["--permission-mode", claudePermissionMode]
            }
            a += ["--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit"]
            if mode == .brief {
                a += ["--json-schema", try Res.string("brief.schema", "json")]
            } else if mode == .personalize {
                a += ["--json-schema", try Res.string("personalize.schema", "json")]
            }
            if !model.isEmpty { a += ["--model", model] }
            return Invocation(args: a + extra, outputFile: nil)

        case .codex:
            let out = Paths.work.appendingPathComponent("codex-last-message-\(UUID().uuidString).txt")
            var a = ["exec", "--skip-git-repo-check", "--ephemeral",
                     "--sandbox", "read-only",
                     "-c", "approval_policy=\"never\"",
                     "--color", "never",
                     "-C", Paths.work.path,
                     "-o", out.path]
            if mode == .brief, let schema = Res.url("brief.schema", "json") {
                a += ["--output-schema", schema.path]
            } else if mode == .personalize, let schema = Res.url("personalize.schema", "json") {
                a += ["--output-schema", schema.path]
            }
            if !model.isEmpty { a += ["-m", model] }
            return Invocation(args: a + extra + [prompt], outputFile: out)

        case .gemini:
            var a = ["-p", prompt, "--output-format", "json", "--skip-trust"]
            // Read-only plan mode unless the user picked a mode under "Extra arguments".
            if !extra.contains("--approval-mode") && !extra.contains("--yolo") && !extra.contains("-y") {
                a += ["--approval-mode", "plan"]
            }
            if !model.isEmpty { a += ["-m", model] }
            return Invocation(args: a + extra, outputFile: nil)
        }
    }

    /// The agent's final text answer, unwrapped from each CLI's JSON envelope.
    func finalText(stdout: String, outputFile: URL?) -> String {
        switch kind {
        case .claude:
            // {"type":"result","is_error":false,"result":"...","structured_output":{...}}
            if let obj = jsonObject(stdout) {
                if let so = obj["structured_output"], JSONSerialization.isValidJSONObject(so),
                   let data = try? JSONSerialization.data(withJSONObject: so),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
                if let r = obj["result"] as? String { return r }
            }
            return stdout
        case .codex:
            if let f = outputFile, let s = try? String(contentsOf: f, encoding: .utf8) {
                try? FileManager.default.removeItem(at: f)
                if !s.isEmpty { return s }
            }
            return stdout
        case .gemini:
            // {"response":"...","stats":{...}}
            if let obj = jsonObject(stdout), let r = obj["response"] as? String { return r }
            return stdout
        }
    }

    /// Error text the CLI reported inside its JSON envelope, if any.
    func reportedError(stdout: String) -> String? {
        guard let obj = jsonObject(stdout) else { return nil }
        if kind == .claude, (obj["is_error"] as? Bool) == true {
            return (obj["result"] as? String) ?? "Claude Code reported an error."
        }
        if kind == .gemini, let err = obj["error"] as? [String: Any] {
            return (err["message"] as? String) ?? "Gemini CLI reported an error."
        }
        return nil
    }

    private func jsonObject(_ s: String) -> [String: Any]? {
        // The envelope is the last JSON object printed; tolerate log lines before it.
        for candidate in JSONExtract.objects(in: s).reversed() {
            if let d = candidate.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return o
            }
        }
        return nil
    }
}

/// A model choice offered in the Settings dropdown. Value "" means the agent's default.
struct ModelOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

extension AgentKind {
    /// A short, curated list per agent. "Agent default" is always right; the rest are the
    /// commonly used names as of early 2026. Anything else goes through "Custom…".
    var modelOptions: [ModelOption] {
        switch self {
        case .claude:
            return [
                ModelOption(value: "", label: "Agent default (recommended)"),
                ModelOption(value: "opus", label: "Opus — most capable"),
                ModelOption(value: "sonnet", label: "Sonnet — balanced"),
                ModelOption(value: "haiku", label: "Haiku — fastest"),
            ]
        case .codex:
            return [
                ModelOption(value: "", label: "Agent default (recommended)"),
                ModelOption(value: "gpt-5.1-codex", label: "GPT-5.1 Codex"),
                ModelOption(value: "gpt-5.1-codex-mini", label: "GPT-5.1 Codex Mini — faster"),
            ]
        case .gemini:
            return [
                ModelOption(value: "", label: "Agent default (recommended)"),
                ModelOption(value: "gemini-2.5-pro", label: "Gemini 2.5 Pro"),
                ModelOption(value: "gemini-2.5-flash", label: "Gemini 2.5 Flash — faster"),
            ]
        }
    }

    /// `… mcp add` arguments that register a remote (HTTP) MCP server at user scope,
    /// so it's available no matter which directory the agent runs from.
    func mcpAddArgs(name: String, url: String) -> [String] {
        switch self {
        case .claude: return ["mcp", "add", "--transport", "http", "--scope", "user", name, url]
        case .codex:  return ["mcp", "add", name, "--url", url]
        case .gemini: return ["mcp", "add", "-s", "user", "-t", "http", name, url]
        }
    }

    /// What the person still has to do once the server is registered.
    func mcpAuthHint(name: String) -> String {
        switch self {
        case .claude:
            return "Added. To sign in: open Terminal, run `claude`, type /mcp, choose “\(name)” and authenticate. After that the brief can use it."
        case .codex:
            return "Added. Open Terminal and run `codex` once — it asks you to sign in to “\(name)” the first time it's used."
        case .gemini:
            return "Added. Open Terminal and run `gemini` once, then type /mcp auth \(name) to sign in."
        }
    }
}

/// Well-known remote MCP servers, used to prefill the Connections form.
/// URLs are editable in the UI in case a vendor moves theirs.
struct KnownTool: Identifiable, Hashable {
    let name: String
    let url: String
    var id: String { name }

    static let catalog: [KnownTool] = [
        KnownTool(name: "linear", url: "https://mcp.linear.app/mcp"),
        KnownTool(name: "notion", url: "https://mcp.notion.com/mcp"),
        KnownTool(name: "asana", url: "https://mcp.asana.com/v2/mcp"),
        KnownTool(name: "atlassian", url: "https://mcp.atlassian.com/v1/mcp"),
        KnownTool(name: "github", url: "https://api.githubcopilot.com/mcp/"),
        KnownTool(name: "sentry", url: "https://mcp.sentry.dev/mcp"),
    ]
}

/// One server row from `claude mcp list`.
struct MCPServerStatus {
    enum State { case connected, needsAuth, failed, other }
    let name: String     // as configured, e.g. "claude.ai Linear" or "plugin:slack:slack"
    let state: State

    /// "claude.ai Linear" → "Linear", "plugin:slack:slack" → "Slack".
    var displayName: String {
        var n = name
        if n.hasPrefix("claude.ai ") { n = String(n.dropFirst("claude.ai ".count)) }
        if n.hasPrefix("plugin:"), let last = n.split(separator: ":").last { n = String(last) }
        if n == n.lowercased(), let first = n.first { n = first.uppercased() + n.dropFirst() }
        return n
    }
}

/// Reads Claude Code's own MCP health check. A headless `claude -p` run starts before claude.ai
/// connectors finish connecting, so asking the model which tools it has under-reports them.
enum MCPList {
    /// Parses lines like `claude.ai Linear: https://mcp.linear.app/mcp - ✔ Connected`.
    static func parse(_ output: String) -> [MCPServerStatus] {
        var servers: [MCPServerStatus] = []
        for line in output.split(separator: "\n").map(String.init) {
            guard let colon = line.range(of: ": "),
                  let dash = line.range(of: " - ", options: .backwards),
                  colon.upperBound <= dash.lowerBound else { continue }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let status = line[dash.upperBound...].lowercased()
            guard !name.isEmpty, !name.hasPrefix("[") else { continue }
            let state: MCPServerStatus.State
            if status.contains("failed") { state = .failed }
            else if status.contains("needs auth") { state = .needsAuth }
            else if status.contains("connected") { state = .connected }
            else { state = .other }
            servers.append(MCPServerStatus(name: name, state: state))
        }
        return servers
    }

    private static let roles: [(role: String, keywords: [String])] = [
        ("calendar", ["calendar", "cal.com", "outlook"]),
        ("chat", ["slack", "teams", "discord", "mattermost"]),
        ("email", ["gmail", "mail", "outlook"]),
        ("meeting notes", ["granola", "fireflies", "otter", "fathom", "tldv", "read.ai"]),
        ("task tracker or docs", ["linear", "notion", "jira", "atlassian", "confluence", "asana",
                                  "clickup", "github", "gitlab", "trello", "monday", "drive"]),
    ]

    /// One line per brief role, then anything that needs a sign-in or is broken.
    static func summary(_ servers: [MCPServerStatus]) -> String {
        let connected = servers.filter { $0.state == .connected }
        let connectedNames = Set(connected.map { $0.displayName.lowercased() })
        var lines: [String] = []
        for (role, keywords) in roles {
            var names: [String] = []
            for s in connected where keywords.contains(where: { s.name.lowercased().contains($0) }) {
                if !names.contains(s.displayName) { names.append(s.displayName) }
            }
            lines.append("\(role): " + (names.isEmpty ? "not connected" : names.joined(separator: ", ")))
        }
        var needsAuth: [String] = []
        for s in servers where s.state == .needsAuth && !connectedNames.contains(s.displayName.lowercased()) {
            if !needsAuth.contains(s.displayName) { needsAuth.append(s.displayName) }
        }
        if !needsAuth.isEmpty {
            lines.append("needs sign-in: \(needsAuth.joined(separator: ", ")) (open Terminal, run `claude`, type /mcp)")
        }
        let failed = servers.filter { $0.state == .failed }.map(\.name)
        if !failed.isEmpty {
            lines.append("not working: \(failed.joined(separator: ", ")) (check its URL, or remove it with `claude mcp remove <name>`)")
        }
        return lines.joined(separator: "\n")
    }
}

enum AgentDetector {
    /// Installed agents with their resolved binary paths, in preference order.
    static func detect(override: String, preferred: String) -> [(AgentKind, String)] {
        var found: [(AgentKind, String)] = []
        for k in AgentKind.allCases {
            let o = (preferred == k.rawValue) ? override : ""
            if let p = ShellEnv.find(k.binaryName, override: o) { found.append((k, p)) }
        }
        return found
    }
}
