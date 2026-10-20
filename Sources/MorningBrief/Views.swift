import AppKit
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.statusLine)

        Divider()

        Button("Open Today's Brief") {
            if let b = state.todayBrief { WindowManager.shared.showBrief(url: b.htmlURL) }
        }
        .disabled(state.todayBrief == nil)
        .keyboardShortcut("o")

        Button(state.todayBrief == nil ? "Generate Now" : "Regenerate Today's Brief") {
            Task { await state.generate(manual: true) }
        }
        .disabled(state.isRunning)
        .keyboardShortcut("g")

        let past = state.recent.filter { $0.day != BriefStore.dayKey() }
        if !past.isEmpty {
            Menu("Earlier Briefs") {
                ForEach(past.prefix(7)) { b in
                    Button(b.displayName) { WindowManager.shared.showBrief(url: b.htmlURL) }
                }
            }
        }

        Divider()

        Button("Settings…") { WindowManager.shared.showSettings() }
            .keyboardShortcut(",")
        Button("Show Logs in Finder") {
            Paths.ensure()
            NSWorkspace.shared.activateFileViewerSelecting([Paths.logs])
        }

        Divider()

        Button("Quit Morning Brief") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var customModel = false
    @State private var newToolName = ""
    @State private var newToolURL = ""

    // MARK: derived bindings

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: state.settings.hour, minute: state.settings.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                state.settings.hour = c.hour ?? 8
                state.settings.minute = c.minute ?? 0
            }
        )
    }

    /// The agent whose model list we show: the explicit choice, or whatever Automatic resolved to.
    private var effectiveKind: AgentKind {
        if let k = AgentKind(rawValue: state.settings.agent) { return k }
        if let (k, _) = state.resolvedAgent() { return k }
        return .claude
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                if customModel { return "custom" }
                let m = state.settings.model
                if m.isEmpty { return "" }
                return effectiveKind.modelOptions.contains(where: { $0.value == m }) ? m : "custom"
            },
            set: { v in
                if v == "custom" {
                    customModel = true
                } else {
                    customModel = false
                    state.settings.model = v
                }
            }
        )
    }

    var body: some View {
        Form {
            agentSection
            scheduleSection
            briefSection
            connectionsSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 620)
        .onAppear {
            let m = state.settings.model
            customModel = !m.isEmpty && !effectiveKind.modelOptions.contains(where: { $0.value == m })
        }
    }

    // MARK: sections

    private var agentSection: some View {
        Section {
            Picker("Agent", selection: $state.settings.agent) {
                Text("Automatic — using \(state.resolvedAgentLabel)").tag("auto")
                ForEach(AgentKind.allCases) { k in
                    if state.agents[k] != nil {
                        Text(k.displayName).tag(k.rawValue)
                    }
                }
            }

            Picker("Model", selection: modelSelection) {
                ForEach(effectiveKind.modelOptions) { opt in
                    Text(opt.label).tag(opt.value)
                }
                Text("Custom…").tag("custom")
            }
            if customModel {
                TextField("Model name", text: $state.settings.model,
                          prompt: Text("exact model name for \(effectiveKind.displayName)"))
            }
        } header: {
            Text("Agent")
        } footer: {
            Text(agentFooter)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var agentFooter: String {
        let found = AgentKind.allCases.compactMap { state.agents[$0] != nil ? $0.displayName : nil }
        if found.isEmpty {
            return "No agent found yet. Install Claude Code, Codex or Gemini CLI — or point to one under Advanced."
        }
        return "Found on this Mac: \(found.joined(separator: ", ")). Automatic prefers Claude Code, then Codex, then Gemini — nothing to configure."
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            DatePicker("Generate at", selection: timeBinding, displayedComponents: .hourAndMinute)
            Toggle("Weekdays only", isOn: $state.settings.weekdaysOnly)
            Toggle("Launch at login", isOn: $state.launchAtLogin)
            Text("If your Mac is asleep at that time, the brief is written as soon as it wakes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var briefSection: some View {
        Section {
            TextField("Your first name", text: $state.settings.name)
            TextField("Language", text: $state.settings.language, prompt: Text("English"))
            VStack(alignment: .leading, spacing: 4) {
                Text("About you")
                TextEditor(text: $state.settings.about)
                    .font(.body)
                    .frame(minHeight: 54)
                Text("Role and tools that matter, e.g. “Android engineer on the Users team; include Linear issues assigned to me.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Extra sections (one per line)")
                TextEditor(text: $state.settings.sections)
                    .font(.body)
                    .frame(minHeight: 54)
                Text("e.g. “#android-releases: anything shipped or rolled back”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Include action buttons (open a prefilled Claude chat)", isOn: $state.settings.includeButtons)
            HStack {
                Button(state.personalizing ? "Asking your agent…" : "Fill from your agent's memory") {
                    Task { await state.personalize(overwrite: true) }
                }
                .disabled(state.personalizing || state.isRunning)
            }
            if !state.personalizeStatus.isEmpty {
                Text(state.personalizeStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Brief")
        } footer: {
            Text("“Fill from memory” asks the agent what it already knows about you (its own memory files) and writes these fields for you. It calls no tools and reads none of your data.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionsSection: some View {
        Section {
            HStack {
                Button(state.probing ? "Checking…" : "Check What's Connected") {
                    Task { await state.probeConnections() }
                }
                .disabled(state.probing || state.isRunning)
            }
            if !state.probeResult.isEmpty {
                Text(state.probeResult)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Add a tool", selection: $newToolName) {
                Text("Choose…").tag("")
                ForEach(KnownTool.catalog) { t in
                    Text(t.name.capitalized).tag(t.name)
                }
            }
            .onChange(of: newToolName) { name in
                if let t = KnownTool.catalog.first(where: { $0.name == name }) {
                    newToolURL = t.url
                }
            }
            TextField("Server URL", text: $newToolURL, prompt: Text("https://mcp.example.com/mcp"))
            HStack {
                Button(state.connecting ? "Adding…" : "Connect to \(effectiveKind.displayName)") {
                    Task { await state.connectTool(name: newToolName, url: newToolURL) }
                }
                .disabled(state.connecting || newToolName.isEmpty || newToolURL.isEmpty)
            }
            if !state.connectStatus.isEmpty {
                Text(state.connectStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("The brief sees whatever your agent sees. Pick a tool (or type any MCP server URL) to register it with your agent; you sign in once and it shows up in the next brief. Slack, Gmail and Google Calendar have no public server URL — with Claude Code, turn them on as connectors at claude.ai and they're available here automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            DisclosureGroup("Only needed if something's off") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Agent binary path", text: $state.settings.binaryOverride,
                              prompt: Text("/opt/homebrew/bin/claude"))
                    Text("Where the agent's command-line program lives. Leave empty — the app finds it by itself. Fill it only if the Agent picker says “no agent found” although one is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Extra command-line arguments", text: $state.settings.extraArgs)
                    Text("Appended to every run, for power users — e.g. --mcp-config ~/brief-mcp.json. Most people never need this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Give up after \(state.settings.timeoutMinutes) minutes",
                        value: $state.settings.timeoutMinutes, in: 3...45)
                ForEach(AgentKind.allCases) { k in
                    LabeledContent(k.displayName) {
                        Text(state.agents[k] ?? "not installed")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button("Re-detect Agents") { state.refreshAgents() }
            }
        }
    }
}
