import Foundation

@main
struct DiscoveryChecks {
    static func main() throws {
        let titles = try JSONDecoder().decode(TMPage.self, from: Data("""
        {"results":[
          {"id":10,"media_type":"person","name":"Une personne"},
          {"id":20,"media_type":"movie","title":"La Nuit"},
          {"id":20,"media_type":"tv","name":"La Nuit animée","original_language":"ja","genre_ids":[16]},
          {"id":21,"media_type":"movie","title":"Animation","original_language":"fr","genre_ids":[16]},
          {"id":22,"media_type":"movie","title":"Anime film","original_language":"ja","genre_ids":[16]}
        ],"total_pages":2}
        """.utf8))
        precondition(titles.results.filter(CatalogSearchScope.all.includes).count == 4)
        precondition(titles.results.filter(CatalogSearchScope.anime.includes).map(\.key) == ["tv:20", "movie:22"])
        precondition(titles.results.filter(CatalogSearchScope.movies.includes).count == 3)
        var result = CatalogResults()
        precondition(result.append(titles, page: 1, including: CatalogSearchScope.all.includes))
        precondition(!result.append(titles, page: 2, including: CatalogSearchScope.all.includes))
        precondition(result.items.count == 4 && result.nextPage == nil)

        let search = TMDbCatalog.search("L’été & C++", scope: .anime, page: 2)
        precondition(search.path == "/3/search/multi")
        precondition(query(search)["query"] == "L’été & C++")
        precondition(search.url?.absoluteString.contains("C%2B%2B") == true)
        precondition(query(search)["page"] == "2")
        precondition(query(search)["include_adult"] == "false")

        let day = ISO8601DateFormatter().date(from: "2026-11-17T23:30:00Z")!
        let cinema = query(TMDbCatalog.cinema(page: 1, now: day))
        precondition(cinema["region"] == "FR" && cinema["with_release_type"] == "3|2")
        precondition(cinema["release_date.gte"] == "2026-10-15" && cinema["release_date.lte"] == "2026-11-18")

        let streaming = TMDbCatalog.streaming(.tv, provider: 8, page: 2)
        precondition(streaming.path == "/3/discover/tv")
        precondition(query(streaming)["watch_region"] == "FR")
        precondition(query(streaming)["with_watch_providers"] == "8")
        precondition(query(streaming)["with_watch_monetization_types"] == "flatrate|free|ads")
        precondition(query(TMDbCatalog.streaming(.movie, provider: nil, page: 1))["with_watch_providers"] == nil)

        let availability = try JSONDecoder().decode(WatchAvailability.self, from: Data("""
        {"results":{"FR":{
          "link":"https://www.themoviedb.org/movie/20/watch?locale=FR",
          "flatrate":[{"provider_name":"Plateforme A","provider_id":8},{"provider_name":"Plateforme A","provider_id":8}],
          "rent":[{"provider_name":"Plateforme B","provider_id":9}]
        }}}
        """.utf8))
        let groups = availability.results[TMDbCatalog.market]?.groups ?? []
        precondition(groups.map(\.label) == ["Abonnement", "Location"])
        precondition(groups.first?.providers.count == 1)
        precondition(TMDbCatalog.offers(for: result.items[1]).path == "/3/tv/20/watch/providers")
        precondition(Set(EditorialPick.selection.map(\.id)).count == EditorialPick.selection.count)
        precondition(EditorialPick.selection.allSatisfy { $0.item.year == $0.year && $0.article.scheme == "https" })
        print("Catalog search, anime filtering, French theatrical releases, legal streaming and editorial picks passed.")
    }

    private static func query(_ endpoint: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (endpoint.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
