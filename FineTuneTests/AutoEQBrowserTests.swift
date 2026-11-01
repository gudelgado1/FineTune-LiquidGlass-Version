import Foundation
import Testing
@testable import FineTune

@Suite("AutoEQ browser request ownership")
@MainActor struct AutoEQBrowserTests {
    private let entry = AutoEQCatalogEntry(id: "qa", name: "QA headphones", measuredBy: "QA", relativePath: "qa")
    private let profile = AutoEQProfile(id: "qa", name: "QA headphones", source: .fetched, preampDB: -3, filters: [])

    @Test("closing the browser rejects a late successful fetch")
    func closeWhileLoading() async {
        let request = AutoEQBrowserSelection()
        let started = AsyncStream<Void>.makeStream()
        var pending: CheckedContinuation<AutoEQProfile?, Never>?
        var applied: [String] = []
        let operation = request.select(entry, resolve: { _ in
            await withCheckedContinuation { pending = $0; started.continuation.yield(()) }
        }, apply: { applied.append($0.id) })
        for await _ in started.stream { break }
        #expect(request.loadingProfileID == entry.id)
        request.cancel()
        pending?.resume(returning: profile)
        await operation.value
        #expect(applied.isEmpty)
        #expect(request.loadingProfileID == nil)
        #expect(request.errorMessage == nil)
    }

    @Test("a newer selection wins even when the earlier resolver ignores cancellation")
    func newerSelectionWins() async {
        let request = AutoEQBrowserSelection()
        let started = AsyncStream<Void>.makeStream()
        var pending: CheckedContinuation<AutoEQProfile?, Never>?
        var applied: [String] = []
        let first = request.select(entry, resolve: { _ in
            await withCheckedContinuation { pending = $0; started.continuation.yield(()) }
        }, apply: { applied.append($0.id) })
        for await _ in started.stream { break }
        let other = AutoEQProfile(id: "new", name: "New", source: .imported, preampDB: 0, filters: [])
        let second = request.select(entry, resolve: { _ in other }, apply: { applied.append($0.id) })
        await second.value
        pending?.resume(returning: profile)
        await first.value
        #expect(applied == ["new"])
        #expect(request.loadingProfileID == nil)
    }

    @Test("a failed download stays unapplied and a retry clears the error")
    func retrySelection() async {
        let request = AutoEQBrowserSelection()
        var applied: [String] = []
        await request.select(entry, resolve: { _ in nil }, apply: { applied.append($0.id) }).value
        #expect(request.errorMessage?.contains(entry.name) == true)
        #expect(applied.isEmpty)
        #expect(request.loadingProfileID == nil)
        await request.select(entry, resolve: { _ in profile }, apply: { applied.append($0.id) }).value
        #expect(applied == [entry.id])
        #expect(request.errorMessage == nil)
    }
}

@Suite("Popup inline editor dismissal")
@MainActor struct PopupInlineEditorTests {
    @Test("Escape dismisses the current editor once")
    func dismissOnce() {
        let context = PopupInlineEditorContext()
        var closes = 0
        context.register(owner: UUID()) { closes += 1 }
        #expect(context.isPresented)
        #expect(context.dismissCurrent())
        #expect(!context.dismissCurrent())
        #expect(!context.isPresented)
        #expect(closes == 1)
    }

    @Test("teardown of a replaced editor cannot unregister its replacement")
    func staleTeardown() {
        let context = PopupInlineEditorContext()
        let first = UUID(), second = UUID()
        var firstCloses = 0, secondCloses = 0
        context.register(owner: first) { firstCloses += 1 }
        context.register(owner: second) { secondCloses += 1 }
        context.unregister(owner: first)
        #expect(firstCloses == 1)
        #expect(context.isPresented)
        #expect(context.dismissCurrent())
        #expect(secondCloses == 1)
    }
}

private final class OfflineCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@Suite("AutoEQ browser offline catalog")
@MainActor struct AutoEQBrowserCatalogTests {
    @Test("failed refresh keeps cached profiles searchable and exits loading")
    func cachedCatalogSurvivesFailedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = AutoEQCatalogEntry(id: "cached", name: "Cached Headphones", measuredBy: "QA", relativePath: "QA")
        try JSONEncoder().encode([entry]).write(to: root.appendingPathComponent("autoeq-catalog.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineCatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fetcher = AutoEQFetcher(session: session, cacheDirectory: root)
        await fetcher.loadCatalog()
        #expect(fetcher.catalogState == .loaded)
        let manager = AutoEQProfileManager(fetcher: fetcher)
        await manager.loadCatalogForBrowsing(retry: true)
        guard case .error = fetcher.catalogState else {
            Issue.record("Offline refresh must report a recoverable error, not remain loading")
            return
        }
        #expect(fetcher.catalog == [entry])
        #expect(manager.search(query: "Cached").entries.contains(entry))
    }
}
