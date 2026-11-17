import SwiftUI

struct RouletteView: View {
    @EnvironmentObject private var model: LibraryModel
    let openSettings: () -> Void
    @AppStorage("rouletteHistory") private var historyData = Data()
    @State private var formats = Set(RouletteFormat.allCases)
    @State private var genres = Set<RouletteGenre>()
    @State private var count = 3
    @State private var results: [TMItem] = []
    @State private var note: String?
    @State private var showsReset = false
    @State private var drawID: UUID?
    @State private var isCheckingLibrary = false

    private var history: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: historyData)) ?? []
    }

    private var canDraw: Bool { Roulette.canDraw(formats: formats, genres: genres) }

    var body: some View {
        List {
            Section {
                Text("Tire des titres bien notés, à découvrir dans plusieurs époques.")
                    .foregroundStyle(.secondary)
                Picker("Nombre de choix", selection: $count) {
                    ForEach([1, 3, 5, 10], id: \.self) { count in Text("\(count)").tag(count) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Nombre de suggestions")
            }
            .disabled(drawID != nil)

            Section {
                DisclosureGroup {
                    ForEach(RouletteFormat.allCases) { format in
                        Toggle(format.label, isOn: Binding(
                            get: { formats.contains(format) },
                            set: { enabled in
                                if enabled { formats.insert(format) }
                                else { formats.remove(format) }
                            }
                        ))
                    }
                } label: {
                    LabeledContent("Formats", value: formats.count == RouletteFormat.allCases.count
                                   ? "Tous" : "\(formats.count) sélectionnés")
                }

                DisclosureGroup {
                    if !genres.isEmpty { Button("Tous les genres") { genres.removeAll() } }
                    ForEach(RouletteGenre.allCases) { genre in
                        Toggle(genre.label, isOn: Binding(
                            get: { genres.contains(genre) },
                            set: { enabled in
                                if enabled { genres.insert(genre) }
                                else { genres.remove(genre) }
                            }
                        ))
                    }
                } label: {
                    LabeledContent("Genres", value: genres.isEmpty ? "Tous" : "\(genres.count) sélectionnés")
                }
            } footer: {
                Text("Tu peux choisir plusieurs formats et genres. Un titre doit correspondre à au moins un des genres choisis.")
            }
            .disabled(drawID != nil)

            Section {
                if !model.hasJellyfinSession || model.tmdbKey.isEmpty {
                    Label(model.hasJellyfinSession ? "Configure TMDb pour lancer la roulette." :
                          "Connecte Jellyfin pour exclure les contenus déjà présents.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Button("Ouvrir les réglages", action: openSettings)
                } else {
                    Button {
                        drawID = UUID()
                    } label: {
                        Label(results.isEmpty ? "Lancer la roulette" : "Relancer la roulette", systemImage: "die.face.5")
                    }
                    .controlSize(.large)
                    .glassButtonStyle(prominent: true)
                    .disabled(drawID != nil || !canDraw)
                    if drawID != nil {
                        ProgressView(isCheckingLibrary ? "Inventaire Jellyfin…" : "Tirage en cours…")
                    } else if !canDraw {
                        Text(formats.isEmpty ? "Choisis au moins un format." :
                             "TMDb ne propose pas ces genres pour les formats choisis.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let note { Text(note).foregroundStyle(.secondary) }
            } footer: {
                Text("Les notes et le nombre de votes viennent de TMDb. La bibliothèque sert à éliminer les doublons.")
            }

            if !results.isEmpty {
                Section("Suggestions") {
                    ForEach(results.filter { !model.owns($0) }, id: \.key) { item in
                        NavigationLink { DetailView(item: item) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                CatalogTitleRow(item: item)
                                if let rating = item.vote_average, let votes = item.vote_count {
                                    Label("\(rating.formatted(.number.precision(.fractionLength(1))))/10 · \(votes.formatted()) votes TMDb",
                                          systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                                }
                                TorrentIndicator(item: item).font(.caption)
                            }
                        }
                    }
                }
            }

            if !history.isEmpty {
                Button("Réinitialiser l’historique des tirages", role: .destructive) { showsReset = true }
                    .disabled(drawID != nil)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Roulette")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: drawID) {
            if let drawID { await draw(drawID) }
        }
        .confirmationDialog("Réinitialiser l’historique ?", isPresented: $showsReset, titleVisibility: .visible) {
            Button("Réinitialiser", role: .destructive) {
                historyData = Data()
                note = nil
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les titres déjà tirés pourront réapparaître, à l’exception de ceux présents dans Jellyfin.")
        }
    }

    private func draw(_ id: UUID) async {
        let quantity = count
        let wantedFormats = formats
        let wantedGenres = genres
        isCheckingLibrary = true
        note = nil
        defer {
            if drawID == id {
                drawID = nil
                isCheckingLibrary = false
            }
        }
        do {
            await model.refresh()
            try Task.checkCancellation()
            guard model.lastVerifiedSync != nil, model.hasJellyfinSession else {
                note = model.message.isEmpty ? "Synchronise Jellyfin avant de lancer le tirage." : model.message
                return
            }
            let revision = model.inventoryRevision
            isCheckingLibrary = false
            let excluded = history.union(results.map(\.key))
            let drawn = try await model.drawCandidates(formats: wantedFormats, genres: wantedGenres,
                                                       excluding: excluded, count: quantity)
            try Task.checkCancellation()
            guard model.inventoryRevision == revision, model.lastVerifiedSync != nil else {
                note = "La bibliothèque a changé pendant le tirage. Relance la roulette."
                return
            }
            results = drawn
            if !drawn.isEmpty {
                historyData = (try? JSONEncoder().encode(history.union(drawn.map(\.key)))) ?? historyData
            }
            if drawn.count < quantity {
                note = drawn.isEmpty ? "Aucun nouveau titre trouvé pour ces filtres. Essaie d’autres genres ou formats."
                    : "Seulement \(drawn.count) suggestion(s) trouvée(s) avec ces filtres."
            }
        } catch {
            if !Task.isCancelled { note = error.localizedDescription }
        }
    }
}

extension LibraryModel {
    func drawCandidates(formats: Set<RouletteFormat>, genres: Set<RouletteGenre>,
                        excluding history: Set<String>, count: Int) async throws -> [TMItem] {
        var results: [TMItem] = []
        var considered = history
        for spread in [4, 16] {
            let queries = Roulette.queries(formats: formats, genres: genres)
            let allCandidates = try await withThrowingTaskGroup(of: [TMItem].self) { group in
                // Limit concurrent catalog requests to four.
                for index in 0..<min(queries.count, 4) {
                    let lane = stride(from: index, to: queries.count, by: 4).map { queries[$0] }
                    group.addTask {
                        var candidates: [TMItem] = []
                        for query in lane { candidates += try await self.drawPage(query, spread: spread) }
                        return candidates
                    }
                }
                var candidates: [TMItem] = []
                for try await page in group { candidates += page }
                return candidates
            }
            var ranked = Roulette.rank(allCandidates.filter { !owns($0) }, excluding: considered)
            while results.count < count, let candidate = Roulette.next(from: ranked, after: results, formats: formats) {
                try Task.checkCancellation()
                ranked.removeAll { $0.key == candidate.key }
                considered.insert(candidate.key)
                if requiresExternalIDCheck(candidate) {
                    let endpoint = TMDbCatalog.endpoint("\(candidate.kind)/\(candidate.id)/external_ids")
                    let external: TMDbExternalIDs = try await catalog(endpoint)
                    if owns(candidate, externalIDs: external) { continue }
                }
                results.append(candidate)
            }
            if results.count >= count { break }
        }
        return results
    }

    private func drawPage(_ query: Roulette.Query, spread: Int) async throws -> [TMItem] {
        let page = Int.random(in: 1...spread)
        let response: TMPage = try await catalog(query.endpoint(page: page))
        if response.results.isEmpty && page > 1 {
            let fallbackPage = Int.random(in: 1...max(1, min(spread, response.total_pages)))
            let fallback: TMPage = try await catalog(query.endpoint(page: fallbackPage))
            return fallback.results.filter(query.matches)
        }
        return response.results.filter(query.matches)
    }
}
