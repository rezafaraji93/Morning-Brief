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
                refreshAgents()
            }
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var agents: [AgentKind: String] = [:]
    @Published private(set) var recent: [StoredBrief] = []
    @Published var probeResult: String = ""
    @Published private(set) var probing = false
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { applyLaunchAtLogin() }
    }

    private var timer: Timer?
    private let lastAttemptKey = "MorningBrief.lastAutoAttemptDay"

    private init() {
        settings = AppSettings.load()
        Paths.ensure()
        recent = BriefStore.recent()
    }

    // MARK: lifecycle

    func start() {
        refreshAgents()
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

    // MARK: agents

    func refreshAgents() {
        let override = settings.binaryOverride
        let preferred = settings.agent
        Task.detached {
            ShellEnv.resetCache()
            let found = AgentDetector.detect(override: override, preferred: preferred)
            await MainActor.run {
                var map: [AgentKind: String] = [:]
                for (k, p) in found { map[k] = p }
                AppState.shared.agents = map
            }
        }
    }

    /// The agent to use: the one chosen in Settings, or the first installed (Claude, Codex, Gemini).
    func resolvedAgent() -> (AgentKind, String)? {
        if let k = AgentKind(rawValue: settings.agent) {
            if let p = agents[k] { return (k, p) }
            return nil
        }
        for k in AgentKind.allCases { if let p = agents[k] { return (k, p) } }
        return nil
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
        var day = Date()
        for _ in 0..<8 {
            if isRunDay(day), let t = scheduledTime(on: day),
               t > Date() || (cal.isDateInToday(day) && todayBrief == nil
                              && UserDefaults.standard.string(forKey: lastAttemptKey) != BriefStore.dayKey()) {
                let f = DateFormatter()
                f.timeStyle = .short
                f.dateStyle = .none
                let time = f.string(from: t)
                if cal.isDateInToday(day) { return t > Date() ? "today at \(time)" : "soon" }
                if cal.isDateInTomorrow(day) { return "tomorrow at \(time)" }
                let w = DateFormatter()
                w.dateFormat = "EEEE"
                return "\(w.string(from: day)) at \(time)"
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
              !BriefStore.exists(day: today),
              UserDefaults.standard.string(forKey: lastAttemptKey) != today
        else { return }
        UserDefaults.standard.set(today, forKey: lastAttemptKey)
        Task { await generate(manual: false) }
    }

    // MARK: generation

    func generate(manual: Bool) async {
        guard !isRunning else { return }
        if agents.isEmpty {
            // First launch: detection may still be running.
            let override = settings.binaryOverride, preferred = settings.agent
            let found = await Task.detached { AgentDetector.detect(override: override, preferred: preferred) }.value
            var map: [AgentKind: String] = [:]
            for (k, p) in found { map[k] = p }
            agents = map
            // Another generate() may have started while we were awaiting detection.
            guard !isRunning else { return }
        }
        guard let resolved = resolvedAgent() else {
            fail(BriefError.noAgent.localizedDescription, notify: !manual)
            return
        }
        let (kind, binary) = resolved
        status = .running(agent: kind.displayName, since: Date())
        let snapshot = settings
        let day = BriefStore.dayKey()
        do {
            let prompt = try PromptBuilder.build(settings: snapshot)
            let runner = AgentRunner(kind: kind, binary: binary, settings: snapshot)
            let text = try await runAgent(runner, prompt: prompt, mode: .brief, logName: "\(day)-\(kind.rawValue)")
            let brief = try JSONExtract.brief(from: text)
            let rendered = try BriefRenderer.render(brief, buttons: snapshot.includeButtons)
            let url = try BriefStore.save(html: rendered.html, json: rendered.json, day: day)
            recent = BriefStore.recent()
            status = .idle
            notifyReady(brief: brief, url: url)
            if manual { WindowManager.shared.showBrief(url: url) }
        } catch {
            fail(error.localizedDescription, notify: !manual)
        }
    }

    func probeConnections() async {
        guard !probing else { return }
        guard let resolved = resolvedAgent() else {
            probeResult = BriefError.noAgent.localizedDescription
            return
        }
        let (kind, binary) = resolved
        probing = true
        probeResult = "Asking \(kind.displayName)…"
        defer { probing = false }
        do {
            let runner = AgentRunner(kind: kind, binary: binary, settings: settings)
            let text = try await runAgent(runner, prompt: PromptBuilder.probe, mode: .probe,
                                          logName: "probe-\(kind.rawValue)", timeout: 180)
            probeResult = "\(kind.displayName):\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            probeResult = error.localizedDescription
        }
    }

    private func runAgent(_ runner: AgentRunner, prompt: String, mode: AgentRunner.Mode,
                          logName: String, timeout: TimeInterval? = nil) async throws -> String {
        let limit = timeout ?? TimeInterval(max(2, settings.timeoutMinutes) * 60)
        var inv = try runner.invocation(prompt: prompt, mode: mode)
        var result = try await ProcessRunner.run(executable: runner.binary, args: inv.args, cwd: Paths.work,
                                                 timeout: limit, logName: logName)
        // Older Claude Code builds or some plans don't offer the "auto" permission mode.
        if runner.kind == .claude, result.status != 0, !result.timedOut,
           result.stderr.localizedCaseInsensitiveContains("permission-mode") ||
           result.stderr.localizedCaseInsensitiveContains("permission mode") {
            inv = try runner.invocation(prompt: prompt, mode: mode, claudePermissionMode: "bypassPermissions")
            result = try await ProcessRunner.run(executable: runner.binary, args: inv.args, cwd: Paths.work,
                                                 timeout: limit, logName: logName + "-retry")
        }
        if result.timedOut { throw BriefError.timedOut(Int(limit / 60)) }
        if let err = runner.reportedError(stdout: result.stdout) { throw BriefError.agentFailed(err) }
        let text = runner.finalText(stdout: result.stdout, outputFile: inv.outputFile)
        if result.status != 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw BriefError.agentFailed("\(runner.kind.displayName) exited with code \(result.status). \(tail)")
        }
        return text
    }

    private func fail(_ message: String, notify: Bool) {
        status = .failed(message)
        if notify {
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
