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
    let Id: String?
    let Name: String?
    let Type: String?
    let ProductionYear: Int?
    let Overview: String?
    let ProviderIds: [String: String]?
    var id: String { Id ?? UUID().uuidString }
    var title: String { Name ?? "Sans titre" }
}
struct JellyfinItems: Decodable { let Items: [Media] }
struct AuthResponse: Decodable { let AccessToken: String }

struct TMPage: Decodable { let results: [TMItem] }
struct TMItem: Identifiable, Decodable {
    let id: Int
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
    @Published var favorites: Set<Int> = Set(UserDefaults.standard.array(forKey: "favorites") as? [Int] ?? [])
    @Published var tmdbKey = Secrets.get("tmdb")
    private var token = Secrets.get("jellyfin")
    private var userId = UserDefaults.standard.string(forKey: "userId") ?? ""
    var owned: Set<String> { Set(library.compactMap { $0.ProviderIds?["Tmdb"] }) }
    func saveSettings() {
        server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(server, forKey: "server")
        Secrets.set(tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "tmdb")
    }
    func login(password: String) async {
        busy = true; defer { busy = false }
        saveSettings()
        guard let url = URL(string: server + "/Users/AuthenticateByName") else { message = "URL Jellyfin invalide"; return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MediaBrowser Client=\"CineScout\", Device=\"iPhone\", DeviceId=\"cinescout-ios\", Version=\"1.0\"", forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { message = "Connexion refusée. Vérifie tes identifiants."; return }
            let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let user = json?["User"] as? [String: Any]
            userId = user?["Id"] as? String ?? ""
            guard !userId.isEmpty else { message = "Identifiant utilisateur manquant"; return }
            token = auth.AccessToken
            Secrets.set(token, for: "jellyfin")
            UserDefaults.standard.set(userId, forKey: "userId")
            UserDefaults.standard.set(username, forKey: "username")
            connected = true; message = ""
            await refresh()
        } catch { message = "Erreur de connexion : \(error.localizedDescription)" }
    }
    func refresh() async {
        guard !token.isEmpty, !userId.isEmpty else { return }
        guard var parts = URLComponents(string: server + "/Users/\(userId)/Items") else { return }
        parts.queryItems = [URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"), URLQueryItem(name: "Fields", value: "ProviderIds"), URLQueryItem(name: "Limit", value: "10000")]
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { message = "Session Jellyfin expirée"; connected = false; return }
            library = try JSONDecoder().decode(JellyfinItems.self, from: data).Items
            connected = true
        } catch { message = "Bibliothèque : \(error.localizedDescription)" }
    }
    func discover() async {
        saveSettings()
        guard !tmdbKey.isEmpty else { message = "Ajoute ta clé TMDb dans Réglages."; return }
        busy = true; defer { busy = false }
        guard var parts = URLComponents(string: "https://api.themoviedb.org/3/discover/\(mediaType)") else { return }
        var queries = [URLQueryItem(name: "language", value: "fr-FR"), URLQueryItem(name: "sort_by", value: "vote_count.desc"), URLQueryItem(name: "vote_average.gte", value: String(minRating)), URLQueryItem(name: "vote_count.gte", value: "100"), URLQueryItem(name: "page", value: "1")]
        if !genre.isEmpty { queries.append(URLQueryItem(name: "with_genres", value: genre)) }
        if let year = Int(minYear), year >= 1900 {
            queries.append(URLQueryItem(name: mediaType == "movie" ? "primary_release_date.gte" : "first_air_date.gte", value: "\(year)-01-01"))
        }
        parts.queryItems = queries
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(tmdbKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { message = "TMDb : vérifie ton jeton API (Read Access Token)."; return }
            discoveries = try JSONDecoder().decode(TMPage.self, from: data).results
            message = ""
        } catch { message = "TMDb : \(error.localizedDescription)" }
    }
    func toggle(_ id: Int) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }
    func logout() {
        token = ""; Secrets.set("", for: "jellyfin"); connected = false; library = []
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
    var body: some View {
        AsyncImage(url: path.flatMap { URL(string: "https://image.tmdb.org/t/p/w342" + $0) }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.white.opacity(0.08)).overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
        .aspectRatio(2/3, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
struct DiscoverView: View {
    @EnvironmentObject var model: LibraryModel
    private let genres = [("Tous", ""), ("Action", "28"), ("Comédie", "35"), ("Drame", "18"), ("Horreur", "27"), ("Thriller", "53"), ("Science-fiction", "878"), ("Animation", "16"), ("Documentaire", "99")]
    var visible: [TMItem] { model.discoveries.filter { !model.hideOwned || !model.owned.contains(String($0.id)) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Trouve ton prochain coup de cœur").font(.title2.bold())
                    Picker("Type", selection: $model.mediaType) {
                        Text("Films").tag("movie"); Text("Séries").tag("tv")
                    }.pickerStyle(.segmented)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(genres.indices, id: \.self) { index in
                                Button(genres[index].0) { model.genre = genres[index].1 }.buttonStyle(.bordered)
                                    .tint(model.genre == genres[index].1 ? .purple : .gray)
                            }
                        }
                    }.scrollIndicators(.hidden)
                    HStack {
                        TextField("Depuis l'année", text: $model.minYear).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        Text("Note ≥ \(model.minRating, specifier: "%.1f")")
                        Slider(value: $model.minRating, in: 0...9, step: 0.5).frame(width: 90)
                    }
                    Toggle("Masquer les titres déjà présents", isOn: $model.hideOwned).font(.subheadline)
                    Button { Task { await model.discover() } } label: {
                        Label(model.busy ? "Recherche…" : "Explorer le catalogue", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                    if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange).font(.caption) }
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
                }.padding()
            }.background(Color(red: 0.055, green: 0.065, blue: 0.10))
                .navigationTitle("CinéScout")
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
                if model.owned.contains(String(item.id)) { Label("Déjà sur Jellyfin", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button {
                    model.toggle(item.id)
                } label: {
                    Label(model.favorites.contains(item.id) ? "Retirer de ma liste" : "Ajouter à ma liste", systemImage: model.favorites.contains(item.id) ? "bookmark.fill" : "bookmark")
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
                ForEach(filtered) { item in
                    HStack {
                        Image(systemName: item.Type == "Series" ? "tv" : "film").foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text("\(item.ProductionYear.map(String.init) ?? "—") · \(item.Type ?? "")").font(.caption).foregroundStyle(.secondary)
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
                if model.favorites.isEmpty { Text("Ajoute des films et séries depuis Découvrir.") }
                ForEach(model.discoveries.filter { model.favorites.contains($0.id) }) { item in
                    NavigationLink(item.display) { DetailView(item: item) }
                }
                if model.favorites.count > model.discoveries.filter({ model.favorites.contains($0.id) }).count {
                    Text("Certains favoris sont enregistrés mais ne figurent pas dans la page de découvertes actuelle.").font(.caption)
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
                    Button("Déconnexion", role: .destructive) { model.logout() }
                }
                Section("TMDb") {
                    SecureField("TMDb API Read Access Token", text: $model.tmdbKey)
                    Button("Enregistrer les réglages") { model.saveSettings() }
                    Text("Le jeton TMDb est nécessaire pour découvrir des titres absents de Jellyfin.").font(.caption)
                }
                if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange) }
                Section { Text("Données TMDb · Application indépendante, non approuvée par TMDb.").font(.caption) }
            }.navigationTitle("Réglages")
        }
    }
}
