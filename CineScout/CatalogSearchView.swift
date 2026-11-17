import SwiftUI

struct CatalogSearchView: View {
    @EnvironmentObject private var model: LibraryModel
    let openSettings: () -> Void
    @State private var query = ""
    @State private var scope = CatalogSearchScope.all
    @State private var retry = 0
    @State private var activeSearch: SearchInput?
    @State private var generation = UUID()
    @State private var results = CatalogResults()
    @State private var isLoading = false
    @State private var error: String?

    private struct SearchInput: Equatable {
        let query: String
        let scope: CatalogSearchScope
        let retry: Int
    }

    private var input: SearchInput {
        SearchInput(query: query.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope, retry: retry)
    }

    var body: some View {
        NavigationStack {
            List {
                if model.tmdbKey.isEmpty {
                    ContentUnavailableView {
                        Label("Recherche TMDb", systemImage: "magnifyingglass")
                    } description: {
                        Text("Configure TMDb pour rechercher dans le catalogue.")
                    } actions: {
                        Button("Ouvrir les réglages", action: openSettings).glassButtonStyle(prominent: true)
                    }.listRowBackground(Color.clear)
                } else {
                    Picker("Type de résultat", selection: $scope) {
                        ForEach(CatalogSearchScope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)

                    searchResults
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Rechercher")
            .searchable(text: $query, prompt: "Titre français ou original")
            .task(id: input) { await startSearch(input) }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if input.query.isEmpty {
            ContentUnavailableView("Films, séries et animes", systemImage: "magnifyingglass",
                                   description: Text("Saisis un titre pour consulter sa fiche et savoir où le regarder."))
                .listRowBackground(Color.clear)
        } else if input != activeSearch || (results.items.isEmpty && isLoading) {
            ProgressView("Recherche…")
        } else {
            ForEach(results.items, id: \.key) { item in
                NavigationLink { DetailView(item: item) } label: {
                    CatalogTitleRow(item: item, owned: model.owns(item))
                }
            }
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button("Réessayer") {
                        if results.items.isEmpty { retry += 1 }
                        else { loadMore() }
                    }
                    .disabled(isLoading)
                }
            } else if results.items.isEmpty && results.nextPage == nil {
                ContentUnavailableView("Aucun titre trouvé", systemImage: "magnifyingglass",
                                       description: Text("Essaie un autre titre ou retire le filtre."))
                    .listRowBackground(Color.clear)
            } else if results.items.isEmpty {
                Text("Aucun titre correspondant dans les premiers résultats.").foregroundStyle(.secondary)
            }
            if results.nextPage != nil && error == nil {
                Button(isLoading ? "Recherche…" : "Afficher plus de résultats", action: loadMore)
                    .disabled(isLoading)
            }
        }
    }

    private func startSearch(_ request: SearchInput) async {
        let current = UUID()
        generation = current
        activeSearch = request
        results = CatalogResults()
        error = nil
        isLoading = false
        guard !request.query.isEmpty, !model.tmdbKey.isEmpty else { return }
        isLoading = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            guard input == request, generation == current else { return }
            isLoading = false
            await load(request, generation: current)
        } catch {
            if generation == current { isLoading = false }
        }
    }

    private func loadMore() {
        let request = input
        let current = generation
        Task { await load(request, generation: current) }
    }

    private func load(_ request: SearchInput, generation current: UUID) async {
        guard activeSearch == request, input == request, generation == current, !isLoading,
              results.nextPage != nil else { return }
        isLoading = true
        error = nil
        defer {
            if generation == current { isLoading = false }
        }
        do {
            for _ in 0..<3 {
                guard let page = results.nextPage else { break }
                let endpoint = TMDbCatalog.search(request.query, scope: request.scope, page: page)
                let response: TMPage = try await model.catalog(endpoint)
                try Task.checkCancellation()
                guard generation == current, input == request else { return }
                if results.append(response, page: page, including: request.scope.includes) { break }
            }
        } catch {
            if !Task.isCancelled, generation == current, input == request {
                self.error = error.localizedDescription
            }
        }
    }
}

struct CatalogTitleRow: View {
    let item: TMItem
    var owned = false

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Poster(path: item.poster_path, cornerRadius: 8).frame(width: 51)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.display).font(.headline)
                Text(([item.kindLabel] + [item.releaseDateText].compactMap { $0 }).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if owned {
                    Label("Dans Jellyfin", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
