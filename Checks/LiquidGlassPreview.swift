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
      {"id":693134,"title":"Dune : Deuxième partie","release_date":"2024-02-28","vote_average":8.2,
       "poster_path":"/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg"},
      {"id":27205,"title":"Inception","release_date":"2010-07-21","vote_average":8.4,
       "poster_path":"/9gk7adHYeDvHkCSEqAvQNLV5Uge.jpg"}
    ]
    """.utf8))

    init() {
        let fixture = LibraryModel()
        fixture.discoveries = Self.titles
        fixture.tmdbKey = showsDetail || ProcessInfo.processInfo.arguments.contains("--classics")
            ? "" : "simulator-fixture"
        _model = StateObject(wrappedValue: fixture)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--roulette-motion") {
                    RouletteMotionPreview(titles: Self.titles)
                } else if ProcessInfo.processInfo.arguments.contains("--roulette") {
                    NavigationStack { RouletteView(openSettings: {}) }
                } else if ProcessInfo.processInfo.arguments.contains("--catalog-search") {
                    CatalogSearchView(openSettings: {})
                } else if ProcessInfo.processInfo.arguments.contains("--classics") {
                    NavigationStack { RecommendationView(section: .classics, openSettings: {}) }
                } else if showsDetail {
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

private struct RouletteMotionPreview: View {
    let titles: [TMItem]
    @State private var phase = RoulettePhase.idle
    @State private var winner: TMItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RouletteStage(candidates: titles, winner: winner, phase: phase,
                                  status: phase == .revealed ? "Tes découvertes" : "Les affiches défilent…")
                    if phase == .revealed {
                        Text("Tes prochaines découvertes").font(.title2.bold())
                        ForEach(titles, id: \.key) { RouletteResultCard(item: $0) }
                    }
                }
                .padding(16)
            }
            .background { CinemaBackground() }
            .navigationTitle("Roulette")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                do {
                    let trigger = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("roulette-start")
                    while !FileManager.default.fileExists(atPath: trigger.path) {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try Task.checkCancellation()
                    phase = .spinning(.now)
                    try await Task.sleep(for: .seconds(3))
                    winner = titles.first
                    phase = .settling(.now)
                    try await Task.sleep(for: .seconds(3.3))
                    phase = .revealed
                } catch {}
            }
        }
    }
}
