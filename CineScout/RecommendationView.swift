import SwiftUI

enum RecommendationSection: String, CaseIterable, Identifiable {
    case cinema, streaming, classics

    var id: Self { self }

    var title: String {
        switch self {
        case .cinema: "Au cinéma"
        case .streaming: "En streaming"
        case .classics: "À redécouvrir"
        }
    }

    var symbol: String {
        switch self {
        case .cinema: "ticket"
        case .streaming: "play.tv"
        case .classics: "text.book.closed"
        }
    }
}

struct RecommendationLinks: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let openSettings: () -> Void

    var body: some View {
        let layout = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 9))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 9))
        layout {
            ForEach(RecommendationSection.allCases) { section in
                NavigationLink {
                    RecommendationView(section: section, openSettings: openSettings)
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: section.symbol)
                            .font(.title3.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .padding(.vertical, 4)
                }
                .buttonBorderShape(.roundedRectangle(radius: 18))
                .glassButtonStyle()
            }
        }
    }
}

struct RecommendationView: View {
    @EnvironmentObject private var model: LibraryModel
    let section: RecommendationSection
    let openSettings: () -> Void

    @State private var kind = StreamingMedia.movie
    @State private var provider: Int?
    @State private var providers: [WatchProvider] = []
    @State private var loadingProviders = false
    @State private var providerError: String?
    @State private var results = CatalogResults()
    @State private var activeFeed: Feed?
    @State private var generation = UUID()
    @State private var error: String?
    @State private var loading = false

    private struct Feed: Equatable {
        let kind: StreamingMedia
        let provider: Int?
        let configured: Bool
    }

    private var feed: Feed { Feed(kind: kind, provider: provider, configured: !model.tmdbKey.isEmpty) }
    private var visible: [TMItem] { results.items.filter(model.canSuggest) }

    var body: some View {
        List {
            if section == .classics {
                Section {
                    let picks = EditorialPick.selection.filter { model.canSuggest($0.item) }
                    if picks.isEmpty {
                        ContentUnavailableView("Sélection déjà dans Jellyfin", systemImage: section.symbol)
                    }
                    ForEach(picks) { pick in
                        NavigationLink {
                            DetailView(item: pick.item)
                        } label: {
                            EditorialPickRow(pick: pick)
                        }
                    }
                } header: {
                    Text("Notes de CinéScout")
                }
            } else if !feed.configured {
                ContentUnavailableView {
                    Label("Catalogue TMDb", systemImage: section.symbol)
                } description: {
                    Text("Configure TMDb pour consulter cette sélection.")
                } actions: {
                    Button("Ouvrir les réglages", action: openSettings).glassButtonStyle(prominent: true)
                }
                .listRowBackground(Color.clear)
            } else {
                if section == .streaming { streamingControls }
                Section {
                    recommendationRows
                } header: {
                    Text(section == .cinema ? "Sorties des 35 derniers jours en France" : "Disponibles en France")
                } footer: {
                    Text(section == .cinema
                         ? "Les dates de sortie proviennent de TMDb. Consulte ton cinéma pour les séances."
                         : "Offres par abonnement, gratuites ou avec publicité. Disponibilités JustWatch via TMDb.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: feed) {
            if section != .classics { await startFeed(feed) }
        }
        .task(id: kind) {
            if section == .streaming && feed.configured { await loadProviders(kind) }
        }
        .refreshable {
            if section != .classics { await startFeed(feed) }
        }
    }

    private var streamingControls: some View {
        Section {
            Picker("Type", selection: Binding(get: { kind }, set: { value in
                guard kind != value else { return }
                provider = nil
                providers = []
                providerError = nil
                kind = value
            })) {
                ForEach(StreamingMedia.allCases) { kind in Text(kind.label).tag(kind) }
            }.pickerStyle(.segmented)

            Picker("Plateforme", selection: $provider) {
                Text("Toutes").tag(nil as Int?)
                ForEach(providers) { provider in
                    Text(provider.provider_name).tag(Optional(provider.id))
                }
            }
            .disabled(loadingProviders || providers.isEmpty)

            if loadingProviders {
                ProgressView("Chargement des plateformes…")
            } else if let providerError {
                Text(providerError).font(.footnote).foregroundStyle(.secondary)
                Button("Recharger les plateformes") {
                    let selected = kind
                    Task { await loadProviders(selected) }
                }
            }
        }
    }

    @ViewBuilder private var recommendationRows: some View {
        if activeFeed != feed || (visible.isEmpty && loading) {
            ProgressView("Chargement…")
        } else {
            ForEach(visible, id: \.key) { item in
                NavigationLink { DetailView(item: item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        CatalogTitleRow(item: item, owned: model.owns(item))
                        if !model.owns(item) { TorrentIndicator(item: item).font(.caption) }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Réessayer", action: loadMore)
            } else if visible.isEmpty {
                Text(results.nextPage == nil ? "Aucune suggestion disponible." : "Aucune suggestion sur les premières pages.")
                    .foregroundStyle(.secondary)
            }
            if results.nextPage != nil && error == nil {
                Button(loading ? "Chargement…" : "Afficher plus de titres", action: loadMore).disabled(loading)
            }
        }
    }

    private func loadProviders(_ requestedKind: StreamingMedia) async {
        loadingProviders = true
        providerError = nil
        defer { if requestedKind == kind { loadingProviders = false } }
        do {
            let directory: WatchProviderDirectory = try await model.catalog(TMDbCatalog.providers(requestedKind))
            try Task.checkCancellation()
            guard requestedKind == kind else { return }
            var seen = Set<Int>()
            providers = directory.results.filter { seen.insert($0.id).inserted }
                .sorted { $0.provider_name.localizedStandardCompare($1.provider_name) == .orderedAscending }
        } catch {
            if !Task.isCancelled, requestedKind == kind { providerError = error.localizedDescription }
        }
    }

    private func startFeed(_ requested: Feed) async {
        generation = UUID()
        activeFeed = requested
        results = CatalogResults()
        error = nil
        loading = false
        guard requested.configured else { return }
        await load(requested, generation: generation)
    }

    private func loadMore() {
        let requested = feed
        let current = generation
        Task { await load(requested, generation: current) }
    }

    private func load(_ requested: Feed, generation current: UUID) async {
        guard activeFeed == requested, feed == requested, generation == current, !loading,
              results.nextPage != nil else { return }
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            for _ in 0..<3 {
                guard let page = results.nextPage else { break }
                let endpoint = section == .cinema ? TMDbCatalog.cinema(page: page)
                    : TMDbCatalog.streaming(requested.kind, provider: requested.provider, page: page)
                let response: TMPage = try await model.catalog(endpoint)
                try Task.checkCancellation()
                guard feed == requested, generation == current else { return }
                if results.append(response, page: page, including: model.canSuggest) { break }
            }
        } catch {
            if !Task.isCancelled, feed == requested, generation == current { self.error = error.localizedDescription }
        }
    }
}

private struct EditorialPickRow: View {
    @EnvironmentObject private var model: LibraryModel
    let pick: EditorialPick
    @State private var poster: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 13) {
                Poster(path: poster ?? pick.item.poster_path, cornerRadius: 8).frame(width: 51)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pick.item.display).font(.headline)
                    Text("\(pick.item.kindLabel) · \(pick.year.formatted(.number.grouping(.never)))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(pick.note).font(.subheadline).foregroundStyle(.secondary)
            Label(pick.critic, systemImage: "text.book.closed").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task {
            guard poster == nil, pick.item.poster_path == nil, !model.tmdbKey.isEmpty else { return }
            let item: TMItem? = try? await model.catalog(TMDbCatalog.title(pick.item))
            if !Task.isCancelled { poster = item?.poster_path }
        }
    }
}
