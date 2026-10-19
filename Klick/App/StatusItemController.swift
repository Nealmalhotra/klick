import AppKit
import SwiftUI
import Combine

/// The wheel glyph in the menu bar.
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
        let image = wheelGlyph()
        return enabled ? image : image.tinted(alpha: 0.4)
    }

    /// A template version of the app icon: six segments with the top one lit,
    /// and a solid hub with the ⇧ arrow knocked out of it.
    private static func wheelGlyph() -> NSImage {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let count = 6
            for index in 0..<count {
                let segment = WheelSegmentShape(index: index, count: count, innerRadius: 5.1, outerRadius: 8.9,
                                                gap: 1.3, corner: 0.8).path(in: rect).cgPath
                ctx.addPath(segment)
                ctx.setFillColor(NSColor.black.withAlphaComponent(index == 0 ? 1 : 0.4).cgColor)
                ctx.fillPath()
            }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - 3.9, y: center.y - 3.9, width: 7.8, height: 7.8))

            // ⇧ arrow: triangular head over a short stem, cut out of the hub.
            let arrow = CGMutablePath()
            arrow.addLines(between: [
                CGPoint(x: center.x, y: center.y - 2.5),
                CGPoint(x: center.x + 2.3, y: center.y),
                CGPoint(x: center.x + 1, y: center.y),
                CGPoint(x: center.x + 1, y: center.y + 2.3),
                CGPoint(x: center.x - 1, y: center.y + 2.3),
                CGPoint(x: center.x - 1, y: center.y),
                CGPoint(x: center.x - 2.3, y: center.y),
            ])
            arrow.closeSubpath()
            ctx.setBlendMode(.clear)
            ctx.addPath(arrow)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Klick"
        return image
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
