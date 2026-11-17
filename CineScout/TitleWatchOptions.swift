import SwiftUI

struct TitleWatchOptions: View {
    @EnvironmentObject private var model: LibraryModel
    let item: TMItem
    @State private var offers: WatchAvailability.Offers?
    @State private var isLoading = true
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        if !model.tmdbKey.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Où regarder en France").font(.title2.bold()).accessibilityAddTraits(.isHeader)

                if isLoading {
                    ProgressView("Vérification des plateformes…")
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Réessayer") { retry += 1 }.glassButtonStyle()
                } else if let offers, !offers.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(offers.groups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.label).font(.subheadline.weight(.semibold))
                                Text(group.providers.map(\.provider_name).joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))

                    if let link = offers.link, link.scheme == "https",
                       ["www.themoviedb.org", "themoviedb.org"].contains(link.host ?? "") {
                        Link(destination: link) {
                            Label("Consulter les offres", systemImage: "arrow.up.right")
                        }.glassButtonStyle()
                    }
                } else {
                    Text("Aucune offre répertoriée pour ce titre en France.")
                        .foregroundStyle(.secondary)
                }

                if offers != nil || (!isLoading && error == nil) {
                    Text("Disponibilités JustWatch via TMDb.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .task(id: retry) { await loadOffers() }
        }
    }

    private func loadOffers() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response: WatchAvailability = try await model.catalog(TMDbCatalog.offers(for: item))
            try Task.checkCancellation()
            offers = response.results[TMDbCatalog.market]
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
