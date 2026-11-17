import SwiftUI

struct RouletteView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openSettings: () -> Void
    @AppStorage("rouletteHistory") private var historyData = Data()
    @State private var formats = Set(RouletteFormat.allCases)
    @State private var genres = Set<RouletteGenre>()
    @State private var count = 3
    @State private var results: [TMItem] = []
    @State private var reelCandidates: [TMItem] = []
    @State private var winner: TMItem?
    @State private var phase = RoulettePhase.idle
    @State private var note: String?
    @State private var showsReset = false
    @State private var drawID: UUID?
    @State private var isCheckingLibrary = false

    private var history: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: historyData)) ?? []
    }

    private var canDraw: Bool { Roulette.canDraw(formats: formats, genres: genres) }
    private var recentYear: Int { Calendar.current.component(.year, from: .now) - 4 }

    private var status: String {
        if isCheckingLibrary { return "Vérification de tes médiathèques" }
        switch phase {
        case .spinning: return "Les affiches défilent…"
        case .settling: return "Le tirage ralentit…"
        case .revealed: return results.count == 1 ? "Ta découverte" : "Tes découvertes"
        case .idle: return "À toi de lancer le tirage"
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            rouletteScroll
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    drawControl {
                        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo("reel", anchor: .top) }
                        winner = nil
                        reelCandidates = []
                        phase = .spinning(.now)
                        drawID = UUID()
                    }
                }
        }
        .background { CinemaBackground() }
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

    private var rouletteScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                RouletteStage(candidates: reelCandidates, winner: winner, phase: phase, status: status)
                    .id("reel")

                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                }

                if !results.isEmpty && drawID == nil {
                    Text(results.count == 1 ? "Ta prochaine découverte" : "Tes prochaines découvertes")
                        .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    ForEach(results.filter { !model.owns($0) }, id: \.key) { item in
                        NavigationLink { DetailView(item: item) } label: {
                            RouletteResultCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Combien de découvertes ?").font(.headline)
                    Picker("Nombre de choix", selection: $count) {
                        ForEach([1, 3, 5, 10], id: \.self) { count in Text("\(count)").tag(count) }
                    }
                    .pickerStyle(.segmented)

                    Divider()
                    Text("Quels formats ?").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(RouletteFormat.allCases) { format in
                            selectionButton(format.label, selected: formats.contains(format)) {
                                if formats.contains(format) { formats.remove(format) }
                                else { formats.insert(format) }
                            }
                        }
                    }

                    Divider()
                    DisclosureGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                            selectionButton("Tous les genres", selected: genres.isEmpty) { genres.removeAll() }
                            ForEach(RouletteGenre.allCases) { genre in
                                selectionButton(genre.label, selected: genres.contains(genre)) {
                                    if genres.contains(genre) { genres.remove(genre) }
                                    else { genres.insert(genre) }
                                }
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Quels genres ?").font(.headline).foregroundStyle(.primary)
                            Text(genres.isEmpty ? "Tous les genres" :
                                    RouletteGenre.allCases.filter { genres.contains($0) }.map(\.label).joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
                .disabled(drawID != nil)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "calendar").foregroundStyle(CinemaPalette.violet)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Un mélange d’époques").font(.subheadline.bold())
                        Text("Surtout 2000–\(recentYear.formatted(.number.grouping(.never))), avec quelques classiques et nouveautés.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Notes TMDb dès 6,8/10, avec un minimum de votes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)

                if !history.isEmpty {
                    Button("Réinitialiser l’historique des tirages", role: .destructive) { showsReset = true }
                        .font(.footnote).disabled(drawID != nil).padding(.horizontal, 5)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func selectionButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? CinemaPalette.violet : Color.secondary)
                Text(label).foregroundStyle(.primary)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? CinemaPalette.violet.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                        in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func drawControl(start: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            if !model.hasJellyfinSession || model.tmdbKey.isEmpty {
                Button("Connecter mes services", systemImage: "link", action: openSettings)
                    .controlSize(.large).glassButtonStyle(prominent: true)
                Text(model.hasJellyfinSession ? "TMDb permet de rechercher les titres." :
                        "Jellyfin permet d’exclure tes contenus déjà présents.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Button(action: start) {
                    Label(drawID == nil ? "Faire tourner la roulette" : "Tirage en cours", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 27)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .glassButtonStyle(prominent: true)
                .disabled(drawID != nil || !canDraw)
                if !canDraw {
                    Text(formats.isEmpty ? "Choisis au moins un format." :
                         "Ces genres ne sont pas disponibles pour les formats choisis.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
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
                if phase != .revealed {
                    phase = .idle
                    winner = nil
                }
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
            let draw = try await model.drawCandidates(formats: wantedFormats, genres: wantedGenres,
                                                      excluding: excluded, count: quantity)
            try Task.checkCancellation()
            guard !draw.titles.isEmpty else {
                note = "Aucun nouveau titre trouvé pour ces filtres. Essaie d’autres genres ou formats."
                return
            }

            reelCandidates = draw.candidates
            winner = draw.titles.first
            phase = .settling(.now)
            try await Task.sleep(for: .seconds(reduceMotion ? 0.25 : 3.3))
            try Task.checkCancellation()
            guard model.inventoryRevision == revision, model.lastVerifiedSync != nil else {
                note = "La bibliothèque a changé pendant le tirage. Relance la roulette."
                return
            }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.45)) {
                results = draw.titles
                phase = .revealed
            }
            historyData = (try? JSONEncoder().encode(history.union(draw.titles.map(\.key)))) ?? historyData
            if draw.titles.count < quantity {
                note = "\(draw.titles.count) suggestion(s) trouvée(s) avec ces filtres et cet équilibre d’époques."
            }
        } catch {
            if !Task.isCancelled { note = error.localizedDescription }
        }
    }
}

struct RouletteResultCard: View {
    let item: TMItem

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Poster(path: item.poster_path, cornerRadius: 14)
                .frame(width: 88)
                .overlay(alignment: .topLeading) {
                    CinemaScore(item: item).padding(5)
                }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.display).font(.headline).foregroundStyle(.primary)
                Text([item.kindLabel, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                TorrentIndicator(item: item).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }
}

struct RouletteDraw {
    let titles: [TMItem]
    let candidates: [TMItem]
}

extension LibraryModel {
    func drawCandidates(formats: Set<RouletteFormat>, genres: Set<RouletteGenre>,
                        excluding history: Set<String>, count: Int) async throws -> RouletteDraw {
        var results: [TMItem] = []
        var considered = history
        var preview: [TMItem] = []
        let now = Date.now
        let schedule = Roulette.eraSchedule(count: count)
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
            preview += ranked.prefix(12)
            while results.count < count, let candidate = Roulette.next(from: ranked, after: results, formats: formats, schedule: schedule, now: now) {
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
        return RouletteDraw(titles: results, candidates: Array(preview.prefix(18)))
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
