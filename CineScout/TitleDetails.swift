import SwiftUI

struct TitleMetadata: Decodable {
    let genres: [Genre]?
    let runtime: Int?
    let number_of_seasons: Int?
    let number_of_episodes: Int?
    let tagline: String?
    let overview: String?
    let backdrop_path: String?
    let poster_path: String?
    let release_date: String?
    let first_air_date: String?
    let vote_average: Double?
    let credits: Credits?
    let recommendations: TMPage?
    let similar: TMPage?
    struct Genre: Decodable, Identifiable { let id: Int; let name: String }
    struct Credits: Decodable { let cast: [Person]?; let crew: [Person]? }
    struct Person: Decodable, Identifiable {
        let id: Int
        let name: String
        let character: String?
        let job: String?
        let profile_path: String?
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: LibraryModel
    let item: TMItem
    @State private var metadata: TitleMetadata?
    @State private var loadingMetadata = false
    @State private var metadataError = false
    @State private var seerrMedia: SeerrClient.Media?
    @State private var checkingSeerr = false
    @State private var sending = false
    @State private var seerrError: String?
    @State private var receipt: SeerrClient.Receipt?
    @State private var refreshingReceipt = false
    @State private var showsSettings = false
    @State private var showsRequest = false
    @State private var selectedSeasons = Set<Int>()

    private var duration: String? {
        if let minutes = metadata?.runtime, minutes > 0 {
            return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        }
        if let seasons = metadata?.number_of_seasons, seasons > 0 {
            return seasons == 1 ? "1 saison" : "\(seasons) saisons"
        }
        return nil
    }

    private var related: [TMItem] {
        var seen: Set<String> = [item.key]
        let candidates = (metadata?.recommendations?.results ?? []) + (metadata?.similar?.results ?? [])
        return Array(candidates.filter { model.canSuggest($0) && seen.insert($0.key).inserted }.prefix(12))
    }

    private var requestStatus: String? {
        if let receipt { return receipt.label }
        if seerrMedia?.mediaInfo?.status == 6 { return "Titre bloqué dans Seerr" }
        if item.kind == "movie" {
            if seerrMedia?.mediaInfo?.status == 5 || model.owns(item) { return "Déjà disponible" }
            if let request = seerrMedia?.mediaInfo?.requests?.first(where: { $0.is4k != true && [1, 2, 4].contains($0.status) }) {
                if let id = request.id { return SeerrClient.Receipt(id: id, status: request.status).label }
                return request.status == 4 ? "Demande en échec côté Seerr" : "Déjà demandé"
            }
            if seerrMedia?.mediaInfo?.status == 2 { return "Demande en attente d’approbation" }
            if seerrMedia?.mediaInfo?.status == 3 { return "Demande en cours" }
        }
        if item.kind == "tv", let seasons = seerrMedia?.seasons, seasons.contains(where: { $0.seasonNumber > 0 }),
           availableSeasons.isEmpty {
            return "Saisons déjà disponibles ou demandées"
        }
        return nil
    }

    private var availableSeasons: [Int] {
        guard let seerrMedia else { return [] }
        let seasons = (seerrMedia.seasons ?? []).filter { $0.episodeCount != 0 }
        return Set(seasons.map(\.seasonNumber))
            .subtracting(seerrMedia.blockedSeasons).filter { $0 > 0 }.sorted()
    }

    private var canRequest: Bool {
        requestStatus == nil && !model.seerrAddress.isEmpty && !checkingSeerr && seerrMedia != nil &&
        (item.kind == "movie" || !availableSeasons.isEmpty)
    }

    var body: some View {
        detailWithControls
            .background { CinemaBackground() }
            .navigationTitle(item.display)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: item.key) { await loadMetadata() }
            .task(id: model.seerrRevision) { await checkSeerr() }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    SeerrSettingsView().toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Fermer") { showsSettings = false } }
                    }
                }
            }
            .sheet(isPresented: $showsRequest) { requestSheet }
    }

    @ViewBuilder private var detailWithControls: some View {
        if #available(iOS 26.0, *) {
            detailScroll.safeAreaBar(edge: .bottom, spacing: 0) {
                if canRequest { requestButton }
            }
        } else {
            detailScroll.safeAreaInset(edge: .bottom, spacing: 0) {
                if canRequest { requestButton.background(.regularMaterial) }
            }
        }
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                artwork
                heading
                availabilityPanel
                TitleWatchOptions(item: item)
                if let pick = EditorialPick.selection.first(where: { $0.id == item.key }) {
                    editorialNote(pick)
                }
                if let overview = [metadata?.overview, item.overview].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                    synopsis(overview)
                }
                if let director = metadata?.credits?.crew?.first(where: { $0.job == "Director" }) {
                    LabeledContent("Réalisation", value: director.name).font(.subheadline)
                }
                if let cast = metadata?.credits?.cast, !cast.isEmpty { castRow(cast) }
                if !related.isEmpty { relatedRow }
                if loadingMetadata {
                    ProgressView("Chargement de la fiche…")
                } else if metadataError {
                    Button("Recharger les détails", systemImage: "arrow.clockwise") {
                        Task { await loadMetadata() }
                    }.glassButtonStyle()
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Poster(path: metadata?.backdrop_path ?? item.backdrop_path ?? metadata?.poster_path ?? item.poster_path,
                   landscape: true, cornerRadius: 0)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.44)], startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            ArtworkBookmarkButton(title: item.display, saved: model.isWishlisted(item)) {
                model.toggle(item)
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 28))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.display).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if let genres = metadata?.genres, !genres.isEmpty {
                Text(genres.map(\.name).joined(separator: " · ")).foregroundStyle(.secondary)
            }
            let attributes = [duration, (metadata?.vote_average ?? item.vote_average).flatMap { score in
                score > 0 ? "\(score.formatted(.number.precision(.fractionLength(1)))) / 10" : nil
            }].compactMap { $0 }
            if !attributes.isEmpty {
                Text(attributes.joined(separator: " · ")).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var availabilityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(item.kind == "tv" ? "Première diffusion" : "Date de sortie",
                           value: ReleaseDate.french(item.kind == "tv" ? metadata?.first_air_date : metadata?.release_date)
                           ?? item.releaseDateText ?? item.editorialYear.map(String.init) ?? "Date non annoncée")
            if model.owns(item) {
                Divider()
                Label("Dans ta bibliothèque Jellyfin", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if item.kind == "movie" {
                Divider()
                TorrentIndicator(item: item, detailed: true)
            }
            requestControl
        }
        .font(.subheadline)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    private func editorialNote(_ pick: EditorialPick) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Le regard de CinéScout").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(pick.note).foregroundStyle(.secondary)
            Link(destination: pick.article) {
                Label("Lire l’analyse · \(pick.critic)", systemImage: "arrow.up.right")
            }
            .glassButtonStyle()
        }
    }

    private func synopsis(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let tagline = metadata?.tagline, !tagline.isEmpty {
                Text(tagline).font(.subheadline.italic()).foregroundStyle(.secondary)
            }
            Text(overview)
                .foregroundStyle(.secondary)
        }
    }

    private var requestButton: some View {
        Button {
            selectedSeasons = Set(availableSeasons)
            showsRequest = true
        } label: {
            Label(item.kind == "tv" ? "Demander des saisons" : "Demander le film", systemImage: "paperplane.fill")
                .frame(maxWidth: 480, minHeight: 28)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .glassButtonStyle(prominent: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var requestControl: some View {
        if let requestStatus {
            Label(requestStatus, systemImage: "paperplane.circle")
                .font(.subheadline.weight(.semibold))
            if let client = try? model.seerrClient(), seerrMedia != nil {
                HStack {
                    Link(destination: client.requestsURL) {
                        Label("Voir dans Seerr", systemImage: "arrow.up.right.square")
                    }
                    if receipt != nil {
                        Button("Actualiser", systemImage: "arrow.clockwise") {
                            Task { await refreshReceipt() }
                        }.disabled(refreshingReceipt)
                    }
                }.buttonStyle(.bordered)
            }
            if let seerrError { Text(seerrError).font(.footnote).foregroundStyle(.orange) }
        } else if model.seerrAddress.isEmpty {
            Button("Configurer Seerr", systemImage: "paperplane") { showsSettings = true }
                .glassButtonStyle()
        } else if checkingSeerr {
            ProgressView("Vérification dans Seerr…")
        } else if let seerrError {
            Text(seerrError).font(.footnote).foregroundStyle(.orange)
            HStack {
                Button("Réessayer") { Task { await checkSeerr() } }
                Button("Réglages Seerr") { showsSettings = true }
            }.glassButtonStyle()
        } else if !canRequest && seerrMedia != nil {
            Text("Seerr ne propose aucune saison à demander.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var requestSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.display).font(.headline)
                    if item.kind == "tv" {
                        ForEach(availableSeasons, id: \.self) { season in
                            Toggle("Saison \(season)", isOn: Binding(
                                get: { selectedSeasons.contains(season) },
                                set: { if $0 { selectedSeasons.insert(season) } else { selectedSeasons.remove(season) } }
                            ))
                        }
                    }
                } footer: {
                    Text("La demande utilisera le profil standard configuré dans Seerr.")
                }
                if let seerrError { Text(seerrError).foregroundStyle(.orange) }
                Button {
                    Task { await sendRequest() }
                } label: {
                    if sending { ProgressView("Envoi…") }
                    else { Label("Confirmer la demande", systemImage: "paperplane.fill") }
                }.disabled(sending || (item.kind == "tv" && selectedSeasons.isEmpty))
            }
            .navigationTitle("Demande Seerr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showsRequest = false }.disabled(sending)
                }
            }
        }.interactiveDismissDisabled(sending)
    }

    private func castRow(_ people: [TitleMetadata.Person]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Distribution").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(people.prefix(10))) { person in
                        VStack(alignment: .leading, spacing: 6) {
                            Poster(path: person.profile_path)
                            Text(person.name).font(.caption.bold()).lineLimit(2)
                            if let character = person.character, !character.isEmpty {
                                Text(character).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
                            }
                        }.frame(width: 94)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private var relatedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dans le même esprit").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(related, id: \.key) { suggestion in
                        NavigationLink { DetailView(item: suggestion) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Poster(path: suggestion.poster_path)
                                Text(suggestion.display).font(.caption.bold()).lineLimit(2)
                                if let release = suggestion.releaseDateText {
                                    Text(release).font(.caption2).foregroundStyle(.secondary)
                                }
                                TorrentIndicator(item: suggestion).font(.caption2)
                                if model.owns(suggestion) {
                                    Label("Sur Jellyfin", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.green)
                                }
                            }.frame(width: 122, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func loadMetadata() async {
        guard !model.tmdbKey.isEmpty, !loadingMetadata else { return }
        loadingMetadata = true
        defer { loadingMetadata = false }
        do { metadata = try await model.metadata(for: item); metadataError = false }
        catch { if !Task.isCancelled { metadataError = true } }
    }

    private func checkSeerr() async {
        seerrMedia = nil
        receipt = nil
        seerrError = nil
        guard !model.seerrAddress.isEmpty else { return }
        checkingSeerr = true
        defer { checkingSeerr = false }
        do {
            let media = try await model.seerrClient().details(kind: item.kind, id: item.id)
            if !Task.isCancelled { seerrMedia = media }
        } catch {
            if !Task.isCancelled { seerrError = error.localizedDescription }
        }
    }

    private func refreshReceipt() async {
        guard let receipt, !refreshingReceipt else { return }
        refreshingReceipt = true
        seerrError = nil
        defer { refreshingReceipt = false }
        do { self.receipt = try await model.seerrClient().receipt(id: receipt.id) }
        catch { seerrError = error.localizedDescription }
    }

    private func sendRequest() async {
        guard !sending else { return }
        sending = true
        seerrError = nil
        defer { sending = false }
        do {
            let client = try model.seerrClient()
            let current = try await client.details(kind: item.kind, id: item.id)
            seerrMedia = current
            let seasons = selectedSeasons.intersection(availableSeasons).sorted()
            if let requestStatus {
                seerrError = requestStatus
                return
            }
            if item.kind == "tv" && Set(seasons) != selectedSeasons {
                selectedSeasons = Set(seasons)
                seerrError = "La disponibilité des saisons a changé. Vérifie la sélection avant de confirmer."
                return
            }
            guard item.kind == "movie" || !seasons.isEmpty else { return }
            receipt = try await client.submit(.init(mediaType: item.kind, mediaId: item.id,
                                                    seasons: item.kind == "tv" ? seasons : nil))
            showsRequest = false
        } catch {
            seerrError = error.localizedDescription
        }
    }
}
