import Foundation

/// Something a wheel segment can do with the selected files.
struct KlickAction: Identifiable {
    enum Kind {
        /// Runs once per file in the background; returns the files it produced.
        case perFile(verb: String, work: (FileItem, JobProgress) async throws -> [URL])
        /// Runs once for the whole selection (merge, zip, ...).
        case batch(verb: String, work: ([FileItem], JobProgress) async throws -> [URL])
        /// Opens a floating editor window (crop, add background, ...).
        case editor(@MainActor ([FileItem]) -> Void)
        /// Immediate side effect (copy path, AirDrop, ...). Optional confirmation text for the toast.
        case instant(confirmation: String?, perform: @MainActor ([FileItem]) -> Void)
    }

    /// Stable identifier, e.g. `convert.jpg`, `tool.crop`.
    let id: String
    /// Uppercase label rendered on the segment ("JPG", "ADD BG").
    let title: String
    /// Optional SF Symbol drawn above the label (tools page).
    let symbol: String?
    let kind: Kind

    init(id: String, title: String, symbol: String? = nil, kind: Kind) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
    }
}

/// One ring of the wheel. Users flip between pages with Tab / scroll / right click.
struct WheelPage: Identifiable {
    let id: String
    let title: String
    let actions: [KlickAction]
}

/// Thread-safe progress + cancellation token handed to background work.
final class JobProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction: Double = 0
    private var cancelled = false
    private var handler: (@Sendable (Double) -> Void)?

    init(onChange: (@Sendable (Double) -> Void)? = nil) {
        handler = onChange
    }

    /// Reports progress of the *current file* in 0...1.
    func report(_ value: Double) {
        lock.lock()
        fraction = min(max(value, 0), 1)
        let handler = self.handler
        let current = fraction
        lock.unlock()
        handler?(current)
    }

    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return fraction
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func checkCancelled() throws {
        if isCancelled { throw KlickError.cancelled }
    }
}

enum KlickError: LocalizedError {
    case cancelled
    case unreadable(String)
    case unsupported(String)
    case failed(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .unreadable(let name): return "Couldn't read \(name)"
        case .unsupported(let what): return "\(what) isn't supported"
        case .failed(let why): return why
        case .notImplemented(let what): return "\(what) is coming soon"
        }
    }
}
