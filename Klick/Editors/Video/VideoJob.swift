import AppKit

/// Video exports take a while, so an editor closes as soon as you hit Save and the work
/// continues behind a progress toast (with a cancel button), like any wheel action.
@MainActor
enum VideoJob {
    static func start(_ verb: String, item: FileItem, work: @escaping (JobProgress) async throws -> [URL]) {
        var task: Task<Void, Never>?
        var toastRef: ToastHandle?
        let progress = JobProgress { fraction in
            Task { @MainActor in toastRef?.update(progress: fraction) }
        }
        let toast = Toast.shared.begin(title: verb, subtitle: item.name) {
            progress.cancel()
            task?.cancel()
        }
        toastRef = toast
        task = Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await work(progress)
                await MainActor.run {
                    Feedback.shared.success()
                    toast.succeed(subtitle: outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files saved")
                }
            } catch {
                NSLog("%@", "Klick: \(verb) failed for \(item.url.path): \(error)")
                await MainActor.run {
                    if case KlickError.cancelled = error {
                        toast.fail("Cancelled")
                    } else {
                        Feedback.shared.failure()
                        toast.fail(error.localizedDescription)
                    }
                }
            }
        }
        _ = task
    }
}
