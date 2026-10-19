import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $navigation.pane) { pane in
                NavigationLink(value: pane) {
                    Label {
                        Text(pane.title)
                    } icon: {
                        SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch navigation.pane ?? .about {
                case .about: AboutPane()
                case .shortcut: ShortcutPane(settings: settings)
                case .credits: CreditsPane()
                case .license: LicensePane()
                }
            }
            .navigationTitle((navigation.pane ?? .about).title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// System Settings–style glyph: white symbol on a tinted rounded square.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.3), radius: 1, y: 0.5)
    }
}
