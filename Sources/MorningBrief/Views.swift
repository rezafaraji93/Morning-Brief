import AppKit
import SwiftUI

/// Settings, in the panel's brand cards. Shown inside the menu bar panel (gear button) and in a
/// window when a failure notification is clicked. Every change saves immediately.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var customModel = false
    @State private var newToolName = ""   // a catalog name, "custom", or "" for none
    @State private var customName = ""
    @State private var newToolURL = ""
    @State private var showAdvanced = false
    @State private var customEmoji = false

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

    /// "" in Settings means the recommended model, so the picker shows that option as chosen.
    private var modelSelection: Binding<String> {
        Binding(
            get: {
                if customModel { return "custom" }
                let m = state.settings.model
                if m.isEmpty { return effectiveKind.recommendedModel }
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
        ScrollView {
            VStack(spacing: 10) {
                agentSection
                scheduleSection
                briefSection
                slackSection
                connectionsSection
                promptSection
                advancedSection
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
        .tint(Brand.red)
        .task(id: serverRefreshKey) { await state.refreshServers() }
        .environment(\.colorScheme, .dark)
        .onAppear {
            state.detectNotice = nil
            let e = AppSettings.emojiName(state.settings.todoEmoji)
            customEmoji = !e.isEmpty && AppSettings.TodoEmoji.named(e) == nil
            let m = state.settings.model
            customModel = !m.isEmpty && !effectiveKind.modelOptions.contains(where: { $0.value == m })
        }
    }

    // MARK: sections

    private var agentSection: some View {
        SettingsCard(title: "Agent") {
            HStack(spacing: 6) {
                ForEach(AgentKind.allCases) { k in
                    AgentChip(name: k.displayName, found: state.agents[k] != nil)
                }
            }
            SettingsRow("Use") {
                BrandMenu(label: agentLabel) {
                    Picker("Agent", selection: $state.settings.agent) {
                        Text("Automatic — \(state.resolvedAgentLabel)").tag("auto")
                        ForEach(AgentKind.allCases) { k in
                            if state.agents[k] != nil {
                                Text(k.displayName).tag(k.rawValue)
                            }
                        }
                    }
                }
            }
            SettingsRow("Model") {
                BrandMenu(label: modelLabel) {
                    Picker("Model", selection: modelSelection) {
                        ForEach(effectiveKind.modelOptions) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                        Text("Custom…").tag("custom")
                    }
                }
            }
            if customModel {
                BrandField(placeholder: "Exact model name for \(effectiveKind.displayName)", text: $state.settings.model)
            }
            Caption(modelNote)
            Caption(agentFooter)
        }
    }

    private var emojiSelection: Binding<String> {
        Binding(
            get: {
                if customEmoji { return "custom" }
                let n = AppSettings.emojiName(state.settings.todoEmoji)
                if n.isEmpty { return "" }
                return AppSettings.TodoEmoji.named(n) != nil ? n : "custom"
            },
            set: { v in
                if v == "custom" {
                    customEmoji = true
                } else {
                    customEmoji = false
                    state.settings.todoEmoji = v
                }
            }
        )
    }

    private var emojiLabel: String {
        let n = AppSettings.emojiName(state.settings.todoEmoji)
        if customEmoji { return n.isEmpty ? "Other…" : ":\(n):" }
        if n.isEmpty { return "Choose…" }
        if let e = AppSettings.TodoEmoji.named(n) { return "\(e.glyph)  \(e.title)" }
        return ":\(n):"
    }

    /// Catalog tools the active agent doesn't have yet.
    private var addableTools: [KnownTool] {
        KnownTool.catalog.filter { !$0.isConnected(in: state.servers) }
    }

    private var selectedTool: KnownTool? { KnownTool.catalog.first { $0.name == newToolName } }

    private var toolMenuLabel: String {
        if newToolName == "custom" { return "Other server…" }
        return selectedTool?.title ?? "Choose…"
    }

    private var toolName: String {
        newToolName == "custom" ? customName.trimmingCharacters(in: .whitespaces).lowercased() : newToolName
    }

    private var canConnect: Bool {
        !state.connecting && !toolName.isEmpty && newToolURL.lowercased().hasPrefix("https://")
    }

    /// Re-read the agent's servers whenever the agent in use changes.
    private var serverRefreshKey: String {
        "\(state.settings.agent)|\(state.agents.keys.map(\.rawValue).sorted())"
    }

    private var agentLabel: String {
        AgentKind(rawValue: state.settings.agent)?.displayName ?? "Automatic — \(state.resolvedAgentLabel)"
    }

    private var selectedModel: ModelOption? {
        if customModel { return nil }
        let m = state.settings.model
        return effectiveKind.modelOptions.first { $0.value == (m.isEmpty ? effectiveKind.recommendedModel : m) }
    }

    private var modelLabel: String {
        if customModel { return state.settings.model.isEmpty ? "Custom…" : state.settings.model }
        return selectedModel?.label ?? state.settings.model
    }

    private var modelNote: String {
        selectedModel?.note ?? "Any model name \(effectiveKind.displayName) accepts, exactly as its own picker spells it."
    }

    private var agentFooter: String {
        if state.agents.isEmpty {
            return "No agent found yet. Install Claude Code or Codex, or point to one under Advanced."
        }
        return "Automatic prefers Claude Code, then Codex. Nothing to configure."
    }

    private var scheduleSection: some View {
        SettingsCard(title: "Schedule") {
            SettingsRow("Generate at") {
                DatePicker("Generate at", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
            }
            SettingsRow("Weekdays only") {
                Toggle("Weekdays only", isOn: $state.settings.weekdaysOnly).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Launch at login") {
                Toggle("Launch at login", isOn: $state.launchAtLogin).labelsHidden().toggleStyle(.switch)
            }
            Caption("If your Mac is asleep at that time, the brief is written as soon as it wakes.")
        }
    }

    private var briefSection: some View {
        SettingsCard(title: "Your brief") {
            HStack(spacing: 10) {
                LabeledField("First name") {
                    BrandField(placeholder: "Reza", text: $state.settings.name)
                }
                LabeledField("Language") {
                    BrandField(placeholder: "English", text: $state.settings.language)
                }
            }
            LabeledField("About you") {
                BrandEditor(text: $state.settings.about,
                            placeholder: "Android engineer on the Users team; include Linear issues assigned to me.",
                            minHeight: 80)
            }
            Caption("Your role and the tools that matter. The agent reads this before every brief.")
            LabeledField("Extra sections, one per line") {
                BrandEditor(text: $state.settings.sections,
                            placeholder: "#android-releases: anything shipped or rolled back")
            }
            Caption("Each line becomes a section of its own in the brief.")
            Divider().overlay(Brand.ink.opacity(0.08))
            HStack(spacing: 12) {
                Button(state.personalizing ? "Asking your agent…" : "Fill from your agent's memory") {
                    Task { await state.personalize(overwrite: true) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.personalizing || state.isRunning)
                if state.personalizing { ProgressView().controlSize(.small) }
            }
            if !state.personalizeStatus.isEmpty {
                StatusNote(state.personalizeStatus)
            }
            Caption("Asks your agent what it already knows about you and fills in your name and About you. It calls no tools and reads none of your data.")
        }
    }

    private var slackSection: some View {
        SettingsCard(title: "Slack channels") {
            LabeledField("Channels to watch") {
                BrandField(placeholder: "#android-development, #users-team, #general", text: $state.settings.watchChannels,
                           multiline: true)
            }
            Caption("Read in full every morning (Friday to Sunday on Mondays), but only what concerns you makes the brief: your name, your work, decisions that change it, and asks to everyone with a deadline.")
            SettingsRow("Flagged messages") {
                Toggle("Flagged messages", isOn: $state.settings.todoEnabled).labelsHidden().toggleStyle(.switch)
            }
            if state.settings.todoEnabled {
                SettingsRow("To-do emoji") {
                    BrandMenu(label: emojiLabel) {
                        Picker("To-do emoji", selection: emojiSelection) {
                            ForEach(AppSettings.TodoEmoji.catalog) { e in
                                Text("\(e.glyph)  \(e.title)").tag(e.name)
                            }
                            Text("Other…").tag("custom")
                        }
                    }
                }
                if customEmoji {
                    BrandField(placeholder: "Emoji name as Slack spells it, e.g. ticket", text: $state.settings.todoEmoji)
                }
            }
            Caption("React with this emoji on any message and it stays under \u{201C}Flagged in Slack\u{201D} until you remove the reaction. Other… takes any emoji name, including your workspace's own. Slack's own To-dos list isn't readable by the agent; this stands in for it.")
            HStack(spacing: 12) {
                Button(state.suggestingChannels ? "Looking at your Slack…" : "Suggest from Slack") {
                    Task { await state.suggestChannels() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.suggestingChannels || state.isRunning)
                if state.suggestingChannels { ProgressView().controlSize(.small) }
            }
            if let notice = state.channelsNotice {
                NoticeView(notice: notice)
            }
            Caption("Your agent looks at the channels you're active in (read-only) and adds them to Channels to watch. Takes a minute or two.")
        }
    }

    private var connectionsSection: some View {
        SettingsCard(title: "Connections") {
            HStack(spacing: 12) {
                Button(state.probing ? "Checking…" : "Check what's connected") {
                    Task { await state.probeConnections() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.probing || state.isRunning)
                if state.probing { ProgressView().controlSize(.small) }
            }
            if !state.probeResult.isEmpty, !state.probing {
                ConnectionReport(text: state.probeResult)
            }
            Divider().overlay(Brand.ink.opacity(0.08))
            SettingsRow("Add a tool") {
                BrandMenu(label: toolMenuLabel) {
                    Picker("Add a tool", selection: $newToolName) {
                        Text("Choose…").tag("")
                        ForEach(addableTools) { t in
                            Text(t.title).tag(t.name)
                        }
                        Text("Other server…").tag("custom")
                    }
                }
            }
            .onChange(of: newToolName) { name in
                state.connectStatus = ""
                if let t = KnownTool.catalog.first(where: { $0.name == name }) {
                    newToolURL = t.url
                } else if name == "custom" {
                    newToolURL = ""
                }
            }
            .onChange(of: state.servers) { _ in
                // A tool that just got connected drops out of the list; don't leave it selected.
                if let t = selectedTool, t.isConnected(in: state.servers) { newToolName = "" }
            }
            if let t = selectedTool, let steps = t.manualSteps(for: effectiveKind) {
                NoticeView(notice: Notice(tone: .info, text: steps))
            } else if !newToolName.isEmpty {
                if newToolName == "custom" {
                    BrandField(placeholder: "Short name, e.g. jira", text: $customName)
                }
                BrandField(placeholder: "https://mcp.example.com/mcp", text: $newToolURL)
                HStack(spacing: 12) {
                    Button(state.connecting ? "Adding…" : "Connect to \(effectiveKind.displayName)") {
                        Task { await state.connectTool(name: toolName, url: newToolURL) }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!canConnect)
                    .opacity(canConnect ? 1 : 0.5)
                    if state.connecting { ProgressView().controlSize(.small) }
                }
            }
            if !state.connectStatus.isEmpty {
                StatusNote(state.connectStatus)
            }
            Caption("The brief sees whatever your agent sees. Tools it already has don't appear in the list. Pick one (or Other server… for any MCP URL) and sign in once in the browser.")
        }
    }

    private var promptSection: some View {
        SettingsCard(title: "Prompt") {
            SettingsRow("Use my own prompt") {
                Toggle("Use my own prompt", isOn: $state.settings.customPromptEnabled).labelsHidden().toggleStyle(.switch)
            }
            .onChange(of: state.settings.customPromptEnabled) { on in
                // Start from the built-in instructions rather than a blank page.
                if on, state.settings.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let d = try? PromptBuilder.defaultTemplate() {
                    state.settings.customPrompt = d
                }
            }
            if state.settings.customPromptEnabled {
                BrandEditor(text: $state.settings.customPrompt, minHeight: 320, monospaced: true)
                HStack(spacing: 12) {
                    Button("Reset to default") {
                        if let d = try? PromptBuilder.defaultTemplate() { state.settings.customPrompt = d }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Copy today's full prompt") {
                        if let p = try? PromptBuilder.build(settings: state.settings) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(p, forType: .string)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Caption("Placeholders are filled in when the brief runs: " + PromptBuilder.placeholders.joined(separator: " ") + ". Keep {{SCHEMA}} at the end so the agent knows the answer format; it's added for you if missing. The ground rules about staying read-only are part of the prompt, so keep them.")
            } else {
                Caption("The brief runs on the built-in instructions. Turn this on to edit a copy of them; off brings the built-in ones back, and your copy is kept.")
            }
        }
    }

    private var advancedSection: some View {
        SettingsCard {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(Brand.font(13, .semibold))
                        .foregroundStyle(Brand.inkSoft)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.inkGrey)
                        .rotationEffect(.degrees(showAdvanced ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAdvanced {
                Caption("Only needed if something's off.")
                LabeledField("Agent program path") {
                    BrandField(placeholder: "/opt/homebrew/bin/claude", text: $state.settings.binaryOverride)
                }
                Caption("Leave empty and the app finds it. Fill it only if your agent is installed but shows as not found.")
                LabeledField("Extra command-line arguments") {
                    BrandField(placeholder: "--mcp-config ~/brief-mcp.json", text: $state.settings.extraArgs)
                }
                Caption("Appended to every run. Most people never need this.")
                SettingsRow("Give up after \(state.settings.timeoutMinutes) minutes") {
                    Stepper("Timeout", value: $state.settings.timeoutMinutes, in: 3...45).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AgentKind.allCases) { k in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(k.displayName)
                                .font(Brand.font(12.5, .semibold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 92, alignment: .leading)
                            Text(state.agents[k] ?? "not installed")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Brand.inkSoft)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button(state.detecting ? "Detecting…" : "Re-detect agents") {
                        Task { await state.redetectAgents() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(state.detecting)
                    if state.detecting { ProgressView().controlSize(.small) }
                }
                if let notice = state.detectNotice {
                    NoticeView(notice: notice)
                }
            }
        }
    }
}

// MARK: building blocks

private struct SettingsCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(Brand.font(13, .semibold))
                    .foregroundStyle(Brand.inkSoft)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Label on the left, control on the right.
private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Brand.font(14))
                .foregroundStyle(Brand.ink)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 28)
    }
}

/// Small label above a field.
private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Brand.font(12.5, .semibold))
                .foregroundStyle(Brand.inkSoft)
            field
        }
    }
}

/// A soft outline on the field that has keyboard focus, since the plain field styles draw none.
private struct FocusRing: View {
    let on: Bool
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Brand.ink.opacity(on ? 0.45 : 0), lineWidth: 1.5)
            .animation(.easeOut(duration: 0.12), value: on)
            .allowsHitTesting(false)
    }
}

private struct BrandField: View {
    let placeholder: String
    @Binding var text: String
    /// Grows to a few lines instead of scrolling sideways.
    var multiline = false
    @FocusState private var focused: Bool

    var body: some View {
        // Own placeholder instead of the prompt, which macOS draws in a dim system grey.
        TextField("", text: $text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 1...4 : 1...1)
            .textFieldStyle(.plain)
            .focused($focused)
            .font(Brand.font(14))
            .foregroundStyle(Brand.ink)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Brand.font(14))
                        .foregroundStyle(Brand.placeholder)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 8 : 0)
            .frame(minHeight: 34)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(FocusRing(on: focused, radius: 10))
    }
}

private struct BrandEditor: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 64
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : Brand.font(14))
            .foregroundStyle(Brand.ink)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(alignment: .topLeading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(placeholder)
                        .font(Brand.font(14))
                        .foregroundStyle(Brand.placeholder)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(FocusRing(on: focused, radius: 10))
    }
}

/// A pop-up menu drawn as a raised pill showing the current choice.
private struct BrandMenu<Items: View>: View {
    let label: String
    @ViewBuilder var items: Items

    var body: some View {
        // A borderless menu draws only its label's text natively, so the pill and chevron sit around it.
        HStack(spacing: 8) {
            Menu {
                items.pickerStyle(.inline)
            } label: {
                Text(label)
                    .font(Brand.font(13.5, .medium))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Brand.ink)
            .fixedSize()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Brand.inkSoft)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Brand.raised, in: Capsule())
    }
}

private struct AgentChip: View {
    let name: String
    let found: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(found ? Brand.green : Brand.inkGrey.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(name)
                .font(Brand.font(12.5, .semibold))
                .foregroundStyle(found ? Brand.ink : Brand.inkGrey)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Brand.raised.opacity(found ? 1 : 0.5), in: Capsule())
        .help(found ? "Installed" : "Not installed")
    }
}

/// "role: value" lines from the connection check, one row each with a status dot.
private struct ConnectionReport: View {
    let text: String

    private struct Line: Identifiable {
        let id: Int
        let key: String?
        let value: String
        let color: Color
    }

    /// The first line names the agent that was checked ("Codex:").
    private var agent: String? {
        guard let first = text.split(separator: "\n").first, first.hasSuffix(":") else { return nil }
        return String(first.dropLast())
    }

    private var lines: [Line] {
        let raw = text.split(separator: "\n").map(String.init)
        let body = agent != nil ? Array(raw.dropFirst()) : raw
        return body.enumerated().map { i, line in
            guard let r = line.range(of: ": ") else {
                return Line(id: i, key: nil, value: line, color: Brand.inkGrey)
            }
            let key = String(line[..<r.lowerBound])
            let value = String(line[r.upperBound...])
            let color: Color
            if key == "needs sign-in" || key == "not working" { color = Brand.red }
            else if value.hasPrefix("not connected") { color = Brand.inkGrey.opacity(0.6) }
            else { color = Brand.green }
            return Line(id: i, key: key, value: value, color: color)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent {
                Text("Checked with \(agent)")
                    .font(Brand.font(12, .semibold))
                    .foregroundStyle(Brand.inkGrey)
                    .padding(.bottom, 2)
            }
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(l.color).frame(width: 7, height: 7).padding(.top, 5)
                    if let key = l.key {
                        Text(key.prefix(1).uppercased() + key.dropFirst())
                            .font(Brand.font(13, .semibold))
                            .foregroundStyle(Brand.ink)
                            .frame(width: 112, alignment: .leading)
                    }
                    Text(l.value)
                        .font(Brand.font(13))
                        .foregroundStyle(Brand.inkSoft)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.font(12))
            .foregroundStyle(Brand.inkGrey)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A short result message with an icon that says whether it's good news.
struct Notice: Equatable {
    enum Tone { case success, info, warning }
    let tone: Tone
    let text: String
}

private struct NoticeView: View {
    let notice: Notice

    private var icon: (String, Color) {
        switch notice.tone {
        case .success: return ("checkmark.circle.fill", Brand.green)
        case .info: return ("info.circle.fill", Brand.inkSoft)
        case .warning: return ("exclamationmark.circle.fill", Brand.red)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0)
                .font(.system(size: 14))
                .foregroundStyle(icon.1)
                .padding(.top, 1)
            Text(notice.text)
                .font(Brand.font(13))
                .foregroundStyle(Brand.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Brand.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity)
    }
}

/// Result text from an action (fill from memory, connect), selectable so it can be copied.
private struct StatusNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Brand.font(13))
            .foregroundStyle(Brand.inkSoft)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Secondary action: a raised pill, quieter than the red primary one.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat

    init(height: CGFloat = 32) { self.height = height }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(13.5, .semibold))
            .foregroundStyle(Brand.ink.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(configuration.isPressed ? Brand.raised.opacity(0.7) : Brand.raised, in: Capsule())
            .contentShape(Capsule())
    }
}
