import SwiftUI

/// Settings' Mouser section: a switch for all of it, then the user's own
/// Search API key, which the Parts pane's Mouser Stock column asks Mouser
/// with. Mouser issues a key to whoever enrolls and forbids passing it on,
/// so Horizontal ships none: each user brings theirs, and it goes to the
/// keychain. Saving searches once to say whether Mouser takes it. A part's
/// Open on Mouser needs no key: it opens Mouser's search for the MPN. Off,
/// the app asks Mouser nothing and shows no column and no menu items; the
/// key stays, for turning it back on.
struct HorizontalMouserSettingsSection: View {
    @ObservedObject var monitor: HorizontalMouserStockMonitor = .shared
    @State private var apiKey = ""
    @State private var error: String?

    private static let apiHubURL = URL(string: "https://www.mouser.com/api-hub/")!
    private static let termsURL = URL(string: "https://www.mouser.com/apiterms/")!

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Section("Mouser") {
            Toggle("Look Up Parts on Mouser", isOn: $monitor.isEnabled)
            Text(monitor.isEnabled
                 ? "Shows Mouser's stock in the Parts pane, and Open on Mouser when right-clicking a part on the schematic, on the board, or in the Parts and Pools panes."
                 : "Off: Horizontal asks Mouser nothing, and shows no Mouser Stock column and no Mouser menu items.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField(
                "Search API Key",
                text: $apiKey,
                prompt: Text(monitor.hasAPIKey ? "Saved in the keychain" : "Required")
            )
            .onSubmit { if !trimmedKey.isEmpty { save() } }
            .disabled(!monitor.isEnabled)

            HStack {
                status
                Spacer()
                Button("Remove", role: .destructive) { remove() }
                    .disabled(!monitor.hasAPIKey)
                Button("Save") { save() }
                    .disabled(trimmedKey.isEmpty || !monitor.isEnabled)
            }

            Text("The Parts pane's Mouser Stock column asks Mouser's Search API how many of each part's MPN Mouser has in stock, for the rows on screen. As Mouser's API terms require, the answers are kept in memory for half an hour and never saved. Mouser issues each Search API key to the person who enrolls, so use your own: request one from Mouser's API Hub with your My Mouser account, and enter it here, where it is kept in the keychain. Open on Mouser works without it, through Mouser's search for the part's MPN.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("Mouser API Hub", destination: Self.apiHubURL)
                Link("Search API Terms", destination: Self.termsURL)
            }
            .font(.caption)
        }
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
                    Text("Asking Mouser…").foregroundStyle(.secondary)
                }
            case .accepted:
                Label("Mouser accepted the key.", systemImage: "checkmark.circle.fill")
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
            try monitor.saveAPIKey(trimmedKey)
            apiKey = ""
            error = nil
            Task { await monitor.verifyAPIKey() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try monitor.removeAPIKey()
            apiKey = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
