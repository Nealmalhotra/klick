import AppKit
import SwiftUI

// MARK: - About

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    Text(AppInfo.name)
                        .font(.system(size: 26, weight: .bold))
                    Text("Version \(AppInfo.version) (\(AppInfo.build))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(AppInfo.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section("How it works") {
                HowToRow(step: "1", text: "Select a file or folder in Finder.")
                HowToRow(step: "2", text: "Hold \(AppSettings.shared.trigger.glyph) \(AppSettings.shared.trigger.title) — the wheel opens under your cursor.")
                HowToRow(step: "3", text: "Point at an action and release the key (or click it).")
                HowToRow(step: "4", text: "Or drag files, tap the key and drop them on an action.")
            }

            Section {
                LabeledContent("Made by", value: AppInfo.author)
                LabeledContent("Source code") {
                    Link("GitHub", destination: AppInfo.repositoryURL)
                }
                LabeledContent("Feedback") {
                    Link("Report an issue", destination: AppInfo.issuesURL)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HowToRow: View {
    let step: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(step)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accentGradient))
            Text(text)
        }
    }
}

// MARK: - Shortcut

struct ShortcutPane: View {
    @ObservedObject var settings: AppSettings
    @State private var finderAccess: FinderBridge.AutomationStatus?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Hold this key while a file is selected in Finder to open the Convert wheel.")
                        .foregroundStyle(.secondary)
                    KeycapPicker(selection: $settings.trigger)
                }
                .padding(.vertical, 4)
                WheelKeyRow(wheel: .tools, symbol: "wrench.and.screwdriver", selection: $settings.toolsTrigger)
                WheelKeyRow(wheel: .file, symbol: "folder", selection: $settings.fileTrigger)
            } header: {
                Text("Trigger keys")
            } footer: {
                Text("Each key opens its own wheel. While a wheel is open, press another key to switch to its wheel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    HStack {
                        Slider(value: $settings.holdDelay, in: 0.1...0.6, step: 0.05)
                            .tint(Theme.accent)
                            .frame(maxWidth: 220)
                        Text("\(Int(settings.holdDelay * 1000)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                } label: {
                    Text("Hold delay")
                    Text("How long to hold before the wheel appears.")
                }
                Toggle(isOn: $settings.finderOnly) {
                    Text("Only when Finder is in front")
                    Text("Avoids conflicts with Shift in other apps.")
                }
                Toggle(isOn: $settings.dragToOpen) {
                    Text("Open while dragging files")
                    Text("Drag files from anywhere, tap a trigger key, drop them on an action.")
                }
                Toggle("Enable Klick", isOn: $settings.isEnabled)
                Toggle("Open at login", isOn: $settings.launchAtLogin)
            } header: {
                Text("Behavior")
            }

            Section("Feedback") {
                Toggle(isOn: $settings.soundsEnabled) {
                    Text("Haptic sounds")
                    Text("Soft taps when you move across the wheel.")
                }
                if settings.soundsEnabled {
                    LabeledContent("Volume") {
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $settings.soundVolume, in: 0.05...1) { editing in
                                if !editing { Feedback.shared.tick() }
                            }
                            .tint(Theme.accent)
                            .frame(maxWidth: 200)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: $settings.hapticsEnabled) {
                    Text("Trackpad haptics")
                    Text("Uses the Force Touch trackpad when your finger rests on it.")
                }
            }

            Section("While the wheel is open") {
                ShortcutHelpRow(keys: ["⇢"], text: "Point at an action, release the trigger to run it")
                ShortcutHelpRow(keys: ["click"], text: "Run the highlighted action")
                ShortcutHelpRow(keys: ["⇧", "⌘", "⌃"], text: "Switch wheel (Convert · Tools · File)")
                ShortcutHelpRow(keys: ["⇥", "scroll", "→"], text: "Next or previous wheel")
                ShortcutHelpRow(keys: ["1", "…", "8"], text: "Pick an action directly")
                ShortcutHelpRow(keys: ["esc"], text: "Close without doing anything")
            }

            Section("Permissions") {
                LabeledContent {
                    switch finderAccess {
                    case .granted:
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .denied:
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    case .finderNotRunning:
                        Text("Finder isn't running").foregroundStyle(.secondary)
                    case .notDetermined, .none:
                        Button("Allow…") { requestFinderAccess() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                } label: {
                    Text("Finder selection")
                    Text("Needed to know which files are selected.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshFinderAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFinderAccess()
        }
    }

    private func refreshFinderAccess() {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = FinderBridge.automationStatus(prompt: false)
            DispatchQueue.main.async { finderAccess = status }
        }
    }

    private func requestFinderAccess() {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = FinderBridge.automationStatus(prompt: true)
            DispatchQueue.main.async { finderAccess = status }
        }
    }
}

/// Key for one of the secondary wheels, or Off.
private struct WheelKeyRow: View {
    let wheel: WheelKind
    let symbol: String
    @Binding var selection: TriggerKey?

    var body: some View {
        Picker(selection: $selection) {
            Text("Off").tag(TriggerKey?.none)
            Divider()
            ForEach(TriggerKey.allCases) { key in
                Text("\(key.glyph)  \(key.title)").tag(TriggerKey?.some(key))
            }
        } label: {
            Label {
                Text("\(wheel.title) wheel")
            } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Grid of physical-looking keycaps; the chosen one glows in Klick orange.
struct KeycapPicker: View {
    @Binding var selection: TriggerKey

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(TriggerKey.allCases) { key in
                Keycap(key: key, selected: key == selection)
                    .onTapGesture {
                        withAnimation(Theme.springSnappy) { selection = key }
                        Feedback.shared.tick()
                    }
            }
        }
    }
}

struct Keycap: View {
    let key: TriggerKey
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Text(key.glyph)
                .font(.system(size: 22, weight: .medium, design: .rounded))
            Text(key.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                .lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.08 : 0.05)))
                .shadow(color: selected ? Theme.accent.opacity(0.35) : .black.opacity(0.08), radius: selected ? 8 : 1, y: selected ? 3 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .scaleEffect(selected ? 1.02 : (hovering ? 1.01 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.springSnappy, value: hovering)
    }
}

private struct ShortcutHelpRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.1)))
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Credits

struct CreditsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(AppInfo.contributors) { person in
                    HStack(spacing: 12) {
                        Avatar(name: person.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(.system(size: 13, weight: .semibold))
                            Text(person.role).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = person.url {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Contributors")
            } footer: {
                HStack {
                    Text("Klick is open source. Every contributor is listed here.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Contribute on GitHub", destination: AppInfo.repositoryURL)
                }
                .font(.system(size: 11.5))
            }

            Section("Open source") {
                ForEach(AppInfo.acknowledgements) { ack in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(ack.license)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            Link(destination: ack.url) { Image(systemName: "arrow.up.right.square") }
                        }
                    } label: {
                        Text(ack.name)
                        Text(ack.detail)
                    }
                }
            }

            Section("Thanks") {
                Text("Inspired by the weapon wheel of Grand Theft Auto V, and by everyone who sends feedback and ideas.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct Avatar: View {
    let name: String

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Circle()
            .fill(Theme.accentGradient)
            .frame(width: 34, height: 34)
            .overlay(Text(initials).font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
    }
}

// MARK: - License

struct LicensePane: View {
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            Section {
                LicenseText(text: LicenseTexts.klick)
            } header: {
                Text("Klick — MIT License")
            }

            Section {
                ForEach(AppInfo.acknowledgements) { ack in
                    DisclosureGroup("\(ack.name) — \(ack.license)", isExpanded: isExpanded(ack.name)) {
                        LicenseText(text: LicenseTexts.thirdParty(ack))
                            .padding(.top, 6)
                    }
                }
            } header: {
                Text("Third-party")
            }
        }
        .formStyle(.grouped)
    }

    private func isExpanded(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(name) },
            set: { if $0 { expanded.insert(name) } else { expanded.remove(name) } }
        )
    }
}

private struct LicenseText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(height: 260)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

enum LicenseTexts {
    static var klick: String { load("LICENSE") ?? fallbackMIT }
    static func thirdParty(_ ack: AppInfo.Acknowledgement) -> String {
        load(ack.licenseFile) ?? "See \(ack.url.absoluteString)"
    }

    private static func load(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return reflow(text)
    }

    /// License files are hard-wrapped at 80 columns; join lines inside each
    /// paragraph so the text wraps naturally to the pane's width.
    private static func reflow(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            .joined(separator: "\n\n")
    }

    private static let fallbackMIT = "MIT License\n\nCopyright (c) 2026 Giovanni D'Andrea"
}
