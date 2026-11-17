import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    let openSettings: () -> Void
    @State private var showsFilters = false

    private var suggestions: [TMItem] {
        model.discoveries.filter { $0.kind == model.mediaType && model.canSuggest($0) }
    }

    var body: some View {
        NavigationStack {
            discoveryWithControls
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Découvrir")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: model.mediaType) { _, _ in
                    model.genre = ""
                    Task { await model.discover() }
                }
                .sheet(isPresented: $showsFilters) { DiscoveryFilters(model: model) }
                .refreshable { await model.discover() }
        }
    }

    @ViewBuilder private var discoveryWithControls: some View {
        if #available(iOS 26.0, *) {
            catalogue.safeAreaBar(edge: .top, spacing: 0) { catalogueBar }
        } else {
            catalogue.safeAreaInset(edge: .top, spacing: 0) {
                catalogueBar.background(.regularMaterial)
            }
        }
    }

    private var catalogueBar: some View {
        GlassControlGroup(spacing: 8) {
            HStack(spacing: 8) {
                if dynamicType.isAccessibilitySize {
                    Picker("Catalogue", selection: $model.mediaType) {
                        Text("Films").tag("movie")
                        Text("Séries").tag("tv")
                    }
                    .pickerStyle(.menu)
                    .glassButtonStyle()
                    .disabled(model.busy)
                } else {
                    scopeButton("Films", kind: "movie")
                    scopeButton("Séries", kind: "tv")
                }
                Spacer(minLength: 4)
                Button("Filtres", systemImage: "slider.horizontal.3") { showsFilters = true }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .glassButtonStyle()
                    .disabled(model.busy || model.tmdbKey.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: 900)
    }

    private func scopeButton(_ title: String, kind: String) -> some View {
        let selected = model.mediaType == kind
        let foreground = selected ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary
        return Button {
            model.mediaType = kind
        } label: {
            Text(title).foregroundStyle(foreground)
        }
        .buttonBorderShape(.capsule)
        .glassButtonStyle(prominent: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(model.busy)
    }

    private var catalogue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let featured = suggestions.first {
                    Text(model.personalized && model.genre.isEmpty && model.hasTasteProfile
                         ? "Pour toi" : "À la une")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    featuredCard(featured)
                }

                NavigationLink {
                    RouletteView(openSettings: openSettings)
                } label: {
                    Label("Roulette", systemImage: "die.face.5")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
                .controlSize(.large)
                .glassButtonStyle(prominent: true)

                RecommendationLinks(openSettings: openSettings)

                catalogueFeedback

                if suggestions.count > 1 {
                    Text("À explorer").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 16, alignment: .top)], spacing: 22) {
                        ForEach(suggestions.dropFirst(), id: \.key, content: movieCard)
                    }
                }

                if model.hasMore && !model.tmdbKey.isEmpty {
                    Button(model.busy ? "Chargement…" : "Afficher plus de titres") {
                        Task { await model.discover(more: true) }
                    }
                    .glassButtonStyle()
                    .disabled(model.busy)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var catalogueFeedback: some View {
        if model.tmdbKey.isEmpty {
            ContentUnavailableView {
                Label("Découvrir des titres", systemImage: "sparkles.tv")
            } description: {
                Text("Connecte TMDb pour explorer les films et les séries.")
            } actions: {
                Button("Configurer TMDb", action: openSettings).glassButtonStyle(prominent: true)
            }
        } else if !model.discoveryMessage.isEmpty {
            Label(model.discoveryMessage, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Réessayer") { Task { await model.discover() } }
                .glassButtonStyle()
        } else if suggestions.isEmpty {
            if model.busy {
                ProgressView("Recherche de titres…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ContentUnavailableView("Aucun titre à proposer", systemImage: "film",
                                       description: Text("Essaie d’autres filtres ou affiche plus de titres."))
            }
        }
    }

    private func featuredCard(_ item: TMItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                Poster(path: item.backdrop_path ?? item.poster_path, landscape: true, cornerRadius: 0)
                    .overlay {
                        LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                GlassControlGroup {
                    HStack(spacing: 10) {
                        NavigationLink { DetailView(item: item) } label: {
                            Label("Voir la fiche", systemImage: "arrow.right").font(.subheadline.weight(.semibold))
                        }
                        .controlSize(.large)
                        .tint(.white)
                        .glassButtonStyle()
                        Spacer(minLength: 4)
                        bookmark(for: item)
                    }
                    .padding(14)
                }
                .environment(\.colorScheme, .dark)
            }

            VStack(alignment: .leading, spacing: 8) {
                NavigationLink { DetailView(item: item) } label: {
                    Text(item.display).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                .buttonStyle(.plain)

                metadata(item)
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 28))
    }

    private func movieCard(_ item: TMItem) -> some View {
        NavigationLink { DetailView(item: item) } label: {
            VStack(alignment: .leading, spacing: 7) {
                Poster(path: item.poster_path, cornerRadius: 18)
                Text(item.display).font(.headline).lineLimit(2)
                metadata(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            bookmark(for: item).padding(7)
        }
    }

    private func bookmark(for item: TMItem) -> some View {
        ArtworkBookmarkButton(title: item.display, saved: model.isWishlisted(item)) { model.toggle(item) }
    }

    private func metadata(_ item: TMItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let date = item.releaseDateText {
                Text(date).foregroundStyle(.secondary)
            }
            if model.owns(item) {
                Label("Sur Jellyfin", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            TorrentIndicator(item: item)
        }
        .font(.caption)
    }
}

struct DiscoveryFilters: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryModel
    @State private var genre: String
    @State private var minYear: String
    @State private var maxYear: String
    @State private var minRating: Double
    @State private var language: String
    @State private var sort: String
    @State private var personalized: Bool

    init(model: LibraryModel) {
        self.model = model
        _genre = State(initialValue: model.genre)
        _minYear = State(initialValue: model.minYear)
        _maxYear = State(initialValue: model.maxYear)
        _minRating = State(initialValue: model.minRating)
        _language = State(initialValue: model.originalLanguage)
        _sort = State(initialValue: model.sort)
        _personalized = State(initialValue: model.personalized)
    }

    private var genres: [(String, String)] {
        let shared = [("Tous", ""), ("Comédie", "35"), ("Drame", "18"), ("Crime", "80"), ("Animation", "16"), ("Documentaire", "99")]
        return shared + (model.mediaType == "tv"
            ? [("Action et aventure", "10759"), ("Science-fiction et fantasy", "10765"), ("Mystère", "9648")]
            : [("Action", "28"), ("Horreur", "27"), ("Thriller", "53"), ("Science-fiction", "878")])
    }

    private var validYears: Bool {
        let from = minYear.isEmpty ? 1874 : Int(minYear) ?? 0
        let until = maxYear.isEmpty ? 2100 : Int(maxYear) ?? 0
        return (1874...2100).contains(from) && (from...2100).contains(until)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Catalogue") {
                    Picker("Genre", selection: $genre) {
                        ForEach(genres.indices, id: \.self) { index in
                            Text(genres[index].0).tag(genres[index].1)
                        }
                    }
                    Picker("Langue originale", selection: $language) {
                        Text("Toutes").tag("")
                        Text("Français").tag("fr")
                        Text("Anglais").tag("en")
                        Text("Japonais").tag("ja")
                        Text("Coréen").tag("ko")
                        Text("Espagnol").tag("es")
                    }
                    Picker("Trier par", selection: $sort) {
                        Text("Popularité").tag("popularity.desc")
                        Text("Note").tag("vote_average.desc")
                        Text("Nombre de votes").tag("vote_count.desc")
                    }
                }
                Section("Sortie et note") {
                    TextField("Année de début", text: $minYear).keyboardType(.numberPad)
                    TextField("Année de fin", text: $maxYear).keyboardType(.numberPad)
                    LabeledContent("Note minimale", value: minRating == 0 ? "Toutes" : minRating.formatted())
                    Slider(value: $minRating, in: 0...10, step: 0.5)
                        .accessibilityLabel("Note minimale")
                    if !validYears { Text("Entre deux années valides, dans l’ordre.").foregroundStyle(.orange) }
                }
                Section {
                    Toggle("Selon mes goûts", isOn: $personalized).disabled(!genre.isEmpty)
                } footer: {
                    Text("Les films et séries déjà présents sur Jellyfin sont masqués.")
                }
                Button("Réinitialiser les filtres") {
                    genre = ""; minYear = ""; maxYear = ""; minRating = 0
                    language = ""; sort = "popularity.desc"; personalized = true
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer") {
                        model.genre = genre
                        model.minYear = minYear
                        model.maxYear = maxYear
                        model.minRating = minRating
                        model.originalLanguage = language
                        model.sort = sort
                        model.personalized = personalized
                        dismiss()
                        Task { await model.discover() }
                    }.disabled(!validYears || model.busy)
                }
            }
        }
    }
}
