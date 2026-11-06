import Foundation

struct SeerrClient {
    let base: URL
    let key: String
    private let session: URLSession

    init(address: String, key: String, session: URLSession = .shared) throws {
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
        self.session = session
    }

    struct Media: Decodable {
        let id: Int
        let mediaInfo: Info?
        let seasons: [Season]?
        struct Season: Decodable {
            let seasonNumber: Int
            let episodeCount: Int?
        }
        struct Info: Decodable {
            let status: Int?
            let seasons: [SeasonStatus]?
            let requests: [ExistingRequest]?
        }
        struct SeasonStatus: Decodable { let seasonNumber: Int; let status: Int }
        struct ExistingRequest: Decodable {
            let id: Int?
            let status: Int
            let is4k: Bool?
            let seasons: [Season]?
        }

        var blockedSeasons: Set<Int> {
            let tracked = (mediaInfo?.seasons ?? []).filter { (2...5).contains($0.status) }.map(\.seasonNumber)
            let requested = (mediaInfo?.requests ?? []).filter { $0.is4k != true && [1, 2, 4].contains($0.status) }
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

    struct Receipt: Decodable {
        let id: Int
        let status: Int?
        var label: String {
            let prefix = "Demande n°\(id)"
            switch status {
            case 1: return "\(prefix) en attente d’approbation"
            case 2: return "\(prefix) approuvée"
            case 3: return "\(prefix) refusée"
            case 4: return "\(prefix) en échec côté Seerr"
            case 5: return "\(prefix) terminée"
            default: return "\(prefix) enregistrée"
            }
        }
    }
    private struct Account: Decodable { let id: Int }
    private struct APIError: Decodable { let message: String?; let error: String? }

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

    func receipt(id: Int) async throws -> Receipt {
        try await fetch("request/\(id)")
    }

    var requestsURL: URL { base.appendingPathComponent("requests") }

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
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        let reason = apiError?.message ?? apiError?.error
        switch status {
        case 202 where body != nil:
            throw Failure.message("Seerr n’a créé aucune demande (202). Les saisons choisies sont déjà demandées ou indisponibles.")
        case 200...299:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch {
                throw Failure.message(body == nil
                    ? "Réponse inattendue (HTTP \(status)). Vérifie que l’adresse pointe bien vers Seerr."
                    : "Seerr n’a pas renvoyé de numéro de demande (HTTP \(status)). Consulte ses demandes avant de réessayer.")
            }
        case 300...399:
            throw Failure.message("L’adresse redirige vers une autre page. Utilise directement l’URL HTTPS de Seerr.")
        case 401 where body == nil, 403 where body == nil:
            throw Failure.message("Accès refusé par Seerr (HTTP \(status)). Vérifie la clé API de cette instance.")
        case 409:
            throw Failure.message("Seerr signale qu’une demande existe déjà pour ce titre (409).")
        case 404:
            throw Failure.message("Ressource introuvable. Vérifie l’adresse et le chemin de Seerr.")
        default:
            throw Failure.message(reason.map { "Seerr (HTTP \(status)) : \($0)" }
                                  ?? "Seerr indisponible (HTTP \(status)).")
        }
    }
}
