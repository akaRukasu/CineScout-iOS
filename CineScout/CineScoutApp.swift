import SwiftUI
import Security

@main
struct CineScoutApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model).preferredColorScheme(.dark) }
    }
}

enum Secrets {
    static func get(_ key: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        let attrs: [String: Any] = query.merging([kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

struct Media: Identifiable, Decodable {
    let Id: String
    let Name: String?
    let mediaType: String?
    enum CodingKeys: String, CodingKey {
        case Id, Name, ProductionYear, Genres, UserData, ProviderIds
        case mediaType = "Type"
    }
    let ProductionYear: Int?
    let Genres: [String]?
    let UserData: Playback?
    struct Playback: Decodable { let Played: Bool?; let IsFavorite: Bool? }
    let ProviderIds: [String: String]?
    var id: String { Id }
    var title: String { Name ?? "Sans titre" }
}
struct JellyfinItems: Decodable { let Items: [Media]; let TotalRecordCount: Int? }
struct AuthResponse: Decodable {
    let AccessToken: String
    let User: Account
    struct Account: Decodable { let Id: String }
}

struct TMPage: Decodable { let results: [TMItem]; let total_pages: Int }
struct TMItem: Identifiable, Codable {
    let id: Int
    let genre_ids: [Int]?
    let backdrop_path: String?
    var kind: String { title == nil ? "tv" : "movie" }
    var key: String { "\(kind):\(id)" }
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let vote_average: Double?
    let release_date: String?
    let first_air_date: String?
    var display: String { title ?? name ?? "Sans titre" }
    var year: String { String((release_date ?? first_air_date ?? "").prefix(4)) }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? "https://akarukasu.astra.usbx.me/jellyfin"
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var connected = false
    @Published var library: [Media] = []
    @Published var discoveries: [TMItem] = []
    @Published var message = ""
    @Published private(set) var discoveryMessage = ""
    @Published var busy = false
    @Published var mediaType = "movie"
    @Published var genre = ""
    @Published var minYear = ""
    @Published var minRating = 0.0
    @Published var hideOwned = true
    @Published var maxYear = ""
    @Published var originalLanguage = ""
    @Published var sort = "popularity.desc"
    @Published var personalized = true
    @Published private(set) var wishlist = (try? JSONDecoder().decode([TMItem].self, from: UserDefaults.standard.data(forKey: "wishlist") ?? Data())) ?? []
    @Published private(set) var hasMore = false
    private var nextDiscovery: URLComponents?
    private var discoveryToken = ""
    @Published private(set) var syncing = false
    private let deviceID: String = {
        if let existing = UserDefaults.standard.string(forKey: "deviceID") { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()
    @Published var tmdbKey = Secrets.get("tmdb")
    private var token = Secrets.get("jellyfin")
    private var userId = UserDefaults.standard.string(forKey: "userId") ?? ""
    @Published private(set) var owned = Set<String>()
    private var sessionServer = UserDefaults.standard.string(forKey: "sessionServer") ?? UserDefaults.standard.string(forKey: "server") ?? "https://akarukasu.astra.usbx.me/jellyfin"
    private var jellyfinAuthorization: String {
        "MediaBrowser Client=\"CineScout\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
    }
    private func preferredGenres(for kind: String) -> [Int] {
        let aliases: [String: Int] = [
            "action": kind == "tv" ? 10759 : 28, "adventure": kind == "tv" ? 10759 : 12,
            "aventure": kind == "tv" ? 10759 : 12, "animation": 16, "comedy": 35, "comedie": 35,
            "drama": 18, "drame": 18, "crime": 80, "documentary": 99, "documentaire": 99,
            "mystery": 9648, "mystere": 9648, "western": 37,
            "science fiction": kind == "tv" ? 10765 : 878, "fantasy": kind == "tv" ? 10765 : 14,
            "horreur": 27, "horror": 27, "thriller": 53, "romance": 10749
        ]
        var counts: [Int: Int] = [:]
        for item in library where item.mediaType == (kind == "tv" ? "Series" : "Movie") {
            let weight = item.UserData?.IsFavorite == true ? 3 : item.UserData?.Played == true ? 2 : 1
            let ids = Set((item.Genres ?? []).compactMap {
                aliases[$0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .replacingOccurrences(of: "-", with: " ")]
            })
            for id in ids { counts[id, default: 0] += weight }
        }
        for item in wishlist where item.kind == kind {
            for id in item.genre_ids ?? [] { counts[id, default: 0] += 4 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3).map(\.key)
    }
    func saveSettings() {
        server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(server, forKey: "server")
        tmdbKey = tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Secrets.set(tmdbKey, for: "tmdb")
    }
    func login(password: String) async {
        guard !busy, !syncing else { return }
        busy = true; defer { busy = false }
        saveSettings()
        message = ""
        if let web = server.range(of: "/web/", options: .caseInsensitive) {
            server = String(server[..<web.lowerBound])
            saveSettings()
        } else if server.lowercased().hasSuffix("/web") {
            server = String(server.dropLast(4))
            saveSettings()
        }
        guard let base = URLComponents(string: server), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let url = base.url?.appendingPathComponent("Users").appendingPathComponent("AuthenticateByName") else {
            message = "Saisis une URL HTTPS Jellyfin valide."
            return
        }
        let loginServer = server
        let loginUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(jellyfinAuthorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": loginUser, "Pw": password])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: break
            case 401: message = "Jellyfin a refusé la connexion (401). Vérifie le nom d’utilisateur et le mot de passe."
            case 403: message = "Jellyfin refuse l’accès (403). Vérifie les droits de ton compte."
            case 404: message = "Jellyfin est introuvable à cette adresse (404). Vérifie le chemin du serveur."
            default: message = "Connexion Jellyfin indisponible (HTTP \(status))."
            }
            guard status == 200 else { return }
            let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
            guard !auth.User.Id.isEmpty, !auth.AccessToken.isEmpty else { message = "Session Jellyfin invalide."; return }
            library = []
            owned = []
            userId = auth.User.Id
            sessionServer = loginServer
            UserDefaults.standard.set(loginServer, forKey: "sessionServer")
            token = auth.AccessToken
            Secrets.set(token, for: "jellyfin")
            UserDefaults.standard.set(userId, forKey: "userId")
            UserDefaults.standard.set(loginUser, forKey: "username")
            connected = true; message = ""
            await refresh()
        } catch { message = "Erreur de connexion : \(error.localizedDescription)" }
    }
    func refresh() async {
        guard !syncing, !token.isEmpty, !userId.isEmpty else { return }
        let sessionToken = token
        guard var parts = URLComponents(string: sessionServer + "/Items") else { return }
        syncing = true
        defer { syncing = false }
        var items: [Media] = []
        do {
            while true {
                parts.queryItems = [
                    .init(name: "UserId", value: userId),
                    .init(name: "Recursive", value: "true"),
                    .init(name: "IncludeItemTypes", value: "Movie,Series"),
                    .init(name: "Fields", value: "ProviderIds,Genres"),
                    .init(name: "EnableUserData", value: "true"),
                    .init(name: "SortBy", value: "SortName"),
                    .init(name: "StartIndex", value: String(items.count)),
                    .init(name: "Limit", value: "500")
                ]
                guard let url = parts.url else { return }
                var request = URLRequest(url: url)
                request.setValue("\(jellyfinAuthorization), Token=\"\(sessionToken)\"", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard token == sessionToken else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    logout()
                    message = "Session Jellyfin expirée. Reconnecte-toi."
                    return
                }
                guard status == 200 else { message = "Synchronisation Jellyfin indisponible (HTTP \(status))."; return }
                let page = try JSONDecoder().decode(JellyfinItems.self, from: data)
                items.append(contentsOf: page.Items)
                if page.Items.isEmpty || items.count >= (page.TotalRecordCount ?? Int.max) ||
                    (page.TotalRecordCount == nil && page.Items.count < 500) { break }
            }
            library = items
            owned = Set(items.compactMap { item in
                guard let id = item.ProviderIds?.first(where: { $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame })?.value else { return nil }
                let kind = item.mediaType == "Series" ? "tv" : "movie"
                return "\(kind):\(id)"
            })
            connected = true
            message = ""
        } catch {
            if token == sessionToken { message = "Bibliothèque : \(error.localizedDescription)" }
        }
    }

    func discover(more: Bool = false) async {
        guard !busy else { return }
        let key = more ? discoveryToken : tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { discoveryMessage = "Ajoute ton jeton TMDb dans Réglages."; return }
        discoveryMessage = ""
        var parts: URLComponents
        if more {
            guard let nextDiscovery else { return }
            parts = nextDiscovery
        } else {
            guard let endpoint = URLComponents(string: "https://api.themoviedb.org/3/discover/\(mediaType)") else { return }
            parts = endpoint
            let from = Int(minYear)
            let until = Int(maxYear)
            if (!minYear.isEmpty && !(from.map { (1874...2100).contains($0) } ?? false)) ||
                (!maxYear.isEmpty && !(until.map { (1874...2100).contains($0) } ?? false)) ||
                (from ?? 1874) > (until ?? 2100) {
                discoveryMessage = "Vérifie les années de début et de fin."
                return
            }
            let date = mediaType == "movie" ? "primary_release_date" : "first_air_date"
            let selection = genre.isEmpty && personalized ? preferredGenres(for: mediaType).map(String.init).joined(separator: "|") : genre
            var query: [URLQueryItem] = [
                .init(name: "language", value: "fr-FR"),
                .init(name: "sort_by", value: sort),
                .init(name: "vote_average.gte", value: String(minRating)),
                .init(name: "vote_count.gte", value: minRating > 0 ? "20" : "0"),
                .init(name: "include_adult", value: "false")
            ]
            if let from { query.append(.init(name: "\(date).gte", value: "\(from)-01-01")) }
            if let until { query.append(.init(name: "\(date).lte", value: "\(until)-12-31")) }
            if !selection.isEmpty { query.append(.init(name: "with_genres", value: selection)) }
            if !originalLanguage.isEmpty { query.append(.init(name: "with_original_language", value: originalLanguage)) }
            parts.queryItems = query + [.init(name: "page", value: "1")]
        }
        guard let url = parts.url else { return }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: url)
        if key.count == 32 && key.allSatisfy(\.isHexDigit) {
            parts.queryItems = (parts.queryItems ?? []) + [.init(name: "api_key", value: key)]
            guard let apiURL = parts.url else { return }
            request.url = apiURL
            parts.queryItems?.removeAll { $0.name == "api_key" }
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                discoveryMessage = [401, 403].contains(status) ? "TMDb a refusé le jeton ou la clé API." : "TMDb indisponible (HTTP \(status))."
                return
            }
            let page = try JSONDecoder().decode(TMPage.self, from: data)
            if !more { discoveries = [] }
            var seen = Set(discoveries.map(\.key))
            discoveries.append(contentsOf: page.results.filter { seen.insert($0.key).inserted })
            let number = Int(parts.queryItems?.first(where: { $0.name == "page" })?.value ?? "") ?? 1
            hasMore = number < min(page.total_pages, 500)
            parts.queryItems?.removeAll { $0.name == "page" }
            parts.queryItems?.append(.init(name: "page", value: String(number + 1)))
            nextDiscovery = hasMore ? parts : nil
            discoveryToken = key
            discoveryMessage = ""
        } catch { discoveryMessage = "TMDb : \(error.localizedDescription)" }
    }

    func isWishlisted(_ item: TMItem) -> Bool { wishlist.contains { $0.key == item.key } }

    func toggle(_ item: TMItem) {
        if isWishlisted(item) {
            wishlist.removeAll { $0.key == item.key }
        } else {
            wishlist.insert(item, at: 0)
        }
        if let data = try? JSONEncoder().encode(wishlist) { UserDefaults.standard.set(data, forKey: "wishlist") }
    }

    func logout() {
        token = ""
        Secrets.set("", for: "jellyfin")
        connected = false
        library = []
        owned = []
    }
}

struct RootView: View {
    enum Tab: Hashable { case discover, library, wishlist, settings }
    @EnvironmentObject var model: LibraryModel
    @State private var tab = Tab.discover

    var body: some View {
        TabView(selection: $tab) {
            DiscoverView { tab = .settings }
                .tabItem { Label("Découvrir", systemImage: "sparkles") }.tag(Tab.discover)
            LibraryView { tab = .settings }
                .tabItem { Label("Jellyfin", systemImage: "play.rectangle.stack") }.tag(Tab.library)
            WishlistView { tab = .discover }
                .tabItem { Label("Envies", systemImage: "bookmark") }.tag(Tab.wishlist)
            SettingsView { tab = .discover }
                .tabItem { Label("Réglages", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .tint(Color(red: 0.73, green: 0.59, blue: 1))
        .task {
            await model.refresh()
            if !model.tmdbKey.isEmpty && model.discoveries.isEmpty { await model.discover() }
        }
    }
}
struct Poster: View {
    let path: String?
    var landscape = false
    var body: some View {
        Rectangle().fill(.white.opacity(0.08))
            .aspectRatio(landscape ? 16.0/9 : 2.0/3, contentMode: .fit)
            .overlay {
                AsyncImage(url: path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(landscape ? "w780" : "w500")" + $0) }) { phase in
                    if let image = phase.image {
                        GeometryReader { size in
                            image.resizable().scaledToFill()
                                .frame(width: size.size.width, height: size.size.height)
                        }
                    } else {
                        Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}
struct DiscoverView: View {
    @EnvironmentObject var model: LibraryModel
    let openSettings: () -> Void
    @State private var showsFilters = false

    private var visible: [TMItem] {
        model.discoveries.filter {
            $0.kind == model.mediaType && (!model.hideOwned || !model.owned.contains($0.key))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    if let featured = visible.first {
                        NavigationLink { DetailView(item: featured) } label: {
                            Poster(path: featured.backdrop_path ?? featured.poster_path, landscape: true)
                                .overlay(alignment: .bottomLeading) {
                                    ZStack(alignment: .bottomLeading) {
                                        LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .center, endPoint: .bottom)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("À LA UNE").font(.caption2.bold()).tracking(2)
                                            Text(featured.display).font(.title2.bold()).lineLimit(2)
                                            if !featured.year.isEmpty { Text(featured.year).font(.caption) }
                                        }
                                        .padding(16)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }

                    if model.tmdbKey.isEmpty {
                        ContentUnavailableView {
                            Label("Active la découverte", systemImage: "sparkles.tv")
                        } description: {
                            Text("Ajoute ta clé TMDb pour afficher les films et séries.")
                        } actions: {
                            Button("Configurer TMDb", action: openSettings).buttonStyle(.borderedProminent)
                        }
                    } else if visible.isEmpty {
                        if model.busy {
                            ProgressView("Recherche de titres…").frame(maxWidth: .infinity).padding(40)
                        } else if model.discoveryMessage.isEmpty {
                            ContentUnavailableView("Aucun titre à afficher", systemImage: "film",
                                                   description: Text("Ajuste les filtres ou charge la suite du catalogue."))
                        }
                    }

                    if !model.discoveryMessage.isEmpty && !model.tmdbKey.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.discoveryMessage, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.orange)
                            HStack {
                                Button("Réessayer") { Task { await model.discover() } }
                                Button("Réglages TMDb", action: openSettings)
                            }.buttonStyle(.bordered)
                        }
                    }

                    if visible.count > 1 {
                        Text("À explorer").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 14, alignment: .top)], spacing: 18) {
                            ForEach(visible.dropFirst(), id: \.key) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    NavigationLink { DetailView(item: item) } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Poster(path: item.poster_path)
                                            Text(item.display).font(.subheadline.weight(.semibold)).lineLimit(2)
                                            HStack {
                                                if !item.year.isEmpty { Text(item.year) }
                                                if let score = item.vote_average, score > 0 {
                                                    Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                                }
                                            }.font(.caption).foregroundStyle(.secondary)
                                            if model.owned.contains(item.key) {
                                                Label("Sur Jellyfin", systemImage: "checkmark.circle")
                                                    .font(.caption2).foregroundStyle(.green)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                                .overlay(alignment: .topTrailing) {
                                    Button { model.toggle(item) } label: {
                                        Image(systemName: model.isWishlisted(item) ? "bookmark.fill" : "bookmark")
                                            .frame(width: 44, height: 44)
                                            .background(.black.opacity(0.72), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(5)
                                    .accessibilityLabel(model.isWishlisted(item) ? "Retirer de mes envies" : "Ajouter à mes envies")
                                }
                            }
                        }
                    }

                    if model.hasMore && !model.tmdbKey.isEmpty {
                        Button(model.busy ? "Chargement…" : "Voir plus de titres") {
                            Task { await model.discover(more: true) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color(red: 0.055, green: 0.065, blue: 0.10))
            .navigationTitle("Découvrir")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsFilters = true } label: {
                        Label("Filtres", systemImage: "slider.horizontal.3")
                    }
                    .disabled(model.busy || model.tmdbKey.isEmpty)
                }
            }
            .sheet(isPresented: $showsFilters) {
                DiscoveryFilters(model: model)
            }
            .refreshable { await model.discover() }
        }
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
    @State private var hideOwned: Bool

    init(model: LibraryModel) {
        self.model = model
        _genre = State(initialValue: model.genre)
        _minYear = State(initialValue: model.minYear)
        _maxYear = State(initialValue: model.maxYear)
        _minRating = State(initialValue: model.minRating)
        _language = State(initialValue: model.originalLanguage)
        _sort = State(initialValue: model.sort)
        _personalized = State(initialValue: model.personalized)
        _hideOwned = State(initialValue: model.hideOwned)
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
                    Toggle("Masquer les titres sur Jellyfin", isOn: $hideOwned)
                } footer: {
                    Text("Les suggestions utilisent tes goûts quand tu laisses le genre sur Tous.")
                }
                Button("Réinitialiser les filtres") {
                    genre = ""; minYear = ""; maxYear = ""; minRating = 0
                    language = ""; sort = "popularity.desc"; personalized = true; hideOwned = true
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
                        model.hideOwned = hideOwned
                        dismiss()
                        Task { await model.discover() }
                    }.disabled(!validYears || model.busy)
                }
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: LibraryModel
    let item: TMItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let backdrop = item.backdrop_path {
                    Poster(path: backdrop, landscape: true)
                } else {
                    Poster(path: item.poster_path).frame(maxWidth: 180).frame(maxWidth: .infinity)
                }
                Text(item.display).font(.largeTitle.bold())
                Text("\(item.year) · \(item.vote_average ?? 0, specifier: "%.1f")/10").foregroundStyle(.secondary)
                if model.owned.contains(item.key) { Label("Déjà sur Jellyfin", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button {
                    model.toggle(item)
                } label: {
                    Label(model.isWishlisted(item) ? "Retirer de ma liste" : "Ajouter à ma liste", systemImage: model.isWishlisted(item) ? "bookmark.fill" : "bookmark")
                }.buttonStyle(.borderedProminent)
                Text("Synopsis").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text(item.overview.flatMap { $0.isEmpty ? nil : $0 } ?? "Aucun synopsis disponible.").foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle(item.display).navigationBarTitleDisplayMode(.inline)
    }
}
struct LibraryView: View {
    @EnvironmentObject var model: LibraryModel
    let openSettings: () -> Void
    @State private var search = ""
    var filtered: [Media] { model.library.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            List {
                if model.syncing {
                    ProgressView("Synchronisation de la bibliothèque…")
                } else if !model.connected {
                    ContentUnavailableView {
                        Label("Connecte Jellyfin", systemImage: "play.rectangle.stack")
                    } description: {
                        Text("Retrouve ta bibliothèque et repère les titres déjà présents.")
                    } actions: {
                        Button("Configurer Jellyfin", action: openSettings).buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Bibliothèque vide" : "Aucun résultat", systemImage: "film")
                        .listRowBackground(Color.clear)
                }
                if !model.message.isEmpty { Label(model.message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange) }
                ForEach(filtered) { item in
                    HStack {
                        Image(systemName: item.mediaType == "Series" ? "tv" : "film").foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text("\(item.ProductionYear.map(String.init) ?? "—") · \(item.mediaType ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.searchable(text: $search).navigationTitle("Ma bibliothèque")
                .refreshable { await model.refresh() }
                .toolbar {
                    if model.connected {
                        Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                            .disabled(model.syncing)
                    }
                }
        }
    }
}
struct WishlistView: View {
    @EnvironmentObject var model: LibraryModel
    let openDiscover: () -> Void
    var body: some View {
        NavigationStack {
            List {
                if model.wishlist.isEmpty {
                    ContentUnavailableView {
                        Label("Ta liste est vide", systemImage: "bookmark")
                    } description: {
                        Text("Touche le marque-page d’un film ou d’une série pour le retrouver ici.")
                    } actions: {
                        Button("Parcourir les titres", action: openDiscover).buttonStyle(.borderedProminent)
                    }.listRowBackground(Color.clear)
                }
                ForEach(model.wishlist, id: \.key) { item in
                    NavigationLink {
                        DetailView(item: item)
                    } label: {
                        HStack(spacing: 14) {
                            Poster(path: item.poster_path).frame(width: 44)
                            VStack(alignment: .leading) {
                                Text(item.display).font(.headline)
                                Text(item.kind == "tv" ? "Série · \(item.year)" : "Film · \(item.year)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let removed = offsets.map { model.wishlist[$0] }
                    for item in removed { model.toggle(item) }
                }
            }.navigationTitle("Ma liste")
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: LibraryModel
    let openDiscover: () -> Void
    @State private var password = ""
    @State private var tmdbDraft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.connected {
                        Label("Jellyfin connecté", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        LabeledContent("Compte", value: model.username)
                        LabeledContent("Titres synchronisés", value: model.library.count.formatted())
                        Button("Se déconnecter", role: .destructive) { model.logout() }
                            .disabled(model.busy)
                    } else {
                        TextField("Adresse du serveur", text: $model.server)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("Nom d’utilisateur", text: $model.username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Mot de passe", text: $password).textContentType(.password)
                        Button {
                            Task {
                                await model.login(password: password)
                                if model.connected { password = "" }
                            }
                        } label: {
                            if model.busy || model.syncing {
                                ProgressView("Connexion à Jellyfin…")
                            } else {
                                Label("Se connecter à Jellyfin", systemImage: "arrow.right.circle")
                            }
                        }
                        .disabled(model.busy || model.syncing || model.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !model.message.isEmpty {
                        Label(model.message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Bibliothèque Jellyfin")
                } footer: {
                    Text("Utilise le compte avec lequel tu te connectes à Jellyfin.")
                }

                Section {
                    SecureField("Clé API ou jeton de lecture", text: $tmdbDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                    Link("Obtenir une clé TMDb", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    Button {
                        focused = false
                        model.tmdbKey = tmdbDraft
                        model.saveSettings()
                        openDiscover()
                        Task { await model.discover() }
                    } label: {
                        Label("Enregistrer et découvrir", systemImage: "sparkles")
                    }
                    .disabled(model.busy || tmdbDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Catalogue TMDb")
                } footer: {
                    Text("La clé permet d’explorer des films et séries en dehors de ta bibliothèque.")
                }
                Section { Text("Données TMDb · Application indépendante, non approuvée par TMDb.").font(.caption) }
            }
            .navigationTitle("Réglages")
            .onAppear { tmdbDraft = model.tmdbKey }
        }
    }
}
