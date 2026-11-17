import SwiftUI

struct JellyfinMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image("JellyfinMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .padding(size / 4)
            .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: size / 3))
            .accessibilityHidden(true)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    let openSettings: () -> Void
    @State private var search = ""

    private var filtered: [Media] {
        model.library.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        JellyfinMark(size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Jellyfin").font(.title2.bold())
                            if model.connected {
                                Text("\(model.library.count.formatted()) titres synchronisés")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Bibliothèque personnelle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)

                    if model.syncing { ProgressView("Synchronisation…") }
                    if !model.message.isEmpty {
                        Label(model.message, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !model.connected && !model.syncing {
                        Button("Configurer Jellyfin", systemImage: "link", action: openSettings)
                            .glassButtonStyle(prominent: true)
                    }
                }

                if model.connected {
                    Section("Titres") {
                        if filtered.isEmpty && !model.syncing {
                            ContentUnavailableView(search.isEmpty ? "Bibliothèque vide" : "Aucun résultat",
                                                   systemImage: search.isEmpty ? "film" : "magnifyingglass")
                        }
                        ForEach(filtered) { item in
                            HStack(spacing: 14) {
                                Image(systemName: item.mediaType == "Series" ? "tv" : "film")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                    Text([item.mediaType == "Series" ? "Série" : "Film",
                                          item.ProductionYear.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher dans Jellyfin")
            .navigationTitle("Bibliothèque")
            .refreshable { await model.refresh() }
            .toolbar {
                if model.connected {
                    Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.syncing)
                }
            }
        }
    }
}
struct WishlistView: View {
    @EnvironmentObject var model: LibraryModel
    let openDiscover: () -> Void
    var body: some View {
        NavigationStack {
            List {
                if model.wishlist.isEmpty {
                    ContentUnavailableView {
                        Label("Ta liste est vide", systemImage: "bookmark")
                    } description: {
                        Text("Touche le marque-page d’un film ou d’une série pour le retrouver ici.")
                    } actions: {
                        Button("Parcourir les titres", action: openDiscover).glassButtonStyle(prominent: true)
                    }.listRowBackground(Color.clear)
                }
                ForEach(model.wishlist, id: \.key) { item in
                    NavigationLink {
                        DetailView(item: item)
                    } label: {
                        HStack(spacing: 14) {
                            Poster(path: item.poster_path, cornerRadius: 7).frame(width: 48)
                            VStack(alignment: .leading) {
                                Text(item.display).font(.headline)
                                Text([item.kind == "tv" ? "Série" : "Film", item.releaseDateText]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let removed = offsets.map { model.wishlist[$0] }
                    for item in removed { model.toggle(item) }
                }
            }
            .navigationTitle("Envies")
            .toolbar {
                if !model.wishlist.isEmpty { EditButton() }
            }
        }
    }
}
