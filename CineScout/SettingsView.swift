import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var torrents: TorrentChecks
    let openDiscover: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Catalogue et bibliothèque") {
                    NavigationLink { JellyfinSettingsView() } label: {
                        HStack(spacing: 14) {
                            JellyfinMark()
                            serviceText("Jellyfin", active: model.connected)
                        }
                    }
                    NavigationLink { TMDbSettingsView(openDiscover: openDiscover) } label: {
                        serviceRow("TMDb", symbol: "film", color: .teal, active: !model.tmdbKey.isEmpty)
                    }
                }
                Section("Disponibilité et demandes") {
                    NavigationLink { ProwlarrSettingsView() } label: {
                        serviceRow("Prowlarr", symbol: "magnifyingglass", color: .orange, active: !torrents.address.isEmpty)
                    }
                    NavigationLink { SeerrSettingsView() } label: {
                        serviceRow("Seerr", symbol: "paperplane", color: .indigo, active: !model.seerrAddress.isEmpty)
                    }
                }
                Section {
                    Text("CinéScout utilise les données de TMDb. L’application est indépendante de TMDb.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Réglages")
        }
    }

    private func serviceRow(_ title: String, symbol: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.13), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            serviceText(title, active: active)
        }
    }

    private func serviceText(_ title: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(active ? "Configuré" : "À configurer")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct JellyfinSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if model.hasJellyfinSession {
                    Label(model.connected ? "Jellyfin connecté" : "Session Jellyfin enregistrée", systemImage: "person.crop.circle")
                    LabeledContent("Compte", value: model.username)
                    LabeledContent("Titres synchronisés", value: model.library.count.formatted())
                    Button("Se déconnecter", role: .destructive) { model.logout() }
                        .disabled(model.busy)
                } else {
                    TextField("Adresse du serveur", text: $model.server)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Nom d’utilisateur", text: $model.username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mot de passe", text: $password).textContentType(.password)
                    Button {
                        Task {
                            await model.login(password: password)
                            if model.hasJellyfinSession { password = "" }
                        }
                    } label: {
                        if model.busy || model.syncing {
                            ProgressView("Connexion à Jellyfin…")
                        } else {
                            Label("Se connecter à Jellyfin", systemImage: "arrow.right.circle")
                        }
                    }
                    .disabled(model.busy || model.syncing || model.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !model.message.isEmpty {
                    Label(model.message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            } header: {
                Text("Compte Jellyfin")
            } footer: {
                Text("Utilise le compte avec lequel tu te connectes à Jellyfin.")
            }
        }
        .navigationTitle("Jellyfin")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TMDbSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let openDiscover: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                SecureField("Clé API ou jeton de lecture", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                Link("Obtenir une clé TMDb", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                Button {
                    focused = false
                    model.tmdbKey = draft
                    model.saveSettings()
                    dismiss()
                    openDiscover()
                    Task { await model.discover() }
                } label: {
                    Label("Enregistrer et découvrir", systemImage: "sparkles")
                }
                .disabled(model.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Catalogue TMDb")
            } footer: {
                Text("La clé permet d’explorer les films et les séries.")
            }
        }
        .navigationTitle("TMDb")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = model.tmdbKey }
    }
}
