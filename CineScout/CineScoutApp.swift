import SwiftUI
import Security

@main
struct CineScoutApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model).environmentObject(model.torrents) }
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

struct JellyfinItems: Decodable { let Items: [Media]; let TotalRecordCount: Int? }
struct AuthResponse: Decodable {
    let AccessToken: String
    let User: Account
    struct Account: Decodable { let Id: String }
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
    @Published var hideOwnedSeries = true
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
    let torrents = TorrentChecks()
    @Published private(set) var seerrAddress = UserDefaults.standard.string(forKey: "seerrAddress") ?? ""
    @Published private(set) var seerrRevision = 0
    private(set) var seerrKey = Secrets.get("seerrKey")

    func seerrClient() throws -> SeerrClient {
        try SeerrClient(address: seerrAddress, key: seerrKey)
    }

    func saveSeerr(address: String, key: String) {
        seerrKey = key
        Secrets.set(key, for: "seerrKey")
        seerrAddress = address
        UserDefaults.standard.set(address, forKey: "seerrAddress")
        seerrRevision += 1
    }
    private var token = Secrets.get("jellyfin")
    private var userId = UserDefaults.standard.string(forKey: "userId") ?? ""
    @Published private var ownership = (try? JSONDecoder().decode(
        LibraryOwnership.self, from: UserDefaults.standard.data(forKey: "jellyfinOwnership") ?? Data()
    )) ?? LibraryOwnership()
    private var sessionServer = UserDefaults.standard.string(forKey: "sessionServer") ?? UserDefaults.standard.string(forKey: "server") ?? "https://akarukasu.astra.usbx.me/jellyfin"
    private var jellyfinAuthorization: String {
        "MediaBrowser Client=\"CineScout\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
    }
    var hasTasteProfile: Bool { !preferredGenres(for: mediaType).isEmpty }

    func owns(_ item: TMItem) -> Bool { ownership.contains(item) }

    func canSuggest(_ item: TMItem) -> Bool {
        (item.kind == "tv" && !hideOwnedSeries) || !owns(item)
    }

    private func clearOwnership() {
        ownership = LibraryOwnership()
        UserDefaults.standard.removeObject(forKey: "jellyfinOwnership")
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
            clearOwnership()
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
                    .init(name: "Fields", value: "ProviderIds,Genres,OriginalTitle"),
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
            ownership = LibraryOwnership(items)
            if let data = try? JSONEncoder().encode(ownership) {
                UserDefaults.standard.set(data, forKey: "jellyfinOwnership")
            }
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
        busy = true
        defer { busy = false }
        do {
            let page: TMPage = try await fetchTMDb(parts, key: key)
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
        } catch { discoveryMessage = error.localizedDescription }
    }

    func metadata(for item: TMItem) async throws -> TitleMetadata {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.themoviedb.org"
        parts.path = "/3/\(item.kind)/\(item.id)"
        parts.queryItems = [.init(name: "language", value: "fr-FR"),
                            .init(name: "append_to_response", value: "credits,recommendations,similar")]
        return try await fetchTMDb(parts, key: tmdbKey)
    }

    private func fetchTMDb<T: Decodable>(_ endpoint: URLComponents, key: String) async throws -> T {
        var parts = endpoint
        let legacyKey = key.count == 32 && key.allSatisfy(\.isHexDigit)
        if legacyKey { parts.queryItems = (parts.queryItems ?? []) + [.init(name: "api_key", value: key)] }
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if !legacyKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw TMDbError(message: [401, 403].contains(status)
                            ? "TMDb a refusé le jeton ou la clé API." : "TMDb indisponible (HTTP \(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct TMDbError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
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
        clearOwnership()
    }
}

struct RootView: View {
    enum Tab: Hashable { case discover, library, wishlist, settings }
    @EnvironmentObject var model: LibraryModel
    @State private var tab = Tab.discover

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs.tabBarMinimizeBehavior(.onScrollDown)
            } else {
                tabs
            }
        }
        .task {
            await model.refresh()
            if !model.tmdbKey.isEmpty && model.discoveries.isEmpty { await model.discover() }
        }
    }

    private var tabs: some View {
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
    }
}
struct Poster: View {
    let path: String?
    var landscape = false
    var cornerRadius: CGFloat = 14
    var body: some View {
        Rectangle().fill(Color(uiColor: .tertiarySystemFill))
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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }
}
