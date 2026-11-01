import Foundation

/// Owns a user selection until it completes or its browser is closed/replaced.
@Observable @MainActor
final class AutoEQBrowserSelection {
    private(set) var loadingProfileID: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    @discardableResult
    func select(
        _ entry: AutoEQCatalogEntry,
        resolve: @escaping @MainActor (AutoEQCatalogEntry) async -> AutoEQProfile?,
        apply: @escaping @MainActor (AutoEQProfile) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let request = generation
        loadingProfileID = entry.id
        let operation = Task { @MainActor [weak self] in
            let profile = await resolve(entry)
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.task = nil
            self.loadingProfileID = nil
            if let profile {
                apply(profile)
            } else {
                self.errorMessage = "Couldn’t load \(entry.name). Try again or choose another profile."
            }
        }
        task = operation
        return operation
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        loadingProfileID = nil
        errorMessage = nil
    }
}
