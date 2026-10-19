import AppKit
import SwiftUI

/// Shared visual language for every Klick surface (wheel, toast, editors).
enum Theme {
    /// Klick's signature orange-red, taken from the original recording.
    static let accent = Color(red: 0.96, green: 0.29, blue: 0.12)
    static let accentLight = Color(red: 1.00, green: 0.45, blue: 0.22)
    static let accentDeep = Color(red: 0.86, green: 0.17, blue: 0.07)
    static let accentNS = NSColor(srgbRed: 0.96, green: 0.29, blue: 0.12, alpha: 1)

    static let accentGradient = LinearGradient(
        colors: [accentLight, accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Corner radius used by floating editor windows.
    static let windowCornerRadius: CGFloat = 30
    static let controlCornerRadius: CGFloat = 10

    static let springSnappy = Animation.spring(response: 0.26, dampingFraction: 0.78)
    static let springSoft = Animation.spring(response: 0.38, dampingFraction: 0.82)
}

extension NSScreen {
    /// The screen that currently contains `point` (global, bottom-left origin).
    static func containing(_ point: NSPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
    }
}

extension ByteCountFormatter {
    static func klickString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = bytes < 1000 ? [.useBytes] : [.useKB, .useMB, .useGB]
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }
}
