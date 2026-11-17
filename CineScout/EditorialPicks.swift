import Foundation

struct EditorialPick: Identifiable {
    let item: TMItem
    let year: Int
    let note: String
    let critic: String
    let article: URL
    var id: String { item.key }

    private init(_ id: Int, _ title: String, year: Int, poster: String? = nil,
                 anime: Bool = false, series: Bool = false, note: String, critic: String, article: String) {
        item = TMItem(id: id, media_type: series ? "tv" : "movie", original_language: anime ? "ja" : nil,
                      genre_ids: anime ? [16] : nil, backdrop_path: nil, title: series ? nil : title,
                      name: series ? title : nil, original_title: nil, original_name: nil, overview: nil,
                      poster_path: poster, vote_average: nil, release_date: nil, first_air_date: nil,
                      editorialYear: year)
        self.year = year
        self.note = note
        self.critic = critic
        self.article = URL(string: article)!
    }

    static let selection: [EditorialPick] = [
        .init(389, "Douze hommes en colère", year: 1957, poster: "/ow3wq89wM8qd5X7hWKxiRfsFf9C.jpg",
              note: "Observe comment Sidney Lumet rapproche les visages à mesure que le débat se tend. Le doute devient contagieux parce que chaque certitude doit être défendue devant les autres.",
              critic: "Roger Ebert", article: "https://www.rogerebert.com/reviews/great-movie-12-angry-men-1957"),
        .init(843, "In the Mood for Love", year: 2000,
              note: "Les repas, les escaliers et les couloirs reviennent avec de légères variations. Ces répétitions font sentir le temps passé ensemble et tout ce que les personnages se retiennent de dire.",
              critic: "Criterion", article: "https://www.criterion.com/current/posts/197"),
        .init(129, "Le Voyage de Chihiro", year: 2001, poster: "/39wmItIWsg5sZMyRUHLkWBcuVCM.jpg", anime: true,
              note: "Après l’agitation des bains, le voyage en train donne au film le temps de respirer. Ce changement de rythme laisse enfin de la place à la solitude et à la détermination de Chihiro.",
              critic: "Roger Ebert", article: "https://www.rogerebert.com/reviews/great-movie-spirited-away-2002"),
        .init(655, "Paris, Texas", year: 1984,
              note: "Le film commence à l’échelle d’un désert et s’achève sur des visages séparés par une vitre. Les grands espaces de Wenders laissent peu à peu place à la difficulté de se parler.",
              critic: "Roger Ebert", article: "https://www.rogerebert.com/reviews/great-movie-paris-texas-1984"),
        .init(3112, "La Nuit du chasseur", year: 1955,
              note: "La fuite des enfants ressemble à un livre d’images dont les ombres deviennent menaçantes. C’est un bon point d’entrée dans le cinéma expressionniste et le conte noir.",
              critic: "Roger Ebert", article: "https://www.rogerebert.com/reviews/great-movie-the-night-of-the-hunter-1955"),
        .init(890, "Neon Genesis Evangelion", year: 1995, anime: true, series: true,
              note: "La série part du combat de robots géants, puis donne de plus en plus de place aux silences et aux angoisses de ses pilotes. Le changement de forme devient aussi important que la résolution de l’intrigue.",
              critic: "BFI", article: "https://www.bfi.org.uk/features/neon-genesis-evangelion")
    ]
}
