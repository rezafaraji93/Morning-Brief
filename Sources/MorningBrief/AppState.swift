import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle
        case running(agent: String, since: Date)
        case failed(String)
    }

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.binaryOverride != oldValue.binaryOverride || settings.agent != oldValue.agent {
                // Results from the previous agent would read as if they were this one's.
                probeResult = ""
                connectStatus = ""
                invalidateServers()
                scheduleAgentRefresh()
            }
        }
    }
    @Published private(set) var status: Status = .idle
    /// What the agent is doing while a brief is being written, from its live output.
    @Published private(set) var progress: RunProgress?
    @Published private(set) var agents: [AgentKind: String] = [:]
    /// False until the first detection has finished, so an empty `agents` isn't shown as "none installed" too early.
    @Published private(set) var agentsChecked = false
    @Published private(set) var recent: [StoredBrief] = []
    @Published var probeResult: String = ""
    @Published private(set) var probing = false
    @Published var personalizeStatus: String = ""
    @Published private(set) var personalizing = false
    @Published var connectStatus: String = ""
    @Published private(set) var connecting = false
    @Published var detectNotice: Notice?
    @Published var channelsNotice: Notice?
    @Published private(set) var suggestingChannels = false
    /// The active agent's MCP servers from its last check, so Settings can hide tools already connected.
    @Published private(set) var servers: [MCPServerStatus] = []
    @Published private(set) var detecting = false
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { applyLaunchAtLogin() }
    }

    private var timer: Timer?
    private let lastAttemptKey = "MorningBrief.lastAutoAttemptDay"
    private let prefillAttemptedKey = "MorningBrief.prefillAttempted"

    /// Detection runs off the main thread; a result is dropped when a newer detection has started.
    private var detectGeneration = 0
    private var pendingRefresh: Task<Void, Never>?
    /// When `servers` was last read from the agent, so Settings doesn't re-run the check on every open.
    private var serversFetchedAt: Date?

    /// A scheduled run that failed gets another go, so a Mac that woke before Wi-Fi did doesn't lose the day.
    private struct AutoRetry { let day: String; var failures: Int; var after: Date }
    private var autoRetry: AutoRetry?
    private static let maxAutoAttempts = 3
    private static let retryDelay: TimeInterval = 30 * 60

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private init() {
        settings = AppSettings.load()
        Paths.ensure()
        recent = BriefStore.recent()
    }

    // MARK: lifecycle

    func start() {
        refreshAgents()
        Task.detached(priority: .background) { Paths.prune() }
        if AppState.notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let t = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppState.shared.checkSchedule() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Give Wi-Fi a moment to come back before calling out to connectors.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                Task { @MainActor in AppState.shared.checkSchedule() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            Task { @MainActor in AppState.shared.checkSchedule() }
        }

        // First launch with an agent installed: quietly ask it what it already knows about
        // the user, so About/Sections start out filled instead of empty. One attempt, ever.
        if !UserDefaults.standard.bool(forKey: prefillAttemptedKey),
           settings.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                Task { @MainActor in
                    let s = AppState.shared
                    guard !UserDefaults.standard.bool(forKey: s.prefillAttemptedKey) else { return }
                    UserDefaults.standard.set(true, forKey: s.prefillAttemptedKey)
                    await s.personalize(overwrite: false)
                }
            }
        }
    }

    var isRunning: Bool { if case .running = status { return true }; return false }

    var todayBrief: StoredBrief? {
        let day = BriefStore.dayKey()
        return recent.first { $0.day == day }
    }

    var menuIcon: String {
        switch status {
        case .running: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "sun.horizon"
        }
    }

    var statusLine: String {
        switch status {
        case .running(let agent, let since):
            let mins = Int(Date().timeIntervalSince(since) / 60)
            return mins < 1 ? "Writing your brief with \(agent)…" : "Writing your brief with \(agent)… \(mins)m"
        case .failed(let msg):
            return "Last run failed: \(msg)"
        case .idle:
            if todayBrief != nil { return "Today's brief is ready" }
            return "Next brief \(nextRunDescription())"
        }
    }

    /// The failure banner was closed: back to idle until the next run says otherwise.
    func dismissFailure() {
        if case .failed = status { status = .idle }
    }

    // MARK: agents

    /// Full detection at launch, including a fresh read of the login shell's PATH.
    func refreshAgents() {
        Task { await detectAgents(resetPath: true) }
    }

    /// Coalesces quick successive edits (typing a program path) into one detection, without
    /// re-reading PATH: that only changes when something gets installed.
    private func scheduleAgentRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.detectAgents(resetPath: false)
        }
    }

    @discardableResult
    private func detectAgents(resetPath: Bool) async -> [AgentKind: String] {
        detectGeneration += 1
        let generation = detectGeneration
        let override = settings.binaryOverride, preferred = settings.agent
        let found = await Task.detached(priority: .userInitiated) { () -> [(AgentKind, String)] in
            if resetPath { ShellEnv.resetCache() }
            return AgentDetector.detect(override: override, preferred: preferred)
        }.value
        var map: [AgentKind: String] = [:]
        for (k, p) in found { map[k] = p }
        if generation == detectGeneration {
            if map != agents {
                agents = map
                invalidateServers()
            }
            agentsChecked = true
        }
        return map
    }

    /// "Re-detect agents" in Settings: runs detection again and says what changed.
    func redetectAgents() async {
        guard !detecting else { return }
        detecting = true
        detectNotice = nil
        defer { detecting = false }
        let before = agents
        let after = await detectAgents(resetPath: true)
        detectNotice = Self.detectionNotice(before: before, after: after)
    }

    nonisolated static func detectionNotice(before: [AgentKind: String], after: [AgentKind: String]) -> Notice {
        func names(_ kinds: [AgentKind]) -> String {
            let n = kinds.map(\.displayName)
            return n.count < 2 ? n.joined() : n.dropLast().joined(separator: ", ") + " and " + n.last!
        }
        let all = AgentKind.allCases
        let added = all.filter { after[$0] != nil && before[$0] == nil }
        let lost = all.filter { before[$0] != nil && after[$0] == nil }
        let moved = all.filter { before[$0] != nil && after[$0] != nil && before[$0] != after[$0] }
        let installed = all.filter { after[$0] != nil }

        if after.isEmpty {
            return Notice(tone: .warning, text: "No agents found. Install Claude Code or Codex, or set the program path above.")
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Found \(names(added)).") }
        if !moved.isEmpty { parts.append("\(names(moved)) moved; using the new location.") }
        if !lost.isEmpty { parts.append("\(names(lost)) \(lost.count == 1 ? "is" : "are") no longer installed.") }
        if parts.isEmpty {
            if installed.count == all.count {
                return Notice(tone: .success, text: "All agents are already found: \(names(installed)).")
            }
            return Notice(tone: .info, text: "Nothing new found. Installed: \(names(installed)).")
        }
        if installed.count == all.count, !added.isEmpty { parts.append("All agents are now found.") }
        return Notice(tone: lost.isEmpty ? .success : .warning, text: parts.joined(separator: " "))
    }

    /// The agent to use: the one chosen in Settings, or the first installed (Claude, then Codex).
    /// With several agents installed, this picks one on its own — the user never has to.
    func resolvedAgent() -> (AgentKind, String)? {
        if let k = AgentKind(rawValue: settings.agent) {
            if let p = agents[k] { return (k, p) }
            return nil
        }
        for k in AgentKind.allCases { if let p = agents[k] { return (k, p) } }
        return nil
    }

    /// For the Settings UI: which agent "Automatic" currently means.
    var resolvedAgentLabel: String {
        if let (k, _) = resolvedAgent() { return k.displayName }
        return agents.isEmpty ? "no agent found" : "none"
    }

    /// Waits for first-launch agent detection if it hasn't finished yet.
    private func ensureAgentsDetected() async {
        guard agents.isEmpty else { return }
        await detectAgents(resetPath: false)
    }

    // MARK: schedule

    func scheduledTime(on day: Date) -> Date? {
        Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: day)
    }

    func isRunDay(_ date: Date) -> Bool {
        !settings.weekdaysOnly || !Calendar.current.isDateInWeekend(date)
    }

    func nextRunDescription() -> String {
        let cal = Calendar.current
        let today = BriefStore.dayKey()
        if todayBrief == nil, let r = autoRetry, r.day == today {
            return "today at \(Self.clock.string(from: r.after))"
        }
        var day = Date()
        for _ in 0..<8 {
            if isRunDay(day), let t = scheduledTime(on: day),
               t > Date() || (cal.isDateInToday(day) && todayBrief == nil
                              && UserDefaults.standard.string(forKey: lastAttemptKey) != today) {
                let time = Self.clock.string(from: t)
                if cal.isDateInToday(day) { return t > Date() ? "today at \(time)" : "soon" }
                if cal.isDateInTomorrow(day) { return "tomorrow at \(time)" }
                return "\(Self.weekday.string(from: day)) at \(time)"
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return "not scheduled"
    }

    func checkSchedule() {
        let now = Date()
        let today = BriefStore.dayKey(now)
        guard !isRunning,
              isRunDay(now),
              let t = scheduledTime(on: now), now >= t,
              !BriefStore.exists(day: today)
        else { return }
        let attempted = UserDefaults.standard.string(forKey: lastAttemptKey) == today
        let retryDue = autoRetry.map { $0.day == today && now >= $0.after } ?? false
        guard !attempted || retryDue else { return }
        UserDefaults.standard.set(today, forKey: lastAttemptKey)
        Task { await generate(manual: false) }
    }

    // MARK: generation

    func generate(manual: Bool) async {
        guard !isRunning else { return }
        await ensureAgentsDetected()
        // Another generate() may have started while we were awaiting detection.
        guard !isRunning else { return }
        let day = BriefStore.dayKey()
        guard let resolved = resolvedAgent() else {
            handleFailure(BriefError.noAgent.localizedDescription, manual: manual, day: day)
            return
        }
        let (kind, binary) = resolved
        status = .running(agent: kind.displayName, since: Date())
        progress = RunProgress(copy: ProgressCopy.started(kind.displayName))
        defer { progress = nil }
        let snapshot = settings
        do {
            let prompt = try PromptBuilder.build(settings: snapshot)
            let runner = AgentRunner(kind: kind, binary: binary, settings: snapshot)
            let out = try await runAgent(runner, prompt: prompt, mode: .brief, logName: "\(day)-\(kind.rawValue)",
                                         onLine: { stream, line in
                guard let event = runner.event(stream: stream, line: line) else { return }
                Task { @MainActor in AppState.shared.note(event) }
            })
            // Items the user already ticked off in an earlier brief don't come back.
            let brief = DoneStore.strip(try JSONExtract.brief(from: out.text))
            let rendered = try BriefRenderer.render(brief)
            let usage = runner.usage(stdout: out.stdout, stderr: out.stderr, seconds: out.seconds,
                                     toolCalls: progress?.toolCalls ?? 0)
            let url = try BriefStore.save(html: rendered.html, json: rendered.json, usage: usage, day: day)
            recent = BriefStore.recent()
            status = .idle
            autoRetry = nil
            notifyReady(brief: brief, url: url)
        } catch {
            handleFailure(error.localizedDescription, manual: manual, day: day)
        }
    }

    private func note(_ event: AgentEvent) {
        guard var p = progress else { return }
        switch event {
        case .started: break
        case .tool(let name):
            p.toolCalls += 1
            p.copy = ProgressCopy.line(forTool: name, index: p.toolCalls)
        case .thinking: p.copy = ProgressCopy.thinking(index: p.toolCalls)
        case .writing: p.copy = ProgressCopy.writing
        }
        progress = p
    }

    func probeConnections() async {
        guard !probing else { return }
        await ensureAgentsDetected()
        guard let resolved = resolvedAgent() else {
            probeResult = BriefError.noAgent.localizedDescription
            return
        }
        let (kind, binary) = resolved
        probing = true
        probeResult = "Asking \(kind.displayName)…"
        defer { probing = false }
        if let found = await configuredServers(kind: kind, binary: binary) {
            setServers(found)
            probeResult = "\(kind.displayName):\n" + MCPList.summary(found, kind: kind)
            return
        }
        do {
            let runner = AgentRunner(kind: kind, binary: binary, settings: settings)
            let out = try await runAgent(runner, prompt: PromptBuilder.probe, mode: .probe,
                                         logName: "probe-\(kind.rawValue)", timeout: 180)
            let found = MCPList.servers(fromToolNames: out.text)
            setServers(found)
            probeResult = "\(kind.displayName):\n" + MCPList.summary(found, kind: kind)
        } catch {
            probeResult = error.localizedDescription
        }
    }

    private struct ChannelSuggestion: Decodable {
        struct Channel: Decodable { var channel: String; var why: String? }
        var channels: [Channel]
        var note: String?
    }

    /// "Suggest from Slack": the agent looks at the user's Slack activity (read-only) and proposes channels
    /// to watch. New ones are added to the list; nothing already there is removed.
    func suggestChannels() async {
        guard !suggestingChannels else { return }
        await ensureAgentsDetected()
        guard let (kind, binary) = resolvedAgent() else {
            channelsNotice = Notice(tone: .warning, text: BriefError.noAgent.localizedDescription)
            return
        }
        suggestingChannels = true
        channelsNotice = nil
        defer { suggestingChannels = false }
        do {
            let runner = AgentRunner(kind: kind, binary: binary, settings: settings)
            let out = try await runAgent(runner, prompt: PromptBuilder.suggestChannels(settings: settings),
                                         mode: .channels, logName: "channels-\(kind.rawValue)", timeout: 420)
            guard let found = JSONExtract.objects(in: out.text).lazy.compactMap({
                $0.data(using: .utf8).flatMap { try? JSONDecoder().decode(ChannelSuggestion.self, from: $0) }
            }).first else {
                channelsNotice = Notice(tone: .warning, text: "\(kind.displayName) didn't return a usable list. Try again, or type the channels in.")
                return
            }
            let added = Self.merge(found.channels.map(\.channel), into: &settings.watchChannels)
            if found.channels.isEmpty {
                let reason = found.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                channelsNotice = Notice(tone: .warning, text: reason.isEmpty
                    ? "\(kind.displayName) couldn't find any channels. Is Slack connected? Check under Connections."
                    : reason)
            } else if added.isEmpty {
                channelsNotice = Notice(tone: .info, text: "Nothing new. Your list already has the channels \(kind.displayName) found.")
            } else {
                channelsNotice = Notice(tone: .success, text: "Added from your Slack: \(added.joined(separator: ", ")). Remove any that don't matter to you.")
            }
        } catch {
            channelsNotice = Notice(tone: .warning, text: error.localizedDescription)
        }
    }

    /// Appends channels not already in the comma-separated list; returns the ones added.
    private static func merge(_ channels: [String], into list: inout String) -> [String] {
        let existing = Set(AppSettings.channelList(list).map { $0.lowercased() })
        let added = AppSettings.channelList(channels.joined(separator: ","))
            .filter { !existing.contains($0.lowercased()) }
        if !added.isEmpty {
            list = (AppSettings.channelList(list) + added).joined(separator: ", ")
        }
        return added
    }

    private struct Personalization: Decodable {
        var name: String?
        var about: String?
    }

    /// Asks the active agent what it already knows about the user (from its own memory and
    /// instruction files; it is told to call no tools) and fills in the name and About you.
    /// With overwrite=false only empty fields are touched.
    func personalize(overwrite: Bool) async {
        guard !personalizing else { return }
        await ensureAgentsDetected()
        guard let resolved = resolvedAgent() else {
            personalizeStatus = BriefError.noAgent.localizedDescription
            return
        }
        let (kind, binary) = resolved
        personalizing = true
        personalizeStatus = "Asking \(kind.displayName) what it knows about you…"
        defer { personalizing = false }
        do {
            let runner = AgentRunner(kind: kind, binary: binary, settings: settings)
            let out = try await runAgent(runner, prompt: PromptBuilder.personalize, mode: .personalize,
                                         logName: "personalize-\(kind.rawValue)", timeout: 180)
            var parsed: Personalization?
            for candidate in JSONExtract.objects(in: out.text) {
                if let d = candidate.data(using: .utf8),
                   let p = try? JSONDecoder().decode(Personalization.self, from: d) {
                    parsed = p
                    break
                }
            }
            guard let p = parsed else {
                personalizeStatus = "\(kind.displayName) didn't return anything usable."
                return
            }
            var filled: [String] = []
            if let n = p.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty,
               settings.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.name = n
                filled.append("name")
            }
            if let a = p.about?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty,
               overwrite || settings.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.about = a
                filled.append("about you")
            }
            personalizeStatus = filled.isEmpty
                ? "\(kind.displayName) had nothing new to add. You can edit the fields by hand."
                : "Filled from \(kind.displayName)'s memory: \(filled.joined(separator: ", ")). Edit anything that's off."
        } catch {
            personalizeStatus = error.localizedDescription
        }
    }

    /// Registers a remote MCP server with the active agent (`<agent> mcp add …`, user scope).
    func connectTool(name: String, url: String) async {
        guard !connecting else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // The name becomes a config key and part of a log file name, so keep it plain.
        let plainName = name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
        guard plainName, url.lowercased().hasPrefix("https://") else {
            connectStatus = "A connection needs a short name (lowercase letters, numbers, - or _) and an https:// URL."
            return
        }
        await ensureAgentsDetected()
        guard let resolved = resolvedAgent() else {
            connectStatus = BriefError.noAgent.localizedDescription
            return
        }
        let (kind, binary) = resolved
        connecting = true
        connectStatus = kind == .codex
            ? "Adding “\(name)” to Codex… if a browser window opens, sign in there."
            : "Adding “\(name)” to \(kind.displayName)…"
        defer { connecting = false }
        if let found = await configuredServers(kind: kind, binary: binary) {
            setServers(found)
            let known = KnownTool.catalog.first { $0.name == name }
            if let hit = known?.connectedServer(in: found)
                ?? found.first(where: { $0.state == .connected && $0.displayName.lowercased() == name.lowercased() }) {
                connectStatus = "\(known?.title ?? hit.displayName) is already connected (as “\(hit.name)”). Nothing to add."
                return
            }
        }
        do {
            // Codex runs the OAuth sign-in inside `mcp add` and waits for the browser, so give it time.
            let addTimeout: TimeInterval = kind == .codex ? 300 : 60
            var result = try await ProcessRunner.run(executable: binary,
                                                     args: kind.mcpAddArgs(name: name, url: url),
                                                     cwd: Paths.work, timeout: addTimeout, logName: "mcp-add-\(name)")
            var replaced = false
            // Claude Code refuses to overwrite an entry with the same name; swap it for the new URL.
            if kind == .claude, result.status != 0, (result.stderr + result.stdout).contains("already exists") {
                _ = try await ProcessRunner.run(executable: binary, args: ["mcp", "remove", "--scope", "user", name],
                                                cwd: Paths.work, timeout: 60, logName: "mcp-remove-\(name)")
                result = try await ProcessRunner.run(executable: binary,
                                                     args: kind.mcpAddArgs(name: name, url: url),
                                                     cwd: Paths.work, timeout: 60, logName: "mcp-add-\(name)")
                replaced = true
            }
            if result.status == 0 { await refreshServers(maxAge: 0) }
            if result.status == 0, (result.stdout + result.stderr).contains("Successfully logged in") {
                connectStatus = "Added “\(name)” to \(kind.displayName) and signed in. The next brief can use it."
            } else if result.status == 0 {
                connectStatus = (replaced ? "Replaced the old “\(name)” entry. " : "") + kind.mcpAuthHint(name: name)
            } else {
                let tail = (result.stderr + result.stdout).split(separator: "\n").suffix(3).joined(separator: " ")
                connectStatus = "Couldn't add it (exit \(result.status)). \(tail)"
            }
        } catch {
            connectStatus = error.localizedDescription
        }
    }

    /// Re-reads the active agent's servers without asking a model (agents with a list command only),
    /// unless they were read less than `maxAge` ago.
    func refreshServers(maxAge: TimeInterval = 60) async {
        if let t = serversFetchedAt, Date().timeIntervalSince(t) < maxAge { return }
        await ensureAgentsDetected()
        guard let (kind, binary) = resolvedAgent(),
              let found = await configuredServers(kind: kind, binary: binary) else { return }
        setServers(found)
    }

    private func setServers(_ found: [MCPServerStatus]) {
        servers = found
        serversFetchedAt = Date()
    }

    private func invalidateServers() {
        servers = []
        serversFetchedAt = nil
    }

    /// The agent's own list of MCP servers and their state (`claude mcp list`, `codex mcp list --json`).
    /// nil when the agent has no such command or it fails; the caller then asks the model.
    private func configuredServers(kind: AgentKind, binary: String) async -> [MCPServerStatus]? {
        let args: [String]
        switch kind {
        case .claude: args = ["mcp", "list"]
        case .codex: args = ["mcp", "list", "--json"]
        }
        guard let r = try? await ProcessRunner.run(executable: binary, args: args,
                                                   cwd: Paths.work, timeout: 90, logName: "mcp-list-\(kind.rawValue)"),
              r.status == 0 else { return nil }
        if kind == .codex { return MCPList.parse(codexJSON: r.stdout) }
        let servers = MCPList.parse(r.stdout + "\n" + r.stderr)
        return servers.isEmpty ? nil : servers
    }

    struct AgentOutput {
        let text: String
        let stdout: String
        let stderr: String
        let seconds: Int
    }

    private func runAgent(_ runner: AgentRunner, prompt: String, mode: AgentRunner.Mode,
                          logName: String, timeout: TimeInterval? = nil,
                          onLine: (@Sendable (ProcessStream, String) -> Void)? = nil) async throws -> AgentOutput {
        let limit = timeout ?? TimeInterval(max(2, settings.timeoutMinutes) * 60)
        let started = Date()
        var inv = try runner.invocation(prompt: prompt, mode: mode)
        var result = try await ProcessRunner.run(executable: runner.binary, args: inv.args, cwd: Paths.work,
                                                 timeout: limit, logName: logName, onLine: onLine)
        // Older Claude Code builds or some plans don't offer the "auto" permission mode.
        if runner.kind == .claude, result.status != 0, !result.timedOut,
           result.stderr.localizedCaseInsensitiveContains("permission-mode") ||
           result.stderr.localizedCaseInsensitiveContains("permission mode") {
            inv = try runner.invocation(prompt: prompt, mode: mode, claudePermissionMode: "bypassPermissions")
            result = try await ProcessRunner.run(executable: runner.binary, args: inv.args, cwd: Paths.work,
                                                 timeout: limit, logName: logName + "-retry", onLine: onLine)
        }
        if result.timedOut { throw BriefError.timedOut(Int(limit / 60)) }
        if let err = runner.reportedError(stdout: result.stdout) { throw BriefError.agentFailed(err) }
        let text = runner.finalText(stdout: result.stdout, outputFile: inv.outputFile)
        if result.status != 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw BriefError.agentFailed("\(runner.kind.displayName) exited with code \(result.status). \(tail)")
        }
        return AgentOutput(text: text, stdout: result.stdout, stderr: result.stderr,
                           seconds: Int(Date().timeIntervalSince(started)))
    }

    /// A manual run just reports. A scheduled run gets two more tries half an hour apart, and the
    /// notification goes out only when the last one has failed too.
    private func handleFailure(_ message: String, manual: Bool, day: String) {
        guard !manual else { status = .failed(message); return }
        var retry = autoRetry?.day == day ? autoRetry! : AutoRetry(day: day, failures: 0, after: .distantPast)
        retry.failures += 1
        if retry.failures < Self.maxAutoAttempts {
            retry.after = Date().addingTimeInterval(Self.retryDelay)
            autoRetry = retry
            status = .failed("\(message) Trying again at \(Self.clock.string(from: retry.after)).")
        } else {
            autoRetry = nil
            status = .failed(message)
            post(title: "Morning brief didn't run", body: message, path: nil)
        }
    }

    // MARK: notifications

    private func notifyReady(brief: Brief, url: URL) {
        let count = brief.needsAttention?.count ?? 0
        let body: String
        switch count {
        case 0: body = brief.headline
        case 1: body = "1 thing needs you. " + brief.headline
        default: body = "\(count) things need you. " + brief.headline
        }
        post(title: "Your morning brief is ready", body: body, path: url.path)
    }

    /// UNUserNotificationCenter needs a real app bundle; `swift run` builds don't have one.
    static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func post(title: String, body: String, path: String?) {
        guard AppState.notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let path { content.userInfo = ["path": path] }
        let req = UNNotificationRequest(identifier: "morning-brief-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    // MARK: misc

    func reloadRecent() { recent = BriefStore.recent() }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // Don't clobber .running: that would let a second generate() start alongside it.
            if !isRunning { status = .failed("Couldn't change Launch at Login: \(error.localizedDescription)") }
        }
    }
}
