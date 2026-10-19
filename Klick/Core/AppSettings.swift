import Combine
import CoreGraphics
import Foundation
import ServiceManagement

/// The modifier the user holds to summon the wheel.
enum TriggerKey: String, CaseIterable, Identifiable {
    case shift, leftShift, rightShift, option, control, command, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: return "Shift"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .option: return "Option"
        case .control: return "Control"
        case .command: return "Command"
        case .fn: return "Fn / Globe"
        }
    }

    /// Glyph rendered on the keycap.
    var glyph: String {
        switch self {
        case .shift, .leftShift, .rightShift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        case .fn: return "fn"
        }
    }

    var sideHint: String? {
        switch self {
        case .leftShift: return "left"
        case .rightShift: return "right"
        default: return nil
        }
    }

    /// Two keys clash when they read the same modifier flag (Shift and Left Shift do).
    func conflicts(with other: TriggerKey) -> Bool {
        requiredFlag == other.requiredFlag
    }

    private static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
    private static let leftShiftBit: UInt64 = 0x02
    private static let rightShiftBit: UInt64 = 0x04

    private var requiredFlag: CGEventFlags {
        switch self {
        case .shift, .leftShift, .rightShift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        case .fn: return .maskSecondaryFn
        }
    }

    /// True when exactly this modifier (and nothing else) is held.
    func isHeld(in flags: CGEventFlags) -> Bool {
        guard flags.intersection(Self.modifierMask) == requiredFlag else { return false }
        switch self {
        case .leftShift: return flags.rawValue & Self.leftShiftBit != 0 && flags.rawValue & Self.rightShiftBit == 0
        case .rightShift: return flags.rawValue & Self.rightShiftBit != 0 && flags.rawValue & Self.leftShiftBit == 0
        default: return true
        }
    }

    /// True when this modifier is involved at all (used to wait for a full release).
    func isInvolved(in flags: CGEventFlags) -> Bool {
        flags.contains(requiredFlag)
    }

    static func anyModifier(in flags: CGEventFlags) -> Bool {
        !flags.intersection(modifierMask).isEmpty
    }
}

/// The three wheels of the original: one per trigger key.
enum WheelKind: String, CaseIterable, Identifiable {
    case convert, tools, file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .file: return "File actions"
        }
    }

    /// `WheelPage.id` the wheel opens on.
    var pageID: String {
        switch self {
        case .convert: return ActionCatalog.PageID.convert
        case .tools: return ActionCatalog.PageID.tools
        case .file: return ActionCatalog.PageID.file
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    /// Key for the Convert wheel (the main gesture).
    @Published var trigger: TriggerKey {
        didSet {
            defaults.set(trigger.rawValue, forKey: Keys.trigger)
            if toolsTrigger?.conflicts(with: trigger) == true { toolsTrigger = nil }
            if fileTrigger?.conflicts(with: trigger) == true { fileTrigger = nil }
        }
    }
    /// Key for the Tools wheel; nil turns it off (Tools stays reachable with Tab).
    @Published var toolsTrigger: TriggerKey? {
        didSet {
            defaults.set(toolsTrigger?.rawValue ?? Keys.off, forKey: Keys.toolsTrigger)
            if let toolsTrigger, fileTrigger?.conflicts(with: toolsTrigger) == true { fileTrigger = nil }
        }
    }
    /// Key for the File actions wheel; nil turns it off.
    @Published var fileTrigger: TriggerKey? {
        didSet {
            defaults.set(fileTrigger?.rawValue ?? Keys.off, forKey: Keys.fileTrigger)
            if let fileTrigger, toolsTrigger?.conflicts(with: fileTrigger) == true { toolsTrigger = nil }
        }
    }
    /// Tapping a trigger while dragging files opens the wheel; dropping on a segment runs it.
    @Published var dragToOpen: Bool { didSet { defaults.set(dragToOpen, forKey: Keys.dragToOpen) } }
    /// Seconds the trigger must be held before the wheel appears.
    @Published var holdDelay: Double { didSet { defaults.set(holdDelay, forKey: Keys.holdDelay) } }
    @Published var finderOnly: Bool { didSet { defaults.set(finderOnly, forKey: Keys.finderOnly) } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Keys.sounds) } }
    @Published var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: Keys.volume) } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) } }
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("%@", "Klick: launch at login failed: \(error)")
            }
        }
    }

    private enum Keys {
        static let trigger = "trigger"
        static let toolsTrigger = "toolsTrigger"
        static let fileTrigger = "fileTrigger"
        static let dragToOpen = "dragToOpen"
        static let off = "off"
        static let holdDelay = "holdDelay"
        static let finderOnly = "finderOnly"
        static let sounds = "soundsEnabled"
        static let volume = "soundVolume"
        static let haptics = "hapticsEnabled"
        static let enabled = "isEnabled"
        static let onboarding = "hasCompletedOnboarding"
    }

    private init() {
        defaults.register(defaults: [
            Keys.trigger: TriggerKey.shift.rawValue,
            Keys.toolsTrigger: TriggerKey.command.rawValue,
            Keys.fileTrigger: TriggerKey.control.rawValue,
            Keys.dragToOpen: true,
            Keys.holdDelay: 0.2,
            Keys.finderOnly: true,
            Keys.sounds: true,
            Keys.volume: 0.6,
            Keys.haptics: true,
            Keys.enabled: true,
            Keys.onboarding: false,
        ])
        trigger = TriggerKey(rawValue: defaults.string(forKey: Keys.trigger) ?? "") ?? .shift
        toolsTrigger = TriggerKey(rawValue: defaults.string(forKey: Keys.toolsTrigger) ?? "")
        fileTrigger = TriggerKey(rawValue: defaults.string(forKey: Keys.fileTrigger) ?? "")
        dragToOpen = defaults.bool(forKey: Keys.dragToOpen)
        holdDelay = defaults.double(forKey: Keys.holdDelay)
        finderOnly = defaults.bool(forKey: Keys.finderOnly)
        soundsEnabled = defaults.bool(forKey: Keys.sounds)
        soundVolume = defaults.double(forKey: Keys.volume)
        hapticsEnabled = defaults.bool(forKey: Keys.haptics)
        isEnabled = defaults.bool(forKey: Keys.enabled)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
    }

    /// Configured wheels with their keys, Convert first.
    var wheelTriggers: [(wheel: WheelKind, key: TriggerKey)] {
        [(WheelKind.convert, trigger)]
            + (toolsTrigger.map { [(WheelKind.tools, $0)] } ?? [])
            + (fileTrigger.map { [(WheelKind.file, $0)] } ?? [])
    }

    func key(for wheel: WheelKind) -> TriggerKey? {
        switch wheel {
        case .convert: return trigger
        case .tools: return toolsTrigger
        case .file: return fileTrigger
        }
    }
}
