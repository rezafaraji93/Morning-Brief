import AppKit
import SwiftUI
import WebKit

/// Polarsteps brand tokens for the panel. Resources/template.html carries the same values.
enum Brand {
    static let ocean = Color(hex: 0x00293D)
    static let card = Color(hex: 0x0F3547)
    static let raised = Color(hex: 0x1B4256)
    static let ink = Color(hex: 0xFFF2E5)
    static let inkSoft = ink.opacity(0.72)
    static let inkGrey = ink.opacity(0.45)
    static let placeholder = ink.opacity(0.62)
    static let red = Color(hex: 0xF11F4C)
    static let redPressed = Color(hex: 0xD81A43)
    static let green = Color(hex: 0x00DB9A)
    static let oceanNS = NSColor(srgbRed: 0, green: 41 / 255, blue: 61 / 255, alpha: 1)

    private static let hasFellix = NSFont(name: "PolarstepsFellix-Regular", size: 12) != nil
    private static let hasLore = NSFont(name: "LOREAlternates-Bold", size: 12) != nil

    /// Polarsteps Fellix when it's installed, otherwise the system's rounded face.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard hasFellix else { return .system(size: size, weight: weight, design: .rounded) }
        let face: String
        switch weight {
        case .heavy, .black: face = "ExtraBold"
        case .bold: face = "Bold"
        case .semibold: face = "SemiBold"
        case .medium: face = "Medium"
        default: face = "Regular"
        }
        return .custom("PolarstepsFellix-\(face)", size: size)
    }

    /// LORE Alternates, the brand's eyebrow face.
    static func eyebrow(_ size: CGFloat) -> Font {
        hasLore ? .custom("LOREAlternates-Bold", size: size) : .system(size: size, weight: .bold, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The panel that drops down from the menu bar icon: today's brief inline, earlier ones a tab away.
struct BriefPanel: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .today
    @State private var openedEarlier: StoredBrief?
    @State private var showingSettings = false

    enum Tab { case today, earlier }

    var body: some View {
        VStack(spacing: 8) {
            header
            if showingSettings {
                settingsBar
                SettingsView()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabBar
                Group {
                    switch tab {
                    case .today: today
                    case .earlier: earlier
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(10)
        .frame(width: 440, height: 720)
        .background(Brand.ocean)
        .environment(\.colorScheme, .dark)
        .onAppear { state.reloadRecent() }
    }

    // MARK: header and tabs

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting)
                    .font(Brand.font(11, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Brand.inkSoft)
                Text("Morning Brief")
                    .font(Brand.font(21, .heavy))
                    .foregroundStyle(Brand.ink)
            }
            Spacer()
            PanelIconButton(systemName: "arrow.clockwise",
                            help: state.todayBrief == nil ? "Generate now" : "Regenerate today's brief") {
                Task { await state.generate(manual: true) }
            }
            .disabled(state.isRunning)
            .keyboardShortcut("r")
            PanelIconButton(systemName: showingSettings ? "gearshape.fill" : "gearshape", help: "Settings") {
                showingSettings.toggle()
            }
            .keyboardShortcut(",")
            Menu {
                if let b = shownBrief {
                    Button("Open in Window") { WindowManager.shared.showBrief(b) }
                }
                Button("Show Logs in Finder") {
                    Paths.ensure()
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.logs])
                }
                Divider()
                Button("Quit Morning Brief") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.ink)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var tabBar: some View {
        HStack(spacing: 24) {
            TabLabel(title: "Today", selected: tab == .today) { tab = .today }
            TabLabel(title: "Earlier", selected: tab == .earlier) {
                tab = .earlier
                openedEarlier = nil
            }
            Spacer()
            if let b = shownBrief {
                PanelIconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open in a window") {
                    WindowManager.shared.showBrief(b)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsBar: some View {
        HStack {
            Button {
                showingSettings = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Settings").font(Brand.font(15, .semibold))
                }
                .foregroundStyle(Brand.ink)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Spacer()
            Text("Changes save as you go")
                .font(Brand.font(12))
                .foregroundStyle(Brand.inkGrey)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The brief the panel is showing right now, if any.
    private var shownBrief: StoredBrief? {
        switch tab {
        case .today: return state.todayBrief
        case .earlier: return openedEarlier
        }
    }

    // MARK: today

    @ViewBuilder private var today: some View {
        if let b = state.todayBrief {
            ZStack(alignment: .top) {
                BriefWebView(brief: b, buttons: state.settings.includeButtons)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if state.isRunning {
                    RunningBanner()
                        .padding(10)
                }
            }
        } else if state.isRunning {
            PanelCard {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.regular)
                    Text("Writing your brief")
                        .font(Brand.font(18, .bold))
                        .foregroundStyle(Brand.ink)
                    StatusText()
                        .multilineTextAlignment(.center)
                    Text("This takes a few minutes. You can close this panel; you'll get a notification when it's ready.")
                        .font(Brand.font(13))
                        .foregroundStyle(Brand.inkGrey)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 300)
            }
        } else if case .failed(let message) = state.status {
            PanelCard {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Brand.red)
                    Text("The last run didn't finish")
                        .font(Brand.font(18, .bold))
                        .foregroundStyle(Brand.ink)
                    Text(message)
                        .font(Brand.font(13))
                        .foregroundStyle(Brand.inkSoft)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await state.generate(manual: true) } }
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, 4)
                }
                .frame(maxWidth: 320)
            }
        } else {
            PanelCard {
                VStack(spacing: 12) {
                    Image(systemName: "sun.horizon")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Brand.red)
                    Text("No brief yet today")
                        .font(Brand.font(18, .bold))
                        .foregroundStyle(Brand.ink)
                    Text("The next one is due \(state.nextRunDescription()).")
                        .font(Brand.font(13.5))
                        .foregroundStyle(Brand.inkSoft)
                    Button("Generate now") { Task { await state.generate(manual: true) } }
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: earlier

    @ViewBuilder private var earlier: some View {
        let past = state.recent.filter { $0.day != BriefStore.dayKey() }
        if let b = openedEarlier {
            VStack(spacing: 8) {
                Button {
                    openedEarlier = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(b.displayName).font(Brand.font(14, .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                BriefWebView(brief: b, buttons: state.settings.includeButtons)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        } else if past.isEmpty {
            PanelCard {
                Text("Earlier briefs show up here.")
                    .font(Brand.font(14))
                    .foregroundStyle(Brand.inkSoft)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Past briefs")
                        .font(Brand.font(13, .semibold))
                        .foregroundStyle(Brand.inkSoft)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    ForEach(past) { b in
                        EarlierRow(brief: b) { openedEarlier = b }
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if state.todayBrief != nil, !state.isRunning, !isFailed {
                Text("Next brief \(state.nextRunDescription())")
            } else {
                StatusText()
            }
            Spacer()
        }
        .font(Brand.font(11.5))
        .foregroundStyle(Brand.inkGrey)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private var isFailed: Bool { if case .failed = state.status { return true }; return false }

    /// "GOOD MORNING, REZA" — the brief itself carries the date, so the header doesn't repeat it.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = state.settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? part : "\(part), \(name)").uppercased()
    }
}

// MARK: pieces

/// AppState.statusLine, refreshed so the running minutes keep counting while the panel is open.
private struct StatusText: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            Text(state.statusLine)
                .font(Brand.font(13))
                .foregroundStyle(Brand.inkSoft)
        }
    }
}

private struct RunningBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            StatusText()
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Brand.raised, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TabLabel: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.font(15, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Brand.ink : Brand.inkSoft)
                .frame(height: 48)
                .overlay(alignment: .bottom) {
                    if selected {
                        Capsule().fill(Brand.ink).frame(height: 2.5).padding(.bottom, 8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PanelIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.ink.opacity(isEnabled ? 1 : 0.35))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering && isEnabled ? Brand.raised : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct EarlierRow: View {
    let brief: StoredBrief
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(brief.weekdayShort)
                        .font(Brand.font(9.5, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Brand.inkSoft)
                    Text(brief.dayOfMonth)
                        .font(Brand.font(19, .heavy))
                        .foregroundStyle(Brand.ink)
                }
                .frame(width: 46, height: 46)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(brief.displayName)
                        .font(Brand.font(15, .bold))
                        .foregroundStyle(Brand.ink)
                    if let h = brief.headline {
                        Text(h)
                            .font(Brand.font(13))
                            .foregroundStyle(Brand.inkSoft)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.inkGrey)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering ? Brand.raised.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(14, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(configuration.isPressed ? Brand.redPressed : Brand.red, in: Capsule())
            .contentShape(Capsule())
    }
}

/// A stored brief, re-rendered with the current template and shown in a web view.
struct BriefWebView: NSViewRepresentable {
    let brief: StoredBrief
    let buttons: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.underPageBackgroundColor = Brand.oceanNS
        // Hidden until the page has drawn, so there's no white flash inside the dark panel.
        web.alphaValue = 0
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let key = "\(brief.day)|\(brief.modified.timeIntervalSince1970)|\(buttons)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        let url = BriefStore.rerender(brief, buttons: buttons)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.alphaValue = 1
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            BriefLinks.policy(for: navigationAction)
        }
    }
}

/// Links in a brief open in the default browser; only the local brief file loads in the view.
enum BriefLinks {
    @MainActor
    static func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.isFileURL { return .allow }
        if url.scheme == "https", action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}
