import AppKit
import Darwin

/// GUI apps don't inherit the user's shell PATH, so agent CLIs installed via npm, Homebrew,
/// nvm, bun etc. aren't visible. We ask the user's login shell once and cache the answer.
enum ShellEnv {
    private static var cachedPATH: String?
    /// Detection runs on detached tasks that can overlap; serialize access to the cache.
    private static let lock = NSLock()

    static var userShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var extraDirs: [String] {
        [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    /// PATH from an interactive login shell (so .zshrc/.zprofile are honoured), plus common install dirs.
    static func path() -> String {
        lock.lock(); defer { lock.unlock() }
        if let p = cachedPATH { return p }
        var dirs: [String] = []
        let marker = "__MB_PATH__"
        let shell = userShell
        // fish keeps PATH as a list, so join it explicitly there.
        let script = shell.hasSuffix("/fish")
            ? "printf '\(marker)%s\(marker)' (string join : $PATH)"
            : "printf '\(marker)%s\(marker)' \"$PATH\""
        let out = runSync(executable: shell, args: ["-lic", script], timeout: 8)
        if let r = out.range(of: marker), let r2 = out.range(of: marker, range: r.upperBound..<out.endIndex) {
            dirs = out[r.upperBound..<r2.lowerBound].split(separator: ":").map(String.init)
        }
        for d in extraDirs where !dirs.contains(d) { dirs.append(d) }
        let p = dirs.joined(separator: ":")
        cachedPATH = p
        return p
    }

    static func resetCache() { lock.lock(); cachedPATH = nil; lock.unlock() }

    static func find(_ name: String, override: String = "") -> String? {
        let fm = FileManager.default
        let o = (override as NSString).expandingTildeInPath
        if !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }
        for dir in path().split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return bundled(name)
    }

    /// CLIs that ship inside a desktop app instead of on PATH, found by the app's bundle ID so
    /// a renamed or moved app still works: (bundle ID, path inside the .app).
    private static let bundledCLIs: [String: [(String, String)]] = [
        // The Codex desktop app (ChatGPT.app on disk) carries its own `codex`.
        "codex": [("com.openai.codex", "Contents/Resources/codex-cli/bin/codex")],
    ]

    private static func bundled(_ name: String) -> String? {
        for (bundleID, inner) in bundledCLIs[name] ?? [] {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let candidate = app.appendingPathComponent(inner).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path()
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    /// Small synchronous helper used only for the PATH probe. Output goes to a temp file, not a pipe,
    /// because an interactive shell may leave background helpers holding a pipe open.
    private static func runSync(executable: String, args: [String], timeout: TimeInterval) -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb-path-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let handle = try? FileHandle(forWritingTo: tmp) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { try? handle.close(); return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        try? handle.close()
        return (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    }
}

struct RunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let logURL: URL
}

/// Runs a CLI with stdout/stderr redirected to files (not pipes): agents spawn MCP servers that can
/// keep inherited pipes open after the parent exits, which would hang a pipe reader forever.
enum ProcessRunner {
    static func run(executable: String,
                    args: [String],
                    cwd: URL,
                    timeout: TimeInterval,
                    logName: String) async throws -> RunResult {
        Paths.ensure()
        let outURL = Paths.logs.appendingPathComponent("\(logName).stdout.txt")
        let errURL = Paths.logs.appendingPathComponent("\(logName).stderr.txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = ShellEnv.environment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outHandle
        p.standardError = errHandle

        let timedOut = TimeoutFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: BriefError.agentFailed("Couldn't start \(executable): \(error.localizedDescription)"))
                return
            }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                timedOut.set()
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if p.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        try? outHandle.close()
        try? errHandle.close()

        // Lossy decode: a killed process can leave a truncated multi-byte sequence at the end.
        let stdout = (try? Data(contentsOf: outURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return RunResult(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut.value, logURL: outURL)
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Minimal shell-style splitter for the "Extra arguments" field: handles '…', "…" and backslashes.
enum ArgSplitter {
    static func split(_ s: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var hasToken = false
        var quote: Character? = nil
        var escape = false
        for c in s {
            if escape { cur.append(c); escape = false; hasToken = true; continue }
            if c == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; hasToken = true; continue }
            if c == " " || c == "\t" || c == "\n" {
                if hasToken { args.append(cur); cur = ""; hasToken = false }
                continue
            }
            cur.append(c); hasToken = true
        }
        if hasToken { args.append(cur) }
        return args
    }
}
