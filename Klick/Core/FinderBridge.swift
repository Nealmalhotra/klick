import AppKit
import Carbon.HIToolbox

/// Reads the current Finder selection through a raw Apple Event
/// (`get selection as alias list`), which is fast and safe off the main thread.
enum FinderBridge {
    static let bundleID = "com.apple.finder"

    enum AutomationStatus {
        case granted, denied, notDetermined, finderNotRunning
    }

    static var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Asynchronously fetches selected file URLs (empty when nothing is selected).
    static func fetchSelection(completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let result = Result { try selection() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .failure(let error as NSError) = result, !isPermissionError(error) {
                        // Fall back to the AppleScript engine before giving up.
                        completion(Result { try scriptSelection() })
                    } else {
                        completion(result)
                    }
                }
            }
        }
    }

    static func isPermissionError(_ error: NSError) -> Bool {
        [Int(errAEEventNotPermitted), -1744 /* errAEEventWouldRequireUserConsent */].contains(error.code)
    }

    /// AppleScript fallback (main thread only).
    @MainActor
    static func scriptSelection() throws -> [URL] {
        guard let script = NSAppleScript(source: "tell application \"Finder\" to get selection as alias list") else { return [] }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let code = info[NSAppleScript.errorNumber] as? Int ?? -1
            let message = info[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            throw NSError(domain: NSOSStatusErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return urls(in: result)
    }

    /// Synchronous variant (blocks up to ~2s).
    static func selection() throws -> [URL] {
        let finder = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEGetData),
            targetDescriptor: finder,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        // `selection` property of the application.
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("sele")), forKeyword: AEKeyword(keyAEKeyData))
        guard let objectSpecifier = specifier.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { return [] }

        event.setParam(objectSpecifier, forKeyword: AEKeyword(keyDirectObject))
        event.setParam(NSAppleEventDescriptor(typeCode: fourCC("alst")), forKeyword: AEKeyword(keyAERequestedType))

        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 2)
        guard let list = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }

        return urls(in: list)
    }

    private static func urls(in list: NSAppleEventDescriptor) -> [URL] {
        if list.descriptorType != DescType(typeAEList) {
            return list.fileURLValue.map { [$0] } ?? []
        }
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { index in
            guard let item = list.atIndex(index) else { return nil }
            if let url = item.fileURLValue { return url }
            return item.coerce(toDescriptorType: DescType(typeFileURL))?.fileURLValue
        }
    }

    /// Checks (and optionally asks for) permission to automate Finder.
    static func automationStatus(prompt: Bool) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .notDetermined }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)
        switch Int(status) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .denied
        case Int(procNotFound): return .finderNotRunning
        default: return .notDetermined
        }
    }

    private static func fourCC(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
