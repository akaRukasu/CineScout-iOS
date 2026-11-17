import Foundation
import SwiftUI

@main
@MainActor
struct LiquidGlassPreview: App {
    @StateObject private var model: LibraryModel
    private let showsDetail = ProcessInfo.processInfo.arguments.contains("--detail")
    private static let titles = try! JSONDecoder().decode([TMItem].self, from: Data("""
    [
      {"id":157336,"title":"Interstellar","release_date":"2014-11-05","vote_average":8.5,
       "backdrop_path":"/xJHokMbljvjADYdit5fK5VQsXEG.jpg","poster_path":"/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg",
       "overview":"Une équipe d’explorateurs franchit un trou de ver pour chercher un nouveau foyer à l’humanité."},
      {"id":693134,"title":"Dune : Deuxième partie","release_date":"2024-02-28",
       "poster_path":"/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg"},
      {"id":27205,"title":"Inception","release_date":"2010-07-21",
       "poster_path":"/9gk7adHYeDvHkCSEqAvQNLV5Uge.jpg"}
    ]
    """.utf8))

    init() {
        let fixture = LibraryModel()
        fixture.discoveries = Self.titles
        fixture.tmdbKey = showsDetail ? "" : "simulator-fixture"
        _model = StateObject(wrappedValue: fixture)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsDetail {
                    NavigationStack { DetailView(item: Self.titles[0]) }
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .environmentObject(model.torrents)
        }
    }
}
