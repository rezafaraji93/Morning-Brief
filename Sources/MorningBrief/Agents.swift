import Foundation

/// Builds the headless invocation for each agent CLI and pulls the final answer out of its output.
///
/// Safety model: the prompt forbids any write action, and each agent is started in its most
/// restrictive mode that still lets it call read tools on MCP connectors:
///  - Claude Code: `--permission-mode auto` with the shell, file-editing, subagent, search and web
///    tools disallowed, plus every connector tool that writes (see connectorWriteTools).
///  - Codex: `--sandbox read-only`.
/// Users can override or extend flags with "Extra arguments" in Settings.
struct AgentRunner {
    let kind: AgentKind
    let binary: String
    let settings: AppSettings

    enum Mode { case brief, probe, personalize, channels }

    /// The JSON schema an answer in this mode must match, if any.
    private static func schemaName(_ mode: Mode) -> String? {
        switch mode {
        case .brief: return "brief.schema"
        case .personalize: return "personalize.schema"
        case .channels: return "channels.schema"
        case .probe: return nil
        }
    }

    struct Invocation {
        let args: [String]
        let outputFile: URL?
    }

    /// The connectors' tools that change something, denied outright so "read-only" doesn't rest on
    /// the prompt alone. Each name is listed under the claude.ai connector's server name and under
    /// the plain name a server gets when added by hand (`claude mcp add slack …`).
    static let connectorWriteTools: [String] = {
        let servers: [(claudeAI: String, plain: [String], tools: [String])] = [
            ("claude_ai_Slack", ["slack"],
             ["slack_send_message", "slack_send_message_draft", "slack_schedule_message", "slack_add_reaction",
              "slack_create_canvas", "slack_update_canvas", "slack_create_conversation"]),
            ("claude_ai_Google_Calendar", ["google-calendar", "google_calendar", "calendar"],
             ["create_event", "update_event", "delete_event", "respond_to_event"]),
            ("claude_ai_Gmail", ["gmail"],
             ["send_message", "reply", "forward", "create_draft", "update_draft", "delete_draft",
              "trash_message", "trash_thread", "untrash_message", "untrash_thread",
              "label_message", "label_thread", "unlabel_message", "unlabel_thread", "update_message_labels",
              "create_label", "update_label", "delete_label", "mark_message_spam", "mark_thread_spam",
              "unmark_message_spam", "unmark_thread_spam", "apply_sensitive_message_label", "apply_sensitive_thread_label"]),
            ("claude_ai_Granola", ["granola"],
             ["create_folder", "update_folder", "add_note_to_folder", "remove_note_from_folder", "sign_out"]),
            ("claude_ai_Linear", ["linear"],
             ["save_issue", "save_project", "save_initiative", "save_milestone", "save_release", "save_release_note",
              "save_status_update", "save_document", "save_comment", "save_diff_comment", "save_issue_label",
              "save_project_label", "save_initiative_label", "create_issue_label", "create_initiative_label",
              "create_attachment", "create_attachment_from_upload", "prepare_attachment_upload", "delete_attachment",
              "delete_comment", "delete_diff_comment", "delete_status_update", "merge_diff", "update_diff",
              "submit_diff_review", "resolve_diff_thread", "share_issue", "unshare_issue", "mark_notification",
              "retire_issue_label", "retire_project_label", "retire_initiative_label",
              "restore_issue_label", "restore_project_label", "restore_initiative_label"]),
            ("claude_ai_Notion", ["notion"],
             ["notion-create-pages", "notion-update-page", "notion-delete-pages", "notion-restore-pages",
              "notion-move-pages", "notion-duplicate-page", "notion-create-database", "notion-delete-databases",
              "notion-update-data-source", "notion-create-view", "notion-update-view", "notion-create-comment",
              "notion-update-comment", "notion-delete-comment", "notion-set-comment-reaction",
              "notion-set-discussion-resolved", "notion-create-folder", "notion-update-folder",
              "notion-create-attachment", "notion-create-file-upload", "notion-upload-skill",
              "notion-update-enabled-skills", "notion-convert-page-to-skill", "notion-spawn-session",
              "notion-stop-session", "notion-send-message-to-session", "notion-calendar-create-events",
              "notion-calendar-update-events", "notion-calendar-cancel-events"]),
        ]
        var names: [String] = []
        for server in servers {
            for tool in server.tools {
                names.append("mcp__\(server.claudeAI)__\(tool)")
                for plain in server.plain { names.append("mcp__\(plain)__\(tool)") }
            }
        }
        return names
    }()

    func invocation(prompt: String, mode: Mode, claudePermissionMode: String = "auto") throws -> Invocation {
        let model = kind.resolveModel(settings.model)
        let extra = ArgSplitter.split(settings.extraArgs)
        switch kind {
        case .claude:
            // A brief streams one JSON event per line, so the panel can show what's being read;
            // the final "result" event is the same envelope the plain json format prints.
            var a = ["-p", prompt, "--no-session-persistence"]
            a += mode == .brief ? ["--output-format", "stream-json", "--verbose"] : ["--output-format", "json"]
            if !extra.contains("--permission-mode") && !extra.contains("--dangerously-skip-permissions") {
                a += ["--permission-mode", claudePermissionMode]
            }
            // Read stays allowed: Claude Code spills large tool results to disk and reads them back.
            a += ["--disallowedTools", "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit",
                  "Agent", "Task", "Glob", "Grep", "WebFetch", "WebSearch"] + Self.connectorWriteTools
            if let schema = Self.schemaName(mode) {
                a += ["--json-schema", try Res.string(schema, "json")]
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
            if let name = Self.schemaName(mode), let schema = Res.url(name, "json") {
                a += ["--output-schema", schema.path]
            }
            if !model.isEmpty { a += ["-m", model] }
            return Invocation(args: a + extra + [prompt], outputFile: out)
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
        }
    }

    /// Error text the CLI reported inside its JSON envelope, if any.
    func reportedError(stdout: String) -> String? {
        guard let obj = jsonObject(stdout) else { return nil }
        if kind == .claude, (obj["is_error"] as? Bool) == true {
            return (obj["result"] as? String) ?? "Claude Code reported an error."
        }
        return nil
    }

    private func jsonObject(_ s: String) -> [String: Any]? {
        // The envelope is the "result" event. Streamed output is one object per line and can run to
        // megabytes, so walk whole lines from the end; Claude Code may print bookkeeping events
        // (task_summary) after the result, so keep looking a little past the last line.
        var fallback: [String: Any]?
        var checked = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), t.hasSuffix("}"), let d = t.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if o["type"] as? String == "result" { return o }
            if fallback == nil { fallback = o }
            checked += 1
            if checked >= 20 { break }
        }
        if let fallback { return fallback }
        for candidate in JSONExtract.objects(in: s).reversed() {
            if let d = candidate.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return o
            }
        }
        return nil
    }

    /// What one line of live output says the agent is doing, if anything.
    func event(stream: ProcessStream, line: String) -> AgentEvent? {
        switch kind {
        case .claude:
            // Only assistant and system events matter; tool results (type "user") can be huge, so
            // they're ruled out by their prefix before any parsing.
            let head = line.prefix(40)
            guard stream == .stdout, head.hasPrefix("{"),
                  head.contains("\"assistant\"") || head.contains("\"system\""),
                  let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            if o["type"] as? String == "system" {
                return o["subtype"] as? String == "init" ? .started : nil
            }
            guard let message = o["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            if let tool = content.first(where: { $0["type"] as? String == "tool_use" }),
               let name = tool["name"] as? String {
                return name == "StructuredOutput" ? .writing : .tool(name)
            }
            return content.contains { $0["type"] as? String == "text" } ? .thinking : nil
        case .codex:
            // "mcp: linear/get_user started"
            guard stream == .stderr, line.hasPrefix("mcp: "), line.hasSuffix(" started") else { return nil }
            return .tool(String(line.dropFirst(5).dropLast(8)))
        }
    }

    /// Tokens, cost and time for a finished run, as far as the CLI reports them.
    func usage(stdout: String, stderr: String, seconds: Int, toolCalls: Int) -> BriefUsage? {
        var u = BriefUsage(agent: kind.displayName, totalTokens: 0, durationSeconds: seconds, toolCalls: toolCalls)
        switch kind {
        case .claude:
            guard let o = jsonObject(stdout) else { return nil }
            var input = 0, output = 0, read = 0, write = 0, cost = 0.0, model: String?
            if let models = o["modelUsage"] as? [String: [String: Any]], !models.isEmpty {
                for (name, m) in models {
                    model = model ?? name
                    input += m["inputTokens"] as? Int ?? 0
                    output += m["outputTokens"] as? Int ?? 0
                    read += m["cacheReadInputTokens"] as? Int ?? 0
                    write += m["cacheCreationInputTokens"] as? Int ?? 0
                    cost += m["costUSD"] as? Double ?? 0
                }
            } else if let usage = o["usage"] as? [String: Any] {
                input = usage["input_tokens"] as? Int ?? 0
                output = usage["output_tokens"] as? Int ?? 0
                read = usage["cache_read_input_tokens"] as? Int ?? 0
                write = usage["cache_creation_input_tokens"] as? Int ?? 0
                cost = o["total_cost_usd"] as? Double ?? 0
            } else {
                return nil
            }
            u.model = model
            u.inputTokens = input
            u.outputTokens = output
            u.cacheReadTokens = read
            u.cacheWriteTokens = write
            u.costUSD = cost > 0 ? cost : nil
            u.totalTokens = input + output + read + write
            if let ms = o["duration_ms"] as? Int { u.durationSeconds = ms / 1000 }
            return u
        case .codex:
            // The run ends with "tokens used" and the number on the next line, grouped per the locale.
            let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let i = lines.lastIndex(of: "tokens used"), i + 1 < lines.count else { return nil }
            let digits = lines[i + 1].filter(\.isNumber)
            guard let n = Int(digits), n > 0 else { return nil }
            u.totalTokens = n
            u.model = settings.model.isEmpty ? nil : settings.model
            return u
        }
    }
}

/// A model choice offered in the Settings dropdown.
struct ModelOption: Identifiable, Hashable {
    let value: String
    let label: String
    /// One or two sentences on what picking it means, shown under the dropdown.
    let note: String
    var id: String { value }
}

extension AgentKind {
    /// Stored model value meaning "let the CLI pick": no model flag is passed.
    static let cliDefault = "default"

    /// The model a brief runs on when Settings holds "" (the app's recommendation).
    var recommendedModel: String { modelOptions[0].value }

    /// "" → the recommendation, "default" → nil (no flag), anything else as typed.
    func resolveModel(_ stored: String) -> String {
        let m = stored.trimmingCharacters(in: .whitespaces)
        if m.isEmpty { return recommendedModel }
        if m == Self.cliDefault { return "" }
        return m
    }

    /// Recommended first. Claude's notes come from timed runs of the same brief over eight Slack
    /// channels; Codex's rank OpenAI's own descriptions and haven't been measured here.
    var modelOptions: [ModelOption] {
        switch self {
        case .claude:
            return [
                ModelOption(value: "opus", label: "Opus — recommended",
                            note: "The full brief: what needs you, what got resolved, meeting commitments and nudges. About 4 minutes and $2 a day."),
                ModelOption(value: "sonnet", label: "Sonnet — fastest",
                            note: "Accurate on what needs you, but delivers less: it tends to skip the resolved items, meeting commitments and nudges. About 1½ minutes and 50¢."),
                ModelOption(value: "fable", label: "Fable — more than a brief needs",
                            note: "The same brief as Opus, in twice the time and at three times the cost."),
                ModelOption(value: "haiku", label: "Haiku — cheapest",
                            note: "Reads everything for about 10¢ and 2 minutes, but the details are thinner: it missed decisions inside threads and a due date that Opus found."),
                ModelOption(value: AgentKind.cliDefault, label: "Claude Code's own default",
                            note: "Whatever `claude` is set to, so it changes when you run /model there."),
            ]
        case .codex:
            return [
                ModelOption(value: "gpt-5.6-terra", label: "GPT-5.6 Terra — recommended",
                            note: "OpenAI's balanced model, the best bet for a full brief. Not measured here yet."),
                ModelOption(value: "gpt-6-luna", label: "GPT-6 Luna — fastest",
                            note: "Codex's default: fast and cheap, meant for easier tasks. Expect a thinner brief."),
                ModelOption(value: "gpt-5.6-luna", label: "GPT-5.6 Luna — older, fast",
                            note: "An older fast model. Not measured here."),
                ModelOption(value: AgentKind.cliDefault, label: "Codex's own default",
                            note: "Whatever `codex` is set to."),
            ]
        }
    }

    /// `… mcp add` arguments that register a remote (HTTP) MCP server at user scope,
    /// so it's available no matter which directory the agent runs from.
    func mcpAddArgs(name: String, url: String) -> [String] {
        switch self {
        case .claude: return ["mcp", "add", "--transport", "http", "--scope", "user", name, url]
        case .codex:  return ["mcp", "add", name, "--url", url]
        }
    }

    /// How to sign in to a registered server that still needs it.
    var signInHint: String {
        switch self {
        case .claude: return "open Terminal, run `claude`, type /mcp"
        case .codex: return "open Terminal and run `codex mcp login <name>`"
        }
    }

    /// What the person still has to do once the server is registered.
    func mcpAuthHint(name: String) -> String {
        switch self {
        case .claude:
            return "Added. To sign in: open Terminal, run `claude`, type /mcp, choose “\(name)” and authenticate. After that the brief can use it."
        case .codex:
            return "Added. If it didn't sign you in just now, open Terminal and run `codex mcp login \(name)`."
        }
    }
}

/// Well-known remote MCP servers for the Connections form, most-used first.
/// URLs are editable in the UI in case a vendor moves theirs.
struct KnownTool: Identifiable, Hashable {
    /// How a tool gets connected.
    enum Setup: Hashable {
        /// The agent registers the server and signs in through the browser.
        case signIn
        /// The vendor only lets approved apps sign in, so it's set up elsewhere.
        case approvedAppsOnly
        /// No browser sign-in; the server wants a personal access token.
        case token(createAt: String)
    }

    let name: String     // the agent's config name
    let title: String
    let url: String
    var setup: Setup = .signIn
    var id: String { name }

    static let catalog: [KnownTool] = [
        KnownTool(name: "google-calendar", title: "Google Calendar",
                  url: "https://calendarmcp.googleapis.com/mcp/v1", setup: .approvedAppsOnly),
        KnownTool(name: "slack", title: "Slack", url: "https://mcp.slack.com/mcp", setup: .approvedAppsOnly),
        KnownTool(name: "granola", title: "Granola", url: "https://mcp.granola.ai/mcp"),
        KnownTool(name: "linear", title: "Linear", url: "https://mcp.linear.app/mcp"),
        KnownTool(name: "notion", title: "Notion", url: "https://mcp.notion.com/mcp"),
        KnownTool(name: "github", title: "GitHub", url: "https://api.githubcopilot.com/mcp/",
                  setup: .token(createAt: "https://github.com/settings/personal-access-tokens")),
        KnownTool(name: "atlassian", title: "Atlassian (Jira, Confluence)", url: "https://mcp.atlassian.com/v1/mcp"),
        KnownTool(name: "asana", title: "Asana", url: "https://mcp.asana.com/v2/mcp"),
        KnownTool(name: "sentry", title: "Sentry", url: "https://mcp.sentry.dev/mcp"),
    ]

    /// The agent's connected server that already is this tool, e.g. "claude.ai Linear".
    func connectedServer(in servers: [MCPServerStatus]) -> MCPServerStatus? {
        let short = title.split(separator: " ").first.map { String($0).lowercased() } ?? name
        return servers.first { s in
            guard s.state == .connected else { return false }
            let display = s.displayName.lowercased()
            return s.name.lowercased() == name || display == title.lowercased() || display == short
        }
    }

    func isConnected(in servers: [MCPServerStatus]) -> Bool { connectedServer(in: servers) != nil }

    /// What to do instead of "Connect" when the tool can't be signed in to from here.
    func manualSteps(for kind: AgentKind) -> String? {
        switch setup {
        case .signIn:
            return nil
        case .approvedAppsOnly:
            switch kind {
            case .claude:
                return "\(title) only lets approved apps sign in, so it can't be added from here. Turn it on at claude.ai under Settings → Connectors; Claude Code picks it up automatically and it shows as connected here."
            case .codex:
                return "\(title) only lets approved apps sign in, so \(kind.displayName) can't add it from here. Claude Code can use it through claude.ai connectors (Settings → Connectors)."
            }
        case .token(let createAt):
            switch kind {
            case .claude:
                return "\(title) signs in with a personal access token instead of the browser. Create a read-only token at \(createAt), then run in Terminal:\nclaude mcp add --transport http --scope user \(name) \(url) --header \"Authorization: Bearer YOUR_TOKEN\""
            case .codex:
                return "\(title) signs in with a personal access token instead of the browser. Create a read-only token at \(createAt), then run in Terminal:\ncodex mcp add \(name) --url \(url) --bearer-token-env-var GITHUB_PAT\nCodex reads the token from GITHUB_PAT, so that variable has to be set where Codex runs."
            }
        }
    }
}

/// One server row from `claude mcp list`.
struct MCPServerStatus: Equatable {
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

    /// For agents without a health-check command: the model lists the tool names it can call and
    /// this maps them to roles, so the model never decides what counts as connected.
    static func servers(fromToolNames text: String) -> [MCPServerStatus] {
        var servers: [MCPServerStatus] = []
        for raw in text.split(separator: "\n") {
            let tool = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•`")).lowercased()
            // Tool names have no spaces; anything else is prose the model added.
            guard !tool.isEmpty, !tool.contains(" ") else { continue }
            let server = serverName(ofTool: tool)
            for (_, keywords) in roles {
                for k in keywords where tool.contains(k) {
                    // Prefer the server's own name ("google_calendar"); fall back to the keyword when
                    // the server is a generic bundle such as "codex_apps".
                    let name = pretty(server.contains(k) ? server : k)
                    if !servers.contains(where: { $0.name == name }) {
                        servers.append(MCPServerStatus(name: name, state: .connected))
                    }
                }
            }
        }
        return servers
    }

    /// "mcp__slack__search" → "slack", "linear.get_issue" → "linear".
    private static func serverName(ofTool tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let rest = tool.dropFirst("mcp__".count)
            return String(rest.components(separatedBy: "__").first ?? String(rest))
        }
        if let dot = tool.firstIndex(of: ".") { return String(tool[..<dot]) }
        return tool
    }

    private static func pretty(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Parses `codex mcp list --json`: each configured server with its sign-in state. Codex loads an
    /// MCP server's tools only when it needs them, so a model asked for its tools leaves them out.
    static func parse(codexJSON output: String) -> [MCPServerStatus]? {
        guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, (row["enabled"] as? Bool) != false else { return nil }
            let state: MCPServerStatus.State = (row["auth_status"] as? String) == "not_logged_in" ? .needsAuth : .connected
            return MCPServerStatus(name: name, state: state)
        }
    }

    /// One line per brief role, then anything that needs a sign-in or is broken.
    static func summary(_ servers: [MCPServerStatus], kind: AgentKind = .claude) -> String {
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
            lines.append("needs sign-in: \(needsAuth.joined(separator: ", ")) (\(kind.signInHint))")
        }
        // A broken leftover entry for a tool that works through another entry isn't worth flagging.
        let failed = servers.filter { $0.state == .failed && !connectedNames.contains($0.displayName.lowercased()) }.map(\.name)
        if !failed.isEmpty {
            lines.append("not working: \(failed.joined(separator: ", ")) (check its URL, or remove it with `\(kind.binaryName) mcp remove <name>`)")
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
