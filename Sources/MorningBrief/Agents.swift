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

    enum Mode { case brief, probe }

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
