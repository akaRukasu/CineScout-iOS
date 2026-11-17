import Foundation

@main
struct CatalogChecks {
    static func main() async throws {
        try checkLibraryOwnership()
        try await checkProwlarr()
        print("Jellyfin ownership and Prowlarr torrent checks passed.")
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func checkLibraryOwnership() throws {
        let library: [Media] = try decode("""
        [
          {"Id":"1","Type":"Movie","Name":"Film renommé","ProviderIds":{"TMDB":"042"}},
          {"Id":"2","Type":"Movie","Name":"Titre local","OriginalTitle":"L’Été bleu","ProductionYear":2006,
           "ProviderIds":{"Tmdb":null}},
          {"Id":"3","Type":"Movie","Name":"Dune","ProductionYear":2021,"ProviderIds":{"Tmdb":"438631"}},
          {"Id":"4","Type":"Series","Name":"Titre local","ProductionYear":2006,"ProviderIds":{"Tmdb":"42"}}
        ]
        """)
        let ownership = LibraryOwnership(library)
        let existing: TMItem = try decode(#"{"id":42,"title":"Titre différent"}"#)
        let noProviderID: TMItem = try decode(#"{"id":43,"title":"L'Ete Bleu","release_date":"2006-06-15"}"#)
        let remake: TMItem = try decode(#"{"id":44,"title":"L’Été bleu","release_date":"2011-06-15"}"#)
        let missingYear: TMItem = try decode(#"{"id":44,"title":"L’Été bleu"}"#)
        let conflict: TMItem = try decode(#"{"id":45,"title":"Dune","release_date":"2021-09-15"}"#)
        let series: TMItem = try decode(#"{"id":43,"name":"L’Été bleu","first_air_date":"2006-06-15"}"#)
        precondition(existing.kind == "movie" && existing.original_title == nil)
        precondition(ownership.contains(existing))
        precondition(ownership.contains(noProviderID))
        precondition(!ownership.contains(remake) && !ownership.contains(missingYear))
        precondition(!ownership.contains(conflict) && !ownership.contains(series))
        let persisted = try JSONDecoder().decode(LibraryOwnership.self, from: JSONEncoder().encode(ownership))
        precondition(persisted.contains(noProviderID))
    }

    private static func checkProwlarr() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProwlarrFixture.self]
        let session = URLSession(configuration: configuration)
        let client = try ProwlarrClient(address: " https://media.example.org/prowlarr/api/v1/ ",
                                       key: " fixture-key ", session: session)
        precondition(client.base.absoluteString == "https://media.example.org/prowlarr")
        precondition((try? ProwlarrClient(address: "http://media.example.org", key: "fixture-key")) == nil)
        try await client.check()
        let movie: TMItem = try decode("""
        {"id":75,"title":"La Nuit d’été","original_title":"Summer Night","release_date":"2021-10-02"}
        """)
        let found = try await client.availability(for: movie)
        precondition(found.count == 2 && found.bestSeeders == 8)
        let missing: TMItem = try decode(#"{"id":76,"title":"Absent","release_date":"2020-10-02"}"#)
        let empty = try await client.availability(for: missing)
        precondition(empty.count == 0 && empty.bestSeeders == nil)
        let rejected: TMItem = try decode(#"{"id":77,"title":"Accès refusé","release_date":"2020-10-02"}"#)
        do {
            _ = try await client.availability(for: rejected)
            preconditionFailure("Prowlarr authentication errors must be distinguishable from empty results")
        } catch {
            precondition(error.localizedDescription.contains("Accès refusé"))
        }
    }
}

private final class ProwlarrFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        precondition(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "X-Api-Key") == "fixture-key")
        guard let url = request.url, let client else { preconditionFailure("Missing fixture URL") }
        let reply: (Int, String)
        switch url.path {
        case "/prowlarr/api/v1/system/status":
            reply = (200, #"{"appName":"Prowlarr"}"#)
        case "/prowlarr/api/v1/search":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            precondition(query["categories"] == "2000" && query["indexerIds"] == "-2" && query["type"] == "search")
            precondition(query["apikey"] == nil)
            switch query["query"] {
            case "La Nuit d’été 2021", "Absent 2020":
                reply = (200, "[]")
            case "Summer Night 2021":
                reply = (200, """
                [
                  {"title":"Summer.Night.2021.1080p","protocol":"torrent","seeders":5,"downloadUrl":"https://test.example/download"},
                  {"title":"Alternate.Name.2021","tmdbId":75,"protocol":"torrent","seeders":8,"magnetUrl":"magnet:?xt=urn:btih:example"},
                  {"title":"Summer.Night.1988.1080p","protocol":"torrent","seeders":44,"downloadUrl":"https://test.example/download"},
                  {"title":"Summer.Night.2021.720p","tmdbId":76,"protocol":"torrent","seeders":43,"downloadUrl":"https://test.example/download"},
                  {"title":"Summer.Night.2021.1080p","protocol":"usenet","seeders":42,"downloadUrl":"https://test.example/download"},
                  {"title":"Summer.Night.2021.2160p","protocol":"torrent","seeders":41}
                ]
                """)
            case "Accès refusé 2020":
                reply = (401, "{}")
            default:
                preconditionFailure("Unexpected query: \(query)")
            }
        default:
            preconditionFailure("Unexpected fixture path: \(url.path)")
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client.urlProtocolDidFinishLoading(self)
    }
}
