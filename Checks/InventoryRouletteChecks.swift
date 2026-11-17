import Foundation

@main
struct InventoryRouletteChecks {
    static func main() async throws {
        try await checkInventory()
        try checkDraw()
        try checkEraBalance()
        print("Jellyfin per-view inventory, pagination, external IDs, roulette quality and diversity passed.")
    }

    private static func checkInventory() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InventoryFixture.self]
        let session = URLSession(configuration: configuration)
        let client = JellyfinLibraryClient(server: "https://media.example.org/jellyfin", userID: "viewer",
                                          authorization: "MediaBrowser Token=\"fixture\"", session: session, pageSize: 2)
        let result = try await client.inventory()
        precondition(result.libraries.map(\.folder.id) == ["movies", "hidden-series", "mixed"])
        precondition(result.libraries.map(\.count) == [3, 1, 1])
        precondition(Set(result.titles.map(\.id)) == ["m1", "m2", "m3", "s1", "v1", "global"])

        let ownership = LibraryOwnership(result.titles)
        let movies: [TMItem] = try decode("""
        [{"id":12,"title":"A Different Title"},{"id":13,"title":"Independent Video","release_date":"1999-01-01"},
         {"id":34,"name":"Une série renommée","first_air_date":"2017-01-01"}]
        """)
        precondition(ownership.contains(movies[0]) && ownership.contains(movies[1]))
        precondition(!ownership.contains(movies[2]))
        precondition(ownership.hasExternalIDs(kind: "tv") && !ownership.hasExternalIDs(kind: "movie"))
        let external: TMDbExternalIDs = try decode(#"{"tvdb_id":17}"#)
        precondition(ownership.contains(kind: "tv", externalIDs: external))
        precondition(!ownership.contains(kind: "movie", externalIDs: external))
        let legacy: LibraryOwnership = try decode(#"{"ids":["movie:12"],"titlesWithoutID":[]}"#)
        precondition(legacy.contains(movies[0]))
        precondition(!legacy.hasExternalIDs(kind: "tv"))

        for viewer in ["truncated", "denied", "loop"] {
            let failing = JellyfinLibraryClient(server: "https://media.example.org/jellyfin", userID: viewer,
                                               authorization: "MediaBrowser Token=\"fixture\"", session: session, pageSize: 2)
            do {
                _ = try await failing.inventory()
                preconditionFailure("Partial inventories must fail")
            } catch JellyfinLibraryClient.Failure.incomplete {
                precondition(viewer != "denied")
            } catch JellyfinLibraryClient.Failure.http(403) {
                precondition(viewer == "denied")
            }
        }
    }

    private static func checkDraw() throws {
        let titles: [TMItem] = try decode("""
        [
          {"id":1,"title":"First movie","genre_ids":[28],"release_date":"1999-02-03","vote_average":9,"vote_count":1000},
          {"id":2,"title":"Same year","genre_ids":[28],"release_date":"1999-09-28","vote_average":8.9,"vote_count":50},
          {"id":3,"name":"Series","genre_ids":[10759],"first_air_date":"2007-04-01","vote_average":8.4,"vote_count":400},
          {"id":4,"title":"Japanese animated film","genre_ids":[16,14],"original_language":"ja",
           "release_date":"2021-03-08","vote_average":7.5,"vote_count":80},
          {"id":5,"title":"Too few votes","genre_ids":[28],"release_date":"1998-07-07","vote_average":10,"vote_count":1},
          {"id":6,"title":"Too low","genre_ids":[28],"release_date":"1997-05-13","vote_average":6,"vote_count":2000}
        ]
        """)
        let formats: Set<RouletteFormat> = [.film, .series, .anime, .animatedFilm]
        let classics = Roulette.Query(kind: .movie, format: .film, genre: 28, years: 1900...1999)
        precondition(titles.filter(classics.matches).map(\.id) == [1, 2])
        let anime = Roulette.Query(kind: .movie, format: .anime, genre: 14, years: 2015...2099)
        precondition(titles.filter(anime.matches).map(\.id) == [4])
        let endpoint = anime.endpoint(page: 3)
        let args = Dictionary(uniqueKeysWithValues: endpoint.queryItems!.map { ($0.name, $0.value ?? "") })
        precondition(args["with_genres"] == "16,14" && args["with_original_language"] == "ja")
        precondition(args["vote_count.gte"] == "50" && args["vote_average.gte"] == "6.8")
        precondition(args["primary_release_date.gte"] == "2015-01-01" && args["page"] == "3")
        let queries = Roulette.queries(formats: formats, genres: [.action, .fantasy])
        precondition(Set(queries.map(\.years)).count == 4 && Set(queries.map(\.format)) == formats)
        precondition(queries.allSatisfy { $0.genre != nil })
        precondition(!Roulette.canDraw(formats: [.series], genres: [.thriller]))

        let candidates = Array(titles.prefix(4))
        let ranked = Roulette.rank(candidates + [candidates[0]], excluding: []) { 0.5 }
        precondition(ranked.first?.id == 1 && Set(ranked.map(\.key)).count == 4)
        let history = Set(["movie:1"])
        precondition(!Roulette.rank(ranked, excluding: history).contains { $0.id == 1 })
        let alternative = Roulette.next(from: [candidates[1], candidates[2], candidates[3]],
                                        after: [candidates[0]], formats: formats,
                                        schedule: [.classics, .millennium, .contemporary])
        precondition(alternative?.id == 3)
    }

    private static func checkEraBalance() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!
        var rows: [[String: Any]] = []
        // Old titles deliberately dominate both volume and ratings.
        for year in 1950...2026 {
            rows.append(["id": year, "title": "Film \(year)", "release_date": "\(year)-01-01",
                         "genre_ids": [28], "vote_average": year < 2000 ? 9.8 : 7.9, "vote_count": 2000])
        }
        let candidates = try JSONDecoder().decode([TMItem].self, from: JSONSerialization.data(withJSONObject: rows))
        let formats: Set<RouletteFormat> = [.film]
        let schedule = Roulette.eraSchedule(count: 10) { 0.5 }
        let ranked = Roulette.rank(candidates, excluding: []) { 0.5 }
        var result: [TMItem] = []
        var remaining = ranked
        while result.count < 10,
              let next = Roulette.next(from: remaining, after: result, formats: formats, schedule: schedule, now: now) {
            result.append(next)
            remaining.removeAll { $0.key == next.key }
        }
        precondition(result.count == 10 && Set(result.map(\.key)).count == 10)
        let counts = Dictionary(grouping: result, by: { Roulette.era(for: $0, now: now)! }).mapValues(\.count)
        precondition(counts[.classics] == 2 && counts[.millennium] == 3)
        precondition(counts[.contemporary] == 3 && counts[.recent] == 2)
        precondition(Set(result.compactMap(\.year)).count >= 8)

        let oldOnly = candidates.filter { ($0.year ?? 0) < 2000 }
        var limited: [TMItem] = []
        while let next = Roulette.next(from: oldOnly.filter { item in !limited.contains { $0.key == item.key } },
                                       after: limited, formats: formats, schedule: schedule, now: now) {
            limited.append(next)
        }
        precondition(limited.count == 2)
        let recentOnly = candidates.filter { ($0.year ?? 0) >= 2023 }
        var current: [TMItem] = []
        while let next = Roulette.next(from: recentOnly.filter { item in !current.contains { $0.key == item.key } },
                                       after: current, formats: formats, schedule: schedule, now: now) {
            current.append(next)
        }
        precondition(current.count <= 3)

        let singles = (0..<1000).compactMap { sample in
            Roulette.eraSchedule(count: 1) { Double(sample) / 1000 }.first
        }
        precondition(singles.filter { $0 == .classics }.count == 200)
        precondition(singles.filter { $0 == .millennium || $0 == .contemporary }.count == 600)
        precondition(Roulette.reelPosition(elapsed: 0) == 0)
        precondition(Roulette.reelPosition(elapsed: 3.2) == 18)
        precondition(Roulette.reelPosition(elapsed: 6) == 18)
        precondition(Roulette.reelPosition(elapsed: 1) > 0 && Roulette.reelPosition(elapsed: 1) < 18)
        let startSpeed = Roulette.reelPosition(elapsed: 0.2) - Roulette.reelPosition(elapsed: 0.1)
        let endSpeed = Roulette.reelPosition(elapsed: 3.1) - Roulette.reelPosition(elapsed: 3)
        precondition(startSpeed > endSpeed)
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

private final class InventoryFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        precondition(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"fixture\"")
        guard let url = request.url, let client else { preconditionFailure("Missing Jellyfin fixture URL") }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let reply: (Int, String)
        switch url.path {
        case "/jellyfin/UserViews":
            precondition(query["IncludeHidden"] == "true" && query["IncludeExternalContent"] == "false")
            precondition(query["UserId"] != nil)
            reply = (200, """
            {"TotalRecordCount":3,"Items":[{"Id":"movies","Name":"Films A"},
             {"Id":"hidden-series","Name":"Séries masquées"},{"Id":"mixed","Name":"Vidéos"}]}
            """)
        case "/jellyfin/Items":
            precondition(query["Recursive"] == "true" && query["EnableTotalRecordCount"] == "true")
            precondition(query["IncludeItemTypes"] == "Movie,Series,Video" && query["Limit"] == "2")
            switch (query["ParentId"], query["StartIndex"]) {
            case ("movies", "0"):
                reply = (200, #"{"TotalRecordCount":3,"Items":[{"Id":"m1","Type":"Movie","ProviderIds":{"Tmdb":"12"}},{"Id":"m2","Type":"Movie"}]}"#)
            case ("movies", "2"):
                switch query["UserId"] {
                case "truncated": reply = (200, #"{"TotalRecordCount":3,"Items":[]}"#)
                case "loop": reply = (200, #"{"TotalRecordCount":3,"Items":[{"Id":"m1","Type":"Movie"}]}"#)
                default: reply = (200, #"{"TotalRecordCount":3,"Items":[{"Id":"m3","Type":"Movie"}]}"#)
                }
            case ("hidden-series", "0"):
                reply = query["UserId"] == "denied" ? (403, "{}") : (200, """
                {"TotalRecordCount":1,"Items":[{"Id":"s1","Type":"Series","ProviderIds":{"Tvdb":"17"}}]}
                """)
            case ("mixed", "0"):
                reply = (200, #"{"Items":[{"Id":"v1","Type":"Video","Name":"Independent Video","ProductionYear":1999}]}"#)
            case ("mixed", "1"):
                reply = (200, #"{"Items":[]}"#)
            case (nil, "0"):
                reply = (200, #"{"TotalRecordCount":2,"Items":[{"Id":"m1","Type":"Movie","ProviderIds":{"Tmdb":"12"}},{"Id":"global","Type":"Movie"}]}"#)
            default:
                preconditionFailure("Unexpected inventory page: \(query)")
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
