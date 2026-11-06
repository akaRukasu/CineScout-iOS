import SwiftUI

struct SeerrSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var address = ""
    @State private var key = ""
    @State private var checking = false
    @State private var success = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                TextField("https://seerr.exemple.fr", text: $address)
                    .keyboardType(.URL).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Clé API Seerr", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    Task { await connect() }
                } label: {
                    if checking { ProgressView("Vérification…") }
                    else { Label("Vérifier et enregistrer", systemImage: "link") }
                }
                .disabled(checking || address.isEmpty || key.isEmpty)
                if !message.isEmpty {
                    Label(message, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(success ? Color.green : Color.orange)
                }
            } header: {
                Text("Instance Seerr")
            } footer: {
                Text("Copie la clé dans Seerr → Paramètres → Général. Elle donne un accès administrateur et reste dans le trousseau de cet iPhone.")
            }
            if !model.seerrAddress.isEmpty {
                Button("Déconnecter Seerr", role: .destructive) {
                    model.saveSeerr(address: "", key: "")
                    address = ""; key = ""; message = ""; success = false
                }.disabled(checking)
            }
        }
        .navigationTitle("Seerr")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = model.seerrAddress
            key = model.seerrKey
        }
    }

    private func connect() async {
        checking = true
        message = ""
        defer { checking = false }
        do {
            let client = try SeerrClient(address: address, key: key)
            try await client.check()
            model.saveSeerr(address: client.base.absoluteString, key: client.key)
            address = client.base.absoluteString
            success = true
            message = "Seerr connecté."
        } catch {
            success = false
            message = error.localizedDescription
        }
    }
}
