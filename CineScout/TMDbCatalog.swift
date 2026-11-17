import Foundation

enum CatalogSearchScope: String, CaseIterable, Identifiable {
    case all, movies, series, anime

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "Tout"
        case .movies: "Films"
        case .series: "Séries"
        case .anime: "Animes"
        }
    }

    var endpoint: String {
        switch self {
        case .all, .anime: "multi"
        case .movies: "movie"
        case .series: "tv"
        }
    }

    func includes(_ item: TMItem) -> Bool {
        guard item.media_type == nil || ["movie", "tv"].contains(item.media_type ?? ""),
              !item.titles.isEmpty else { return false }
        switch self {
        case .all: return true
        case .movies: return item.kind == "movie"
        case .series: return item.kind == "tv"
        case .anime: return item.isAnime
        }
    }
}

enum StreamingMedia: String, CaseIterable, Identifiable {
    case movie, tv

    var id: Self { self }
    var label: String { self == .movie ? "Films" : "Séries" }
}

struct WatchProvider: Decodable, Identifiable {
    let provider_id: Int
    let provider_name: String
    let logo_path: String?
    let display_priority: Int?
    var id: Int { provider_id }
}

struct WatchProviderDirectory: Decodable {
    let results: [WatchProvider]
}

struct WatchAvailability: Decodable {
    let results: [String: Offers]

    struct Offers: Decodable {
        let link: URL?
        let flatrate: [WatchProvider]?
        let free: [WatchProvider]?
        let ads: [WatchProvider]?
        let rent: [WatchProvider]?
        let buy: [WatchProvider]?

        struct Group: Identifiable {
            let label: String
            let providers: [WatchProvider]
            var id: String { label }
        }

        var groups: [Group] {
            let entries = [("Abonnement", flatrate), ("Gratuit", free), ("Avec publicité", ads),
                           ("Location", rent), ("Achat", buy)]
            return entries.compactMap { label, providers in
                var ids = Set<Int>()
                let unique = (providers ?? []).filter { ids.insert($0.id).inserted }
                return unique.isEmpty ? nil : Group(label: label, providers: unique)
            }
        }
    }
}

enum TMDbCatalog {
    static let market = "FR"

    static func search(_ query: String, scope: CatalogSearchScope, page: Int) -> URLComponents {
        endpoint("search/\(scope.endpoint)", [
            .init(name: "query", value: query),
            .init(name: "include_adult", value: "false"),
            .init(name: "page", value: String(page))
        ])
    }

    static func cinema(page: Int, now: Date = .now) -> URLComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let start = calendar.date(byAdding: .day, value: -34, to: now) ?? now
        let format = Date.ISO8601FormatStyle(timeZone: calendar.timeZone)
            .year().month().day().dateSeparator(.dash)
        return discovery(.movie, page: page, query: [
            .init(name: "region", value: market),
            .init(name: "with_release_type", value: "3|2"),
            .init(name: "release_date.gte", value: start.formatted(format)),
            .init(name: "release_date.lte", value: now.formatted(format))
        ])
    }

    static func streaming(_ kind: StreamingMedia, provider: Int?, page: Int) -> URLComponents {
        var query: [URLQueryItem] = [
            .init(name: "watch_region", value: market),
            .init(name: "with_watch_monetization_types", value: "flatrate|free|ads")
        ]
        if let provider { query.append(.init(name: "with_watch_providers", value: String(provider))) }
        return discovery(kind, page: page, query: query)
    }

    static func providers(_ kind: StreamingMedia) -> URLComponents {
        endpoint("watch/providers/\(kind.rawValue)", [.init(name: "watch_region", value: market)])
    }

    static func title(_ item: TMItem) -> URLComponents {
        endpoint("\(item.kind)/\(item.id)")
    }

    static func offers(for item: TMItem) -> URLComponents {
        endpoint("\(item.kind)/\(item.id)/watch/providers")
    }

    private static func discovery(_ kind: StreamingMedia, page: Int, query: [URLQueryItem]) -> URLComponents {
        endpoint("discover/\(kind.rawValue)", query + [
            .init(name: "include_adult", value: "false"),
            .init(name: "sort_by", value: "popularity.desc"),
            .init(name: "page", value: String(page))
        ])
    }

    private static func endpoint(_ path: String, _ query: [URLQueryItem] = []) -> URLComponents {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.themoviedb.org"
        parts.path = "/3/" + path
        parts.queryItems = [.init(name: "language", value: "fr-FR")] + query
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts
    }
}

struct CatalogResults {
    private(set) var items: [TMItem] = []
    private(set) var nextPage: Int? = 1
    private var seen = Set<String>()

    @discardableResult
    mutating func append(_ response: TMPage, page: Int, including: (TMItem) -> Bool = { _ in true }) -> Bool {
        let matches = response.results.filter { including($0) && seen.insert($0.key).inserted }
        items += matches
        nextPage = page < min(response.total_pages, 500) ? page + 1 : nil
        return !matches.isEmpty
    }
}
