import Foundation

struct ProwlarrClient {
    let base: URL
    private let key: String
    private let session: URLSession

    init(address: String, key: String, session: URLSession = .shared) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw Failure.message("Saisis l’adresse HTTPS de ton instance Prowlarr.")
        }
        parts.scheme = "https"
        let path = "/" + parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = path.lowercased().hasSuffix("/api/v1") ? String(path.dropLast(7)) : path
        if parts.percentEncodedPath == "/" { parts.percentEncodedPath = "" }

        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace), let base = parts.url else {
            throw Failure.message("Renseigne la clé API Prowlarr.")
        }
        self.base = base
        self.key = key
        self.session = session
    }

    struct Availability: Equatable {
        let count: Int
        let bestSeeders: Int?
    }

    func check() async throws {
        let status: Status = try await get("system/status")
        guard status.appName.caseInsensitiveCompare("Prowlarr") == .orderedSame else {
            throw Failure.message("Cette adresse ne répond pas comme une instance Prowlarr.")
        }
    }

    func availability(for movie: TMItem) async throws -> Availability {
        let titles = movie.titles.map(TitleMatch.words).filter { !$0.isEmpty }
        var searched = Set<[String]>()
        for title in movie.titles {
            let words = TitleMatch.words(title)
            guard !words.isEmpty, searched.insert(words).inserted else { continue }
            let query = [title.trimmingCharacters(in: .whitespacesAndNewlines), movie.year.map(String.init)]
                .compactMap { $0 }.joined(separator: " ")
            let releases: [Release] = try await get("search", query: [
                .init(name: "query", value: query),
                .init(name: "type", value: "search"),
                .init(name: "categories", value: "2000"),
                .init(name: "indexerIds", value: "-2")
            ])
            let matches = releases.filter { $0.matches(movie, titles: titles) }
            if !matches.isEmpty {
                return Availability(count: matches.count, bestSeeders: matches.compactMap(\.seeders).max())
            }
        }
        return Availability(count: 0, bestSeeders: nil)
    }

    private struct Status: Decodable { let appName: String }

    private struct Release: Decodable {
        let title: String
        let tmdbId: Int?
        let seeders: Int?
        let protocolName: String?
        let downloadUrl: String?
        let magnetUrl: String?

        private enum CodingKeys: String, CodingKey {
            case title, tmdbId, seeders, downloadUrl, magnetUrl
            case protocolName = "protocol"
        }

        func matches(_ movie: TMItem, titles: [[String]]) -> Bool {
            guard protocolName?.lowercased() == "torrent",
                  [downloadUrl, magnetUrl].contains(where: { $0?.isEmpty == false }) else { return false }
            if let tmdbId, tmdbId > 0 { return tmdbId == movie.id }
            guard let year = movie.year else { return false }
            let words = TitleMatch.words(title)
            return titles.contains { words.starts(with: $0 + [String(year)]) }
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let endpoint = ("/api/v1/" + path).split(separator: "/")
            .reduce(base) { $0.appendingPathComponent(String($1)) }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        if !query.isEmpty { parts?.queryItems = query }
        guard let url = parts?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw Failure.message("Réponse Prowlarr illisible. Vérifie l’adresse du serveur.") }
        case 301...308:
            throw Failure.message("Prowlarr redirige cette adresse. Utilise son URL HTTPS finale.")
        case 400 where path == "search":
            throw Failure.message("Recherche refusée. Vérifie les indexeurs torrent dans Prowlarr.")
        case 401, 403:
            throw Failure.message("Accès refusé. Vérifie la clé API Prowlarr.")
        case 404:
            throw Failure.message("API Prowlarr introuvable. Vérifie le chemin du serveur.")
        case 429:
            throw Failure.message("Limite de recherche Prowlarr atteinte. Réessaie plus tard.")
        default:
            throw Failure.message("Prowlarr indisponible (HTTP \(status)).")
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}
