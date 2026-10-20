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

    func showBrief(_ b: StoredBrief) {
        showBrief(url: BriefStore.rerender(b, buttons: AppState.shared.settings.includeButtons))
    }

    func showBrief(url: URL) {
        if briefWindow == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config)
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
        briefWindow?.title = "Morning Brief — " + url.deletingPathExtension().lastPathComponent
        webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        bringToFront(briefWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Morning Brief Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        bringToFront(settingsWindow)
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
