import SwiftUI

/// An inline discovery view; it shares the popup window rather than creating another panel.
struct AutoEQSearchPanel: View {
    let profileManager: AutoEQProfileManager
    let favoriteIDs: Set<String>
    let selectedProfileID: String?
    let onSelect: (AutoEQProfile?) -> Void
    let onDismiss: () -> Void
    let onImport: () -> Void
    let onToggleFavorite: (String) -> Void
    let importErrorMessage: String?

    @State private var searchText = ""
    @State private var query = ""
    @State private var browserEntries: [AutoEQCatalogEntry] = []
    @State private var localIDs: Set<String> = []
    @State private var searchResult = AutoEQSearchResult(entries: [], totalCount: 0)
    @State private var highlightedID: String?
    @State private var hoveredID: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectionRequest = AutoEQBrowserSelection()
    @State private var lastRequestedEntry: AutoEQCatalogEntry?
    @State private var owner = UUID()
    @State private var isActive = false
    @Environment(\.popupInlineEditor) private var inlineEditor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDebouncing: Bool { searchText.trimmingCharacters(in: .whitespacesAndNewlines) != query }
    private var favorites: [AutoEQCatalogEntry] { browserEntries.filter { favoriteIDs.contains($0.id) } }
    private var localEntries: [AutoEQCatalogEntry] { browserEntries.filter { localIDs.contains($0.id) && !favoriteIDs.contains($0.id) } }
    // Keep the manager’s relevance order; favorites must not outrank an exact match.
    private var rankedResults: [AutoEQCatalogEntry] { searchResult.entries }
    private var navigableEntries: [AutoEQCatalogEntry] { query.isEmpty ? favorites + localEntries : rankedResults }
    private var catalogIsLoading: Bool { profileManager.catalogState == .loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: close) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Back to correction")
                Spacer()
                Text("Headphone Profiles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: { close(); onImport() }) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Import ParametricEQ.txt")
                    .accessibilityLabel("Import custom profile")
            }

            AutoEQSearchField(text: $searchText) { command in
                switch command {
                case .up: moveHighlight(-1)
                case .down: moveHighlight(1)
                case .select:
                    if !isDebouncing, let entry = navigableEntries.first(where: { $0.id == highlightedID }) { select(entry) }
                case .cancel: close()
                }
            }
            .frame(height: 26)

            resultsArea
                .frame(height: 210)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            statusArea

            HStack {
                if selectedProfileID != nil {
                    Button("Remove Correction") { onSelect(nil); close() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if !query.isEmpty && searchResult.totalCount > 0 && !isDebouncing {
                    let shown = searchResult.entries.count
                    Text(searchResult.totalCount > shown ? "\(shown) of \(searchResult.totalCount) matches" : "\(shown) matches")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 18)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            isActive = true
            refreshEntries()
            let request = selectionRequest
            let dismiss = onDismiss
            inlineEditor?.register(owner: owner) { request.cancel(); dismiss() }
            loadCatalog()
        }
        .onDisappear {
            isActive = false
            debounceTask?.cancel()
            selectionRequest.cancel()
            inlineEditor?.unregister(owner: owner)
        }
        .onChange(of: searchText) { _, value in
            selectionRequest.cancel()
            highlightedID = nil
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, isActive else { return }
                query = value.trimmingCharacters(in: .whitespacesAndNewlines)
                searchResult = profileManager.search(query: query)
            }
        }
        .onChange(of: profileManager.catalogState) { _, _ in refreshEntries() }
        .onChange(of: profileManager.profiles.count) { _, _ in refreshEntries() }
        .onChange(of: favoriteIDs) { _, _ in
            if let id = highlightedID, !navigableEntries.contains(where: { $0.id == id }) { highlightedID = nil }
        }
    }

    @ViewBuilder private var resultsArea: some View {
        if isDebouncing {
            placeholder("Searching…", symbol: "magnifyingglass", progress: true)
        } else if !navigableEntries.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if query.isEmpty {
                            section("Favorites", entries: favorites)
                            section("On This Mac", entries: localEntries)
                        } else {
                            ForEach(rankedResults) { entry in row(entry).id(entry.id) }
                        }
                    }.padding(5)
                }
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        } else if catalogIsLoading {
            placeholder("Loading headphone catalog…", symbol: "arrow.down.circle", progress: true)
        } else if case .error = profileManager.catalogState {
            placeholder("Catalog unavailable", symbol: "wifi.slash", detail: "Retry below, or import a profile from this Mac.")
        } else if query.isEmpty {
            placeholder("Find your headphones", symbol: "headphones", detail: "Search by brand or model, or import a profile.")
        } else if profileManager.catalogState == .idle {
            placeholder("Catalog not loaded", symbol: "arrow.down.circle", detail: "Load the catalog to search online profiles.")
        } else {
            placeholder("No matching profiles", symbol: "magnifyingglass", detail: "Try another model name or a shorter search.")
        }
    }

    @ViewBuilder private var statusArea: some View {
        if let error = selectionRequest.errorMessage {
            notice(error, retry: { if let entry = lastRequestedEntry { select(entry) } })
        } else if let error = importErrorMessage {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if case .error = profileManager.catalogState {
            notice("The online catalog couldn’t be loaded. Profiles on this Mac remain available.", retry: { loadCatalog(retry: true) })
        } else if catalogIsLoading && !navigableEntries.isEmpty {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Updating catalog…").font(.caption).foregroundStyle(.secondary) }
        } else if profileManager.catalogState == .idle {
            Button("Load Catalog") { loadCatalog() }.buttonStyle(.borderless)
        } else {
            Text("↑ ↓ to browse · Return to apply · Esc to go back")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ title: String, symbol: String, detail: String? = nil, progress: Bool = false) -> some View {
        VStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.secondary) }
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
    }

    @ViewBuilder private func section(_ title: String, entries: [AutoEQCatalogEntry]) -> some View {
        if !entries.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 5)
            ForEach(entries) { entry in row(entry).id(entry.id) }
        }
    }

    private func row(_ entry: AutoEQCatalogEntry) -> some View {
        let selected = entry.id == selectedProfileID
        let favorite = favoriteIDs.contains(entry.id)
        let loading = selectionRequest.loadingProfileID == entry.id
        return HStack(spacing: 6) {
            Button { select(entry) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                        Text(entry.measuredBy).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if loading { ProgressView().controlSize(.mini) }
                    else if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.name)
            .accessibilityLabel("Apply \(entry.name), \(entry.measuredBy)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { onToggleFavorite(entry.id) } label: {
                Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(favorite ? "Remove" : "Add") \(entry.name) \(favorite ? "from" : "to") favorites")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((highlightedID == entry.id || hoveredID == entry.id) ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { entered in hoveredID = entered ? entry.id : nil }
    }

    private func notice(_ text: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry", action: retry).buttonStyle(.borderless)
        }
    }

    private func refreshEntries() {
        browserEntries = profileManager.refreshBrowserEntries()
        localIDs = Set(profileManager.profiles.keys)
        searchResult = profileManager.search(query: query)
        if let id = highlightedID, !navigableEntries.contains(where: { $0.id == id }) { highlightedID = nil }
    }

    private func loadCatalog(retry: Bool = false) {
        Task { @MainActor in
            await profileManager.loadCatalogForBrowsing(retry: retry)
            if isActive { refreshEntries() }
        }
    }

    private func select(_ entry: AutoEQCatalogEntry) {
        guard !isDebouncing else { return }
        lastRequestedEntry = entry
        selectionRequest.select(entry, resolve: { await profileManager.resolveProfile(for: $0) }) { profile in
            onSelect(profile)
            close()
        }
    }

    private func moveHighlight(_ direction: Int) {
        let entries = navigableEntries
        guard !isDebouncing, !entries.isEmpty else { return }
        let next: Int
        if let id = highlightedID, let current = entries.firstIndex(where: { $0.id == id }) { next = min(entries.count - 1, max(0, current + direction)) }
        else { next = direction > 0 ? 0 : entries.count - 1 }
        hoveredID = nil
        highlightedID = entries[next].id
    }

    private func close() {
        debounceTask?.cancel()
        selectionRequest.cancel()
        inlineEditor?.unregister(owner: owner)
        onDismiss()
    }
}
