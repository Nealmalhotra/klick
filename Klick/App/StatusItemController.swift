import AppKit
import Combine

/// The ⇧ arrow in the menu bar.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings = AppSettings.shared
    private var cancellables: Set<AnyCancellable> = []
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")

    override init() {
        super.init()
        if let button = item.button {
            button.image = Self.icon(enabled: settings.isEnabled)
            button.toolTip = "Klick"
        }

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "Klick", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: "About Klick", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Klick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        settings.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.item.button?.image = Self.icon(enabled: enabled)
            }
            .store(in: &cancellables)
    }

    private static func icon(enabled: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: "shift", accessibilityDescription: "Klick")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return enabled ? image : image?.tinted(alpha: 0.4)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        enabledItem.state = settings.isEnabled ? .on : .off
        enabledItem.title = "Enable \(settings.trigger.glyph) Wheel"
    }

    @objc private func toggleEnabled() { settings.isEnabled.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show(pane: .shortcut) }
    @objc private func openAbout() { SettingsWindowController.shared.show(pane: .about) }
}

private extension NSImage {
    func tinted(alpha: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }
}
