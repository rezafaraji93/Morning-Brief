import AppKit
import SwiftUI
import UserNotifications

@main
struct MorningBriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            BriefPanel().environmentObject(state)
        } label: {
            Image(systemName: state.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, even when launched with `swift run` (the .app sets LSUIElement too).
        NSApp.setActivationPolicy(.accessory)
        if AppState.notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        Task { @MainActor in AppState.shared.start() }
        if ProcessInfo.processInfo.environment["MORNINGBRIEF_PANEL_WINDOW"] == "1" {
            WindowManager.shared.showPanelWindow()
        }
    }

    // Show the banner even if the app happens to be frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Clicking "Your morning brief is ready" opens it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run {
            if let path {
                let url = URL(fileURLWithPath: path)
                let day = url.deletingPathExtension().lastPathComponent
                if let b = BriefStore.recent().first(where: { $0.day == day }) {
                    WindowManager.shared.showBrief(b)   // re-rendered with the current template
                } else {
                    WindowManager.shared.showBrief(url: url)
                }
            } else {
                WindowManager.shared.showSettings()
            }
        }
    }
}
