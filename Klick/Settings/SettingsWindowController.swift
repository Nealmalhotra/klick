import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case about, shortcut, credits, license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .about: return "About"
        case .shortcut: return "Shortcut"
        case .credits: return "Credits"
        case .license: return "License"
        }
    }

    var symbol: String {
        switch self {
        case .about: return "info"
        case .shortcut: return "shift.fill"
        case .credits: return "heart.fill"
        case .license: return "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .about: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .shortcut: return Theme.accent
        case .credits: return Color(red: 0.98, green: 0.32, blue: 0.48)
        case .license: return Color(red: 0.30, green: 0.75, blue: 0.42)
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane? = .about
}

/// Hosts the classic macOS settings window (sidebar + grouped forms).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Cooperative activation may refuse to steal focus; still bring the window up.
        window?.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Klick Settings"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "KlickSettingsToolbar")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsView(navigation: navigation, settings: AppSettings.shared)
        )
        window.setContentSize(NSSize(width: 760, height: 540))
        window.center()
        window.setFrameAutosaveName("KlickSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the instance; it is cheap and preserves the selected pane.
    }
}
