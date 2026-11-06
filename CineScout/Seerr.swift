import Foundation

struct SeerrClient {
    let base: URL
    let key: String

    init(address: String, key: String) throws {
        var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard parts?.scheme?.lowercased() == "https", parts?.host != nil,
              parts?.user == nil, parts?.password == nil, parts?.query == nil, parts?.fragment == nil else {
            throw Failure.message("Saisis l’adresse HTTPS de ton instance Seerr.")
        }
        let path = parts?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if path == "api/v1" || path.hasSuffix("/api/v1") {
            parts?.path = String(("/" + path).dropLast(7))
        } else {
            parts?.path = path.isEmpty ? "" : "/" + path
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace), let base = parts?.url else {
            throw Failure.message("Renseigne la clé API Seerr.")
        }
        self.base = base
        self.key = key
    }

    struct Media: Decodable {
        let id: Int
        let mediaInfo: Info?
        let seasons: [Season]?
        struct Season: Decodable { let seasonNumber: Int }
        struct Info: Decodable {
            let status: Int?
            let seasons: [SeasonStatus]?
            let requests: [ExistingRequest]?
        }
        struct SeasonStatus: Decodable { let seasonNumber: Int; let status: Int }
        struct ExistingRequest: Decodable {
            let status: Int
            let is4k: Bool?
            let seasons: [Season]?
        }

        var blockedSeasons: Set<Int> {
            let tracked = (mediaInfo?.seasons ?? []).filter { (2...5).contains($0.status) }.map(\.seasonNumber)
            let requested = (mediaInfo?.requests ?? []).filter { $0.is4k != true && (1...2).contains($0.status) }
                .flatMap { $0.seasons ?? [] }.map(\.seasonNumber)
            return Set(tracked + requested)
        }
    }

    struct Submission: Encodable {
        let mediaType: String
        let mediaId: Int
        let seasons: [Int]?
        let is4k = false
    }

    struct Receipt: Decodable { let id: Int; let status: Int? }
    private struct Account: Decodable { let id: Int }
    private struct APIError: Decodable { let message: String? }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    func check() async throws {
        let _: Account = try await fetch("auth/me")
    }

    func details(kind: String, id: Int) async throws -> Media {
        try await fetch("\(kind)/\(id)")
    }

    func submit(_ submission: Submission) async throws -> Receipt {
        try await fetch("request", body: JSONEncoder().encode(submission))
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func fetch<T: Decodable>(_ path: String, body: Data? = nil) async throws -> T {
        let url = ("api/v1/" + path).split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw Failure.message("Cette adresse n’a pas renvoyé une réponse Seerr valide.") }
        case 300...399:
            throw Failure.message("L’adresse redirige vers une autre page. Utilise directement l’URL HTTPS de Seerr.")
        case 401, 403:
            throw Failure.message("Accès refusé par Seerr. Vérifie la clé API.")
        case 404:
            throw Failure.message("Ressource introuvable. Vérifie l’adresse et le chemin de Seerr.")
        default:
            let reason = (try? JSONDecoder().decode(APIError.self, from: data))?.message
            throw Failure.message(reason.map { "Seerr : \($0)" } ?? "Seerr indisponible (HTTP \(status)).")
        }
    }
}
