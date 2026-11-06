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
    @Published var busy = false
    @Published var mediaType = "movie"
    @Published var genre = ""
    @Published var minYear = "2015"
    @Published var minRating = 6.5
    @Published var hideOwned = true
    @Published var maxYear = ""
    @Published var originalLanguage = ""
    @Published var sort = "popularity.desc"
    @Published var personalized = true
    @Published private(set) var wishlist = (try? JSONDecoder().decode([TMItem].self, from: UserDefaults.standard.data(forKey: "wishlist") ?? Data())) ?? []
    @Published private(set) var hasMore = false
    private var nextDiscovery: URLComponents?
    private var discoveryToken = ""
    private var syncing = false
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
        guard let base = URLComponents(string: server), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let url = base.url?.appendingPathComponent("Users/AuthenticateByName") else {
            message = "Saisis une URL HTTPS Jellyfin valide."
            return
        }
        let loginServer = server
        let loginUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(jellyfinAuthorization, forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": loginUser, "Pw": password])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { message = "Connexion refusée. Vérifie tes identifiants."; return }
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
                request.setValue(sessionToken, forHTTPHeaderField: "X-Emby-Token")
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
        guard !key.isEmpty else { message = "Ajoute ton jeton TMDb dans Réglages."; return }
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
                message = "Vérifie les années de début et de fin."
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
                message = [401, 403].contains(status) ? "TMDb a refusé le jeton ou la clé API." : "TMDb indisponible (HTTP \(status))."
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
            message = ""
        } catch { message = "TMDb : \(error.localizedDescription)" }
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
    @EnvironmentObject var model: LibraryModel
    var body: some View {
        TabView {
            DiscoverView().tabItem { Label("Découvrir", systemImage: "sparkles") }
            LibraryView().tabItem { Label("Jellyfin", systemImage: "play.rectangle.stack") }
            WishlistView().tabItem { Label("Envies", systemImage: "bookmark") }
            SettingsView().tabItem { Label("Réglages", systemImage: "gearshape") }
        }
        .tint(.purple)
        .task { await model.refresh() }
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
    @State private var showsFilters = false
    private var genres: [(String, String)] {
        let shared = [("Tous", ""), ("Comédie", "35"), ("Drame", "18"), ("Crime", "80"), ("Animation", "16"), ("Documentaire", "99")]
        return shared + (model.mediaType == "tv"
            ? [("Action et aventure", "10759"), ("Science-fiction et fantasy", "10765"), ("Mystère", "9648")]
            : [("Action", "28"), ("Horreur", "27"), ("Thriller", "53"), ("Science-fiction", "878")])
    }
    var visible: [TMItem] { model.discoveries.filter { !model.hideOwned || !model.owned.contains($0.key) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let featured = visible.first {
                        NavigationLink { DetailView(item: featured) } label: {
                            Poster(path: featured.backdrop_path ?? featured.poster_path, landscape: true)
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("À DÉCOUVRIR").font(.caption2.weight(.heavy)).tracking(3)
                                        Text(featured.display).font(.title.bold()).lineLimit(2)
                                    }
                                    .foregroundStyle(.white).padding(20)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(alignment: .bottom) {
                                        LinearGradient(colors: [.clear, .black.opacity(0.94)], startPoint: .top, endPoint: .bottom)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("CINÉSCOUT / DÉCOUVERTE").font(.caption2.bold()).tracking(3)
                                .foregroundStyle(.purple)
                            Text("Trouve ton prochain coup de cœur").font(.largeTitle.bold())
                        }.padding(.vertical, 12)
                    }
                    Picker("Type", selection: $model.mediaType) {
                        Text("Films").tag("movie")
                        Text("Séries").tag("tv")
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.busy)
                    .onChange(of: model.mediaType) { _, _ in
                        model.genre = ""
                        Task { await model.discover() }
                    }
                    DisclosureGroup("Filtres", isExpanded: $showsFilters) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Genre", selection: $model.genre) {
                                ForEach(genres.indices, id: \.self) { index in
                                    Text(genres[index].0).tag(genres[index].1)
                                }
                            }
                            HStack {
                                TextField("Année min.", text: $model.minYear).keyboardType(.numberPad)
                                TextField("Année max.", text: $model.maxYear).keyboardType(.numberPad)
                            }.textFieldStyle(.roundedBorder)
                            HStack {
                                Text("Note ≥ \(model.minRating, specifier: "%.1f")")
                                Slider(value: $model.minRating, in: 0...10, step: 0.5)
                                    .accessibilityLabel("Note minimale")
                            }
                            Picker("Langue originale", selection: $model.originalLanguage) {
                                Text("Toutes").tag("")
                                Text("Français").tag("fr")
                                Text("Anglais").tag("en")
                                Text("Japonais").tag("ja")
                                Text("Coréen").tag("ko")
                                Text("Espagnol").tag("es")
                            }
                            Picker("Tri", selection: $model.sort) {
                                Text("Popularité").tag("popularity.desc")
                                Text("Note").tag("vote_average.desc")
                                Text("Nombre de votes").tag("vote_count.desc")
                            }
                            Toggle("Selon mes goûts", isOn: $model.personalized)
                            Text("Utilise ta bibliothèque et tes envies quand aucun genre n’est sélectionné.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Masquer les titres déjà présents", isOn: $model.hideOwned)
                        }.font(.subheadline).padding(.top, 10)
                    }.padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    Button { Task { await model.discover() } } label: {
                        Label(model.busy ? "Recherche…" : "Explorer le catalogue", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                    if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange).font(.caption) }
                    if visible.isEmpty && !model.discoveries.isEmpty {
                        Text("Aucun titre visible sur cette page. Charge la suite ou ajuste les filtres.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        ForEach(visible) { item in
                            NavigationLink {
                                DetailView(item: item)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Poster(path: item.poster_path)
                                    Text(item.display).font(.subheadline.bold()).lineLimit(2)
                                    Text("\(item.year) · \(item.vote_average ?? 0, specifier: "%.1f")/10").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if model.hasMore {
                        Button("Afficher plus") { Task { await model.discover(more: true) } }
                            .buttonStyle(.bordered).disabled(model.busy)
                    }
                }.padding()
            }.background(Color(red: 0.055, green: 0.065, blue: 0.10))
                .navigationTitle("CinéScout")
                .task {
                    if model.discoveries.isEmpty && !model.tmdbKey.isEmpty { await model.discover() }
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
                Poster(path: item.poster_path).frame(maxWidth: 220).frame(maxWidth: .infinity)
                Text(item.display).font(.largeTitle.bold())
                Text("\(item.year) · \(item.vote_average ?? 0, specifier: "%.1f")/10").foregroundStyle(.secondary)
                Text(item.overview ?? "Aucun synopsis disponible.")
                if model.owned.contains(item.key) { Label("Déjà sur Jellyfin", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button {
                    model.toggle(item)
                } label: {
                    Label(model.isWishlisted(item) ? "Retirer de ma liste" : "Ajouter à ma liste", systemImage: model.isWishlisted(item) ? "bookmark.fill" : "bookmark")
                }.buttonStyle(.borderedProminent)
            }.padding()
        }.navigationTitle(item.display).navigationBarTitleDisplayMode(.inline)
    }
}
struct LibraryView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var search = ""
    var filtered: [Media] { model.library.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            List {
                if !model.connected {
                    Text("Connecte-toi à Jellyfin dans Réglages pour voir ta bibliothèque.")
                }
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.orange) }
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
                .toolbar { Button("Actualiser") { Task { await model.refresh() } } }
        }
    }
}
struct WishlistView: View {
    @EnvironmentObject var model: LibraryModel
    var body: some View {
        NavigationStack {
            List {
                if model.wishlist.isEmpty { Text("Ajoute des films et séries depuis Découvrir.") }
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
    @State private var password = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Serveur Jellyfin") {
                    TextField("URL", text: $model.server).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("Utilisateur", text: $model.username).textInputAutocapitalization(.never)
                    SecureField("Mot de passe", text: $password)
                    Button(model.busy ? "Connexion…" : "Se connecter") {
                        Task { await model.login(password: password); password = "" }
                    }.disabled(model.busy)
                    if model.connected { Label("Connecté", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button("Déconnexion", role: .destructive) { model.logout() }.disabled(model.busy)
                }
                Section("TMDb") {
                    SecureField("Jeton de lecture ou clé API TMDb", text: $model.tmdbKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Enregistrer les réglages") { model.saveSettings() }
                    Text("Le jeton TMDb est nécessaire pour découvrir des titres absents de Jellyfin.").font(.caption)
                }
                if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange) }
                Section { Text("Données TMDb · Application indépendante, non approuvée par TMDb.").font(.caption) }
            }.navigationTitle("Réglages")
        }
    }
}
