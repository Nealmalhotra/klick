import AppKit

/// Executes a wheel action: background jobs get a progress toast at the cursor,
/// editors open their window, instant actions just run.
@MainActor
enum ActionRunner {
    static func run(_ action: KlickAction, on items: [FileItem]) {
        switch action.kind {
        case .perFile, .batch:
            // Results go next to the originals; say so up front instead of a cryptic encoder error.
            if let folder = Set(items.map(\.directory)).first(where: { !FileManager.default.isWritableFile(atPath: $0.path) }) {
                Feedback.shared.failure()
                Toast.shared.showMessage("Can't save in “\(folder.lastPathComponent)”", symbol: "lock.fill")
                return
            }
        case .editor, .instant:
            break
        }

        switch action.kind {
        case .perFile(let verb, let work):
            runJob(verb: verb, items: items) { item, progress in try await work(item, progress) }
        case .batch(let verb, let work):
            runBatch(verb: verb, items: items, work: work)
        case .editor(let open):
            open(items)
        case .instant(let confirmation, let perform):
            perform(items)
            if let confirmation {
                Feedback.shared.success()
                Toast.shared.showMessage(confirmation)
            }
        }
    }

    private static func runJob(
        verb: String,
        items: [FileItem],
        work: @escaping (FileItem, JobProgress) async throws -> [URL]
    ) {
        let total = items.count
        var currentProgress: JobProgress?
        var task: Task<Void, Never>?
        let toast = Toast.shared.begin(title: verb, subtitle: items.first?.name ?? "") {
            currentProgress?.cancel()
            task?.cancel()
        }

        task = Task.detached(priority: .userInitiated) {
            var saved = 0
            var failure: Error?
            for (index, item) in items.enumerated() {
                let progress = JobProgress { fraction in
                    Task { @MainActor in
                        toast.update(progress: (Double(index) + fraction) / Double(total))
                    }
                }
                await MainActor.run {
                    currentProgress = progress
                    toast.update(progress: Double(index) / Double(total), subtitle: total > 1 ? "\(item.name) · \(index + 1) of \(total)" : item.name)
                }
                do {
                    _ = try await work(item, progress)
                    saved += 1
                } catch {
                    if case KlickError.cancelled = error { failure = error; break }
                    if Task.isCancelled { failure = KlickError.cancelled; break }
                    failure = error
                    NSLog("%@", "Klick: \(verb) failed for \(item.url.path): \(error)")
                }
            }
            let savedCount = saved
            let finalError = failure
            await MainActor.run {
                finish(toast: toast, saved: savedCount, total: total, error: finalError)
            }
        }
    }

    private static func runBatch(
        verb: String,
        items: [FileItem],
        work: @escaping ([FileItem], JobProgress) async throws -> [URL]
    ) {
        var task: Task<Void, Never>?
        var toastRef: ToastHandle?
        let tracked = JobProgress { fraction in
            Task { @MainActor in toastRef?.update(progress: fraction) }
        }
        let toast = Toast.shared.begin(title: verb, subtitle: items.count == 1 ? items[0].name : "\(items.count) items") {
            tracked.cancel()
            task?.cancel()
        }
        toastRef = toast
        task = Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await work(items, tracked)
                await MainActor.run { finish(toast: toast, saved: max(outputs.count, 1), total: max(outputs.count, 1), error: nil) }
            } catch {
                await MainActor.run { finish(toast: toast, saved: 0, total: 1, error: error) }
            }
        }
        _ = task
    }

    private static func finish(toast: ToastHandle, saved: Int, total: Int, error: Error?) {
        if let error, saved == 0 {
            if case KlickError.cancelled = error {
                toast.fail("Cancelled")
            } else {
                Feedback.shared.failure()
                toast.fail(error.localizedDescription)
            }
            return
        }
        Feedback.shared.success()
        toast.succeed(subtitle: "\(saved) of \(total) saved")
    }
}
