import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var model: LibraryModel
    let openSettings: () -> Void
    @State private var showsFilters = false

    private var suggestions: [TMItem] {
        model.discoveries.filter { $0.kind == model.mediaType && model.canSuggest($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Picker("Catalogue", selection: $model.mediaType) {
                        Text("Films").tag("movie")
                        Text("Séries").tag("tv")
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.busy)
                    .onChange(of: model.mediaType) { _, _ in
                        model.genre = ""
                        Task { await model.discover() }
                    }

                    if let featured = suggestions.first {
                        Text(model.personalized && model.genre.isEmpty && model.hasTasteProfile
                             ? "Pour toi" : "À la une")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        featuredCard(featured)
                    }

                    if model.tmdbKey.isEmpty {
                        ContentUnavailableView {
                            Label("Découvrir des titres", systemImage: "sparkles.tv")
                        } description: {
                            Text("Connecte TMDb pour explorer les films et les séries.")
                        } actions: {
                            Button("Configurer TMDb", action: openSettings).buttonStyle(.borderedProminent)
                        }
                    } else if !model.discoveryMessage.isEmpty {
                        Label(model.discoveryMessage, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Réessayer") { Task { await model.discover() } }
                            .buttonStyle(.bordered)
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

                    if suggestions.count > 1 {
                        Text("À explorer").font(.title2.bold().leading(.tight))
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 16, alignment: .top)], spacing: 22) {
                            ForEach(suggestions.dropFirst(), id: \.key, content: movieCard)
                        }
                    }

                    if model.hasMore && !model.tmdbKey.isEmpty {
                        Button(model.busy ? "Chargement…" : "Afficher plus de titres") {
                            Task { await model.discover(more: true) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Découvrir")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Filtres", systemImage: "slider.horizontal.3") { showsFilters = true }
                        .disabled(model.busy || model.tmdbKey.isEmpty)
                }
            }
            .sheet(isPresented: $showsFilters) { DiscoveryFilters(model: model) }
            .refreshable { await model.discover() }
        }
    }

    private func featuredCard(_ item: TMItem) -> some View {
        NavigationLink { DetailView(item: item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Poster(path: item.backdrop_path ?? item.poster_path, landscape: true, cornerRadius: 0)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.display).font(.title2.bold())
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    metadata(item)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func movieCard(_ item: TMItem) -> some View {
        NavigationLink { DetailView(item: item) } label: {
            VStack(alignment: .leading, spacing: 7) {
                Poster(path: item.poster_path)
                Text(item.display).font(.headline).lineLimit(2)
                metadata(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { model.toggle(item) } label: {
                Image(systemName: model.isWishlisted(item) ? "bookmark.fill" : "bookmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel(model.isWishlisted(item)
                                ? "Retirer \(item.display) de mes envies"
                                : "Ajouter \(item.display) à mes envies")
        }
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
    @State private var hideOwnedSeries: Bool

    init(model: LibraryModel) {
        self.model = model
        _genre = State(initialValue: model.genre)
        _minYear = State(initialValue: model.minYear)
        _maxYear = State(initialValue: model.maxYear)
        _minRating = State(initialValue: model.minRating)
        _language = State(initialValue: model.originalLanguage)
        _sort = State(initialValue: model.sort)
        _personalized = State(initialValue: model.personalized)
        _hideOwnedSeries = State(initialValue: model.hideOwnedSeries)
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
                    if model.mediaType == "tv" {
                        Toggle("Masquer les séries déjà sur Jellyfin", isOn: $hideOwnedSeries)
                    }
                } footer: {
                    Text(model.mediaType == "movie"
                         ? "Les films déjà présents sur Jellyfin sont masqués."
                         : "Les suggestions utilisent tes goûts quand tu laisses le genre sur Tous.")
                }
                Button("Réinitialiser les filtres") {
                    genre = ""; minYear = ""; maxYear = ""; minRating = 0
                    language = ""; sort = "popularity.desc"; personalized = true; hideOwnedSeries = true
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
                        model.hideOwnedSeries = hideOwnedSeries
                        dismiss()
                        Task { await model.discover() }
                    }.disabled(!validYears || model.busy)
                }
            }
        }
    }
}
