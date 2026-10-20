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

    var body: some View {
        Form {
            Section("Agent") {
                Picker("Use", selection: $state.settings.agent) {
                    Text("Automatic").tag("auto")
                    ForEach(AgentKind.allCases) { k in
                        Text(k.displayName + (state.agents[k] == nil ? " (not found)" : "")).tag(k.rawValue)
                    }
                }
                ForEach(AgentKind.allCases) { k in
                    LabeledContent(k.displayName) {
                        Text(state.agents[k] ?? "not installed")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                TextField("Binary path (optional)", text: $state.settings.binaryOverride,
                          prompt: Text("/opt/homebrew/bin/claude"))
                TextField("Model (optional)", text: $state.settings.model, prompt: Text("agent default"))
                TextField("Extra arguments", text: $state.settings.extraArgs, prompt: Text("e.g. --mcp-config ~/brief-mcp.json"))
                HStack {
                    Button(state.probing ? "Checking…" : "Check Connections") {
                        Task { await state.probeConnections() }
                    }
                    .disabled(state.probing || state.isRunning)
                    Button("Re-detect Agents") { state.refreshAgents() }
                }
                if !state.probeResult.isEmpty {
                    Text(state.probeResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Schedule") {
                DatePicker("Generate at", selection: timeBinding, displayedComponents: .hourAndMinute)
                Toggle("Weekdays only", isOn: $state.settings.weekdaysOnly)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Stepper("Give up after \(state.settings.timeoutMinutes) minutes",
                        value: $state.settings.timeoutMinutes, in: 3...45)
                Text("If your Mac is asleep at that time, the brief is written when it wakes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Brief") {
                TextField("Your first name", text: $state.settings.name)
                TextField("Language", text: $state.settings.language, prompt: Text("English"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("About you")
                    TextEditor(text: $state.settings.about)
                        .font(.body)
                        .frame(minHeight: 54)
                    Text("Role and tools that matter, e.g. \"Android engineer on the Users team; include Linear issues assigned to me.\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra sections (one per line)")
                    TextEditor(text: $state.settings.sections)
                        .font(.body)
                        .frame(minHeight: 54)
                    Text("e.g. \"#android-releases: anything shipped or rolled back\" or \"PRs waiting on my review\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Include action buttons (open a prefilled Claude chat)", isOn: $state.settings.includeButtons)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
    }
}
