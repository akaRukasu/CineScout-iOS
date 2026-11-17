import Foundation

enum RouletteFormat: String, CaseIterable, Identifiable, Hashable {
    case film, series, anime, animatedFilm, animatedSeries

    var id: Self { self }

    var label: String {
        switch self {
        case .film: "Films"
        case .series: "Séries"
        case .anime: "Animes japonais"
        case .animatedFilm: "Films d’animation"
        case .animatedSeries: "Séries animées"
        }
    }

    var kinds: [StreamingMedia] {
        switch self {
        case .film, .animatedFilm: [.movie]
        case .series, .animatedSeries: [.tv]
        case .anime: [.movie, .tv]
        }
    }

    func includes(_ item: TMItem) -> Bool {
        let animated = item.genre_ids?.contains(16) == true
        switch self {
        case .film: return item.kind == "movie" && !animated
        case .series: return item.kind == "tv" && !animated
        case .anime: return item.isAnime
        case .animatedFilm: return item.kind == "movie" && animated
        case .animatedSeries: return item.kind == "tv" && animated
        }
    }
}

enum RouletteGenre: String, CaseIterable, Identifiable, Hashable {
    case action, adventure, comedy, crime, documentary, drama, family, fantasy, horror, mystery, romance, scienceFiction, thriller, western

    var id: Self { self }

    var label: String {
        switch self {
        case .action: "Action"
        case .adventure: "Aventure"
        case .comedy: "Comédie"
        case .crime: "Policier"
        case .documentary: "Documentaire"
        case .drama: "Drame"
        case .family: "Famille"
        case .fantasy: "Fantastique"
        case .horror: "Horreur"
        case .mystery: "Mystère"
        case .romance: "Romance"
        case .scienceFiction: "Science-fiction"
        case .thriller: "Thriller"
        case .western: "Western"
        }
    }

    func code(for kind: StreamingMedia) -> Int? {
        switch self {
        case .action: kind == .movie ? 28 : 10759
        case .adventure: kind == .movie ? 12 : 10759
        case .comedy: 35
        case .crime: 80
        case .documentary: 99
        case .drama: 18
        case .family: 10751
        case .fantasy: kind == .movie ? 14 : 10765
        case .horror: kind == .movie ? 27 : nil
        case .mystery: 9648
        case .romance: kind == .movie ? 10749 : nil
        case .scienceFiction: kind == .movie ? 878 : 10765
        case .thriller: kind == .movie ? 53 : nil
        case .western: 37
        }
    }
}

enum Roulette {
    static let minimumScore = 6.8
    static let movieVotes = 50
    static let seriesVotes = 20

    struct Query: Hashable {
        let kind: StreamingMedia
        let format: RouletteFormat
        let genre: Int?
        let years: ClosedRange<Int>

        func endpoint(page: Int, now: Date = .now) -> URLComponents {
            let date = kind == .movie ? "primary_release_date" : "first_air_date"
            let latest = now.formatted(Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash))
            var items: [URLQueryItem] = [
                .init(name: "include_adult", value: "false"),
                .init(name: "sort_by", value: "vote_average.desc"),
                .init(name: "vote_average.gte", value: String(Roulette.minimumScore)),
                .init(name: "vote_count.gte", value: String(kind == .movie ? Roulette.movieVotes : Roulette.seriesVotes)),
                .init(name: "\(date).gte", value: "\(years.lowerBound)-01-01"),
                .init(name: "\(date).lte", value: min("\(years.upperBound)-12-31", latest)),
                .init(name: "page", value: String(page))
            ]
            if format == .film || format == .series {
                items.append(.init(name: "without_genres", value: "16"))
                if let genre { items.append(.init(name: "with_genres", value: String(genre))) }
            } else {
                let required = [16] + [genre].compactMap { $0 }
                items.append(.init(name: "with_genres", value: required.map(String.init).joined(separator: ",")))
                if format == .anime { items.append(.init(name: "with_original_language", value: "ja")) }
            }
            return TMDbCatalog.endpoint("discover/\(kind.rawValue)", items)
        }

        func matches(_ item: TMItem) -> Bool {
            guard format.includes(item), item.kind == kind.rawValue, !item.titles.isEmpty,
                  (item.vote_average ?? 0) >= Roulette.minimumScore,
                  (item.vote_count ?? 0) >= (kind == .movie ? Roulette.movieVotes : Roulette.seriesVotes),
                  let year = item.year, years.contains(year) else { return false }
            return genre.map { item.genre_ids?.contains($0) == true } ?? true
        }
    }

    static func queries(formats: Set<RouletteFormat>, genres: Set<RouletteGenre>) -> [Query] {
        let eras = [1900...1999, 2000...2014, 2015...2099]
        var queries = Set<Query>()
        for format in formats {
            for kind in format.kinds {
                let eligible = Set(genres.compactMap { $0.code(for: kind) }).shuffled()
                guard genres.isEmpty || !eligible.isEmpty else { continue }
                for (index, years) in eras.enumerated() {
                    let genre = eligible.isEmpty ? nil : eligible[index % eligible.count]
                    queries.insert(Query(kind: kind, format: format, genre: genre, years: years))
                }
            }
        }
        return queries.shuffled()
    }

    static func canDraw(formats: Set<RouletteFormat>, genres: Set<RouletteGenre>) -> Bool {
        formats.contains { format in
            genres.isEmpty || format.kinds.contains { kind in genres.contains { $0.code(for: kind) != nil } }
        }
    }

    static func rank(_ candidates: [TMItem], excluding excluded: Set<String>,
                     random: () -> Double = { Double.random(in: 0..<1) }) -> [TMItem] {
        var seen = excluded
        let scores = candidates.filter { seen.insert($0.key).inserted }.map { item in
            let rating = item.vote_average ?? minimumScore
            let votes = Double(item.vote_count ?? 0)
            let adjusted = (rating * votes + minimumScore * 80) / (votes + 80)
            let weight = pow(max(adjusted - 6, 0.2), 4)
            return (item, -log(max(random(), 0.000_001)) / weight)
        }
        return scores.sorted { $0.1 < $1.1 }.map(\.0)
    }

    static func next(from candidates: [TMItem], after chosen: [TMItem], formats: Set<RouletteFormat>) -> TMItem? {
        let usedYears = Set(chosen.compactMap(\.year))
        let usedDecades = Set(usedYears.map { $0 / 10 })
        let usedFormats = Set(chosen.compactMap { format(for: $0, in: formats) })
        return candidates.enumerated().min { lhs, rhs in
            let left = diversity(lhs.element, usedYears: usedYears, usedDecades: usedDecades,
                                 usedFormats: usedFormats, formats: formats)
            let right = diversity(rhs.element, usedYears: usedYears, usedDecades: usedDecades,
                                  usedFormats: usedFormats, formats: formats)
            return left == right ? lhs.offset < rhs.offset : left > right
        }?.element
    }

    private static func diversity(_ item: TMItem, usedYears: Set<Int>, usedDecades: Set<Int>,
                                  usedFormats: Set<RouletteFormat>, formats: Set<RouletteFormat>) -> Int {
        let year = item.year ?? 0
        let format = format(for: item, in: formats)
        var score = usedYears.contains(year) ? 0 : 4
        if !usedDecades.contains(year / 10) { score += 2 }
        if let format, !usedFormats.contains(format) { score += 1 }
        return score
    }

    private static func format(for item: TMItem, in formats: Set<RouletteFormat>) -> RouletteFormat? {
        RouletteFormat.allCases.first { formats.contains($0) && $0.includes(item) }
    }
}
