import SwiftUI

/// Settings' DigiKey section: the API client ID and secret the Parts pane's
/// DigiKey Stock column signs in with. The ID is a preference, the secret
/// goes to the keychain, and saving signs in once to say whether DigiKey
/// takes them.
struct HorizontalDigiKeySettingsSection: View {
    @ObservedObject var monitor: HorizontalDigiKeyStockMonitor = .shared
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var error: String?

    private static let portalURL = URL(string: "https://developer.digikey.com")!

    private var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSecret: String {
        clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedClientID.isEmpty
            && (monitor.hasClientSecret || !trimmedSecret.isEmpty)
            && (trimmedClientID != monitor.clientID || !trimmedSecret.isEmpty)
    }

    var body: some View {
        Section("DigiKey") {
            TextField("Client ID", text: $clientID)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField(
                "Client Secret",
                text: $clientSecret,
                prompt: Text(monitor.hasClientSecret ? "Saved in the keychain" : "Required")
            )
            .onSubmit { if canSave { save() } }

            Picker("Packaging", selection: $monitor.packaging) {
                ForEach(HorizontalDigiKeyPackaging.allCases) { packaging in
                    Text(packaging.title).tag(packaging)
                }
            }
            Text("DigiKey sells a part on cut tape, full reels and Digi-Reels under separate part numbers, each with its own stock. The column counts the packaging chosen here, or the most stocked one for a part that doesn't come in it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                status
                Spacer()
                Button("Remove", role: .destructive) { remove() }
                    .disabled(monitor.clientID.isEmpty && !monitor.hasClientSecret)
                Button("Save") { save() }
                    .disabled(!canSave)
            }

            Text("The Parts pane's DigiKey Stock column asks DigiKey's Product Information API how many of each part's MPN DigiKey has in stock, once every 12 hours. Create an app with the Product Information V4 API on DigiKey's API portal and enter its client ID and secret here; the secret is kept in the keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("DigiKey API Portal", destination: Self.portalURL)
                .font(.caption)
        }
        .onAppear { clientID = monitor.clientID }
        .onChange(of: monitor.clientID) { _, id in clientID = id }
    }

    @ViewBuilder
    private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if let problem = monitor.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            switch monitor.verification {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Signing in to DigiKey…").foregroundStyle(.secondary)
                }
            case .accepted:
                Label("DigiKey accepted the credentials.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .refused(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case nil:
                Text(monitor.isConfigured ? "Set up." : "Not set up.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        do {
            try monitor.saveCredentials(clientID: trimmedClientID, clientSecret: trimmedSecret.isEmpty ? nil : trimmedSecret)
            clientSecret = ""
            error = nil
            Task { await monitor.verifyCredentials() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try monitor.removeCredentials()
            clientID = ""
            clientSecret = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
