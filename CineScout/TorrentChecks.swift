import SwiftUI

@MainActor
final class TorrentChecks: ObservableObject {
    enum State: Equatable {
        case checking
        case checked(ProwlarrClient.Availability)
        case failed(String)
    }

    private struct Entry {
        let state: State
        let expires: Date
    }

    @Published private(set) var address = UserDefaults.standard.string(forKey: "prowlarrAddress") ?? ""
    @Published private(set) var revision = 0
    @Published private var entries: [Int: Entry] = [:]
    private(set) var key = Secrets.get("prowlarrKey")
    private var queue: [TMItem] = []
    private var jobs: [Int: Task<Void, Never>] = [:]

    func state(for movie: TMItem) -> State? { entries[movie.id]?.state }

    func save(address: String, key: String) {
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        queue.removeAll()
        entries.removeAll()
        Secrets.set(key, for: "prowlarrKey")
        UserDefaults.standard.set(address, forKey: "prowlarrAddress")
        self.key = key
        self.address = address
        revision += 1
    }

    func check(_ movie: TMItem, retry: Bool = false) {
        guard movie.kind == "movie", !address.isEmpty else { return }
        if let entry = entries[movie.id],
           entry.state == .checking || (!retry && entry.expires > .now) { return }

        entries[movie.id] = Entry(state: .checking, expires: .distantFuture)
        queue.append(movie)
        startQueuedChecks()
    }

    private func startQueuedChecks() {
        while jobs.count < 2 && !queue.isEmpty {
            let movie = queue.removeFirst()
            jobs[movie.id] = Task {
                let state: State
                let lifetime: TimeInterval
                do {
                    let client = try ProwlarrClient(address: address, key: key)
                    state = .checked(try await client.availability(for: movie))
                    lifetime = 30 * 60
                } catch {
                    state = .failed(error.localizedDescription)
                    lifetime = 60
                }
                guard !Task.isCancelled else { return }
                entries[movie.id] = Entry(state: state, expires: .now.addingTimeInterval(lifetime))
                jobs.removeValue(forKey: movie.id)
                startQueuedChecks()
            }
        }
    }
}

struct TorrentIndicator: View {
    @EnvironmentObject private var checks: TorrentChecks
    let item: TMItem
    var detailed = false
    @State private var showsSettings = false

    var body: some View {
        if item.kind == "movie" {
            indicator
                .task(id: checks.revision) { checks.check(item) }
                .sheet(isPresented: $showsSettings) {
                    NavigationStack {
                        ProwlarrSettingsView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Fermer") { showsSettings = false }
                                }
                            }
                    }
                }
        }
    }

    @ViewBuilder private var indicator: some View {
        if checks.address.isEmpty {
            if detailed {
                Button("Configurer Prowlarr", systemImage: "magnifyingglass") { showsSettings = true }
                    .buttonStyle(.bordered)
            }
        } else {
            switch checks.state(for: item) {
            case nil, .checking:
                ProgressView("Recherche de torrents…")
                    .controlSize(.small)
            case .checked(let result):
                if result.count == 0 {
                    Label("Aucun torrent trouvé", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(result.count == 1 ? "1 torrent trouvé" : "\(result.count) torrents trouvés",
                              systemImage: "checkmark.circle")
                        if let seeders = result.bestSeeders {
                            let text = seeders == 1 ? "1 seeder" : "\(seeders) seeders"
                            Text(detailed && result.count > 1 ? "Jusqu’à \(text)" : text)
                                .foregroundStyle(.secondary)
                        } else if detailed {
                            Text("Nombre de seeders inconnu").foregroundStyle(.secondary)
                        }
                    }
                }
            case .failed(let error):
                if detailed {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button("Relancer la recherche", systemImage: "arrow.clockwise") {
                        checks.check(item, retry: true)
                    }.buttonStyle(.bordered)
                } else {
                    Label("Vérification impossible", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProwlarrSettingsView: View {
    @EnvironmentObject private var checks: TorrentChecks
    @State private var address = ""
    @State private var key = ""
    @State private var checking = false
    @State private var result: String?
    @State private var connected = false

    var body: some View {
        Form {
            Section {
                TextField("Adresse HTTPS", text: $address, prompt: Text("https://prowlarr.exemple.fr"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: address) { _, value in
                        if value != checks.address && key == checks.key { key = "" }
                        result = nil
                    }
                SecureField("Clé API", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await connect() }
                } label: {
                    if checking { ProgressView("Vérification…") }
                    else { Label("Vérifier et enregistrer", systemImage: "link") }
                }
                .disabled(checking || address.isEmpty || key.isEmpty)
                if let result {
                    Label(result, systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(connected ? Color.green : Color.orange)
                }
            } header: {
                Text("Instance Prowlarr")
            } footer: {
                Text("La clé se trouve dans Prowlarr → Paramètres → Général. Elle est conservée dans le trousseau de l’iPhone.")
            }
            .disabled(checking)

            if !checks.address.isEmpty {
                Button("Déconnecter Prowlarr", role: .destructive) {
                    checks.save(address: "", key: "")
                    address = ""
                    key = ""
                    result = nil
                }.disabled(checking)
            }
        }
        .navigationTitle("Prowlarr")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = checks.address
            key = checks.key
        }
    }

    private func connect() async {
        checking = true
        defer { checking = false }
        do {
            let client = try ProwlarrClient(address: address, key: key)
            try await client.check()
            checks.save(address: client.base.absoluteString, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
            address = checks.address
            connected = true
            result = "Prowlarr connecté."
        } catch {
            connected = false
            result = error.localizedDescription
        }
    }
}
