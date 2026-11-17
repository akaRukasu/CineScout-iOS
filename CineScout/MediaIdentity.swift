import Foundation

struct Media: Identifiable, Decodable {
    let Id: String
    let Name: String?
    let OriginalTitle: String?
    let mediaType: String?
    let ProductionYear: Int?
    let Genres: [String]?
    let UserData: Playback?
    let ProviderIds: [String: String?]?

    enum CodingKeys: String, CodingKey {
        case Id, Name, OriginalTitle, ProductionYear, Genres, UserData, ProviderIds
        case mediaType = "Type"
    }

    struct Playback: Decodable { let Played: Bool?; let IsFavorite: Bool? }
    var id: String { Id }
    var title: String { Name ?? "Sans titre" }
}

struct TMPage: Decodable { let results: [TMItem]; let total_pages: Int }

struct TMItem: Identifiable, Codable {
    let id: Int
    let media_type: String?
    let original_language: String?
    let genre_ids: [Int]?
    let backdrop_path: String?
    let title: String?
    let name: String?
    let original_title: String?
    let original_name: String?
    let overview: String?
    let poster_path: String?
    let vote_average: Double?
    let release_date: String?
    let first_air_date: String?
    let editorialYear: Int?

    var kind: String { media_type ?? (title == nil && original_title == nil ? "tv" : "movie") }
    var isAnime: Bool { original_language == "ja" && genre_ids?.contains(16) == true }
    var kindLabel: String {
        if isAnime { return kind == "tv" ? "Série animée" : "Film d’animation" }
        return kind == "tv" ? "Série" : "Film"
    }
    var key: String { "\(kind):\(id)" }
    var display: String { title ?? name ?? original_title ?? original_name ?? "Sans titre" }
    var date: String? { kind == "tv" ? first_air_date : release_date }
    var year: Int? { date.flatMap { Int($0.prefix(4)) }.flatMap { $0 > 0 ? $0 : nil } ?? editorialYear }
    var releaseDateText: String? { ReleaseDate.french(date) }
    var titles: [String] { [title, original_title, name, original_name].compactMap { $0 } }
}

enum TitleMatch {
    static func words(_ title: String) -> [String] {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

struct LibraryOwnership: Codable {
    private var ids = Set<String>()
    private var titlesWithoutID = Set<String>()

    init(_ media: [Media] = []) {
        for item in media {
            let kind: String
            switch item.mediaType {
            case "Movie": kind = "movie"
            case "Series": kind = "tv"
            default: continue
            }
            let tmdb = item.ProviderIds?.first { $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame }
            if let rawID = tmdb?.value, let id = Int(rawID.trimmingCharacters(in: .whitespaces)), id > 0 {
                ids.insert("\(kind):\(id)")
            } else if let year = item.ProductionYear, year > 0 {
                for title in [item.Name, item.OriginalTitle].compactMap({ $0 }) {
                    if let key = Self.titleKey(kind: kind, title: title, year: year) {
                        titlesWithoutID.insert(key)
                    }
                }
            }
        }
    }

    func contains(_ item: TMItem) -> Bool {
        if ids.contains(item.key) { return true }
        guard let year = item.year else { return false }
        return item.titles.compactMap { Self.titleKey(kind: item.kind, title: $0, year: year) }
            .contains(where: titlesWithoutID.contains)
    }

    private static func titleKey(kind: String, title: String, year: Int) -> String? {
        let words = TitleMatch.words(title)
        guard !words.isEmpty else { return nil }
        return "\(kind):\(year):" + words.joined(separator: " ")
    }
}
