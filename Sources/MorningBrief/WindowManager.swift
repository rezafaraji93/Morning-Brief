import AppKit
import SwiftUI
import WebKit

/// Plain AppKit windows, so the brief can be opened from anywhere (menu, notification click)
/// without depending on SwiftUI scene plumbing in a menu-bar-only app.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = WindowManager()

    private var briefWindow: NSWindow?
    private var webView: WKWebView?
    private var settingsWindow: NSWindow?
    private var panelWindow: NSWindow?

    func showBrief(_ b: StoredBrief) {
        showBrief(url: BriefStore.rerender(b), title: b.displayName)
    }

    func showBrief(url: URL, title: String? = nil) {
        if briefWindow == nil {
            let web = WKWebView(frame: .zero, configuration: BriefPageBridge.configuration())
            web.navigationDelegate = self
            web.underPageBackgroundColor = Brand.oceanNS
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 980),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = web
            w.setFrameAutosaveName("MorningBriefWindow")
            if w.frame.origin == .zero { w.center() }
            w.delegate = self
            briefWindow = w
            webView = web
        }
        briefWindow?.title = "Morning Brief — " + (title ?? url.deletingPathExtension().lastPathComponent)
        webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        bringToFront(briefWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(AppState.shared)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 34)   // clear the transparent title bar
                .frame(width: 440, height: 744)
                .background(Brand.ocean)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = "Morning Brief Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Brand.oceanNS
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        bringToFront(settingsWindow)
    }

    /// The menu bar panel in an ordinary window: `MORNINGBRIEF_PANEL_WINDOW=1 swift run`, for
    /// screenshots and UI work without reaching for the menu bar.
    func showPanelWindow() {
        if panelWindow == nil {
            let host = NSHostingController(rootView: BriefPanel().environmentObject(AppState.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Morning Brief Panel"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Brand.oceanNS
            w.isReleasedWhenClosed = false
            w.center()
            panelWindow = w
        }
        bringToFront(panelWindow)
    }

    private func bringToFront(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
        w?.orderFrontRegardless()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        BriefLinks.policy(for: navigationAction)
    }
}
