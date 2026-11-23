import SwiftUI

/// Settings' Arrow section: a switch for all of it, then the user's own
/// login and API key, which the Parts pane's Arrow Stock column asks Arrow
/// with. Arrow issues the two together on request and forbids sharing them
/// outside the company they were issued to, so Horizontal ships none: each
/// user brings theirs, the key to the keychain. Saving searches once to say
/// whether Arrow takes them. A part's Open on Arrow needs neither: it opens
/// Arrow's search for the MPN. Off, as it is until turned on, the app asks
/// Arrow nothing and shows no column and no menu items; the login and key
/// stay, for turning it back on.
struct HorizontalArrowSettingsSection: View {
    @ObservedObject var monitor: HorizontalArrowStockMonitor = .shared
    @State private var login = ""
    @State private var apiKey = ""
    @State private var error: String?

    private static let apiURL = URL(string: "https://developers.arrow.com/api/")!
    private static let termsURL = URL(string: "https://developers.arrow.com/api/index.php/site/page?view=terms")!

    private var trimmedLogin: String {
        login.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A login, and a key typed or already saved, one of them new.
    private var canSave: Bool {
        monitor.isEnabled && !trimmedLogin.isEmpty && (!trimmedKey.isEmpty || monitor.hasAPIKey)
            && (!trimmedKey.isEmpty || trimmedLogin != monitor.login)
    }

    var body: some View {
        Section("Arrow") {
            Toggle("Look Up Parts on Arrow", isOn: $monitor.isEnabled)

            TextField("Login", text: $login, prompt: Text("Required"))
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { if canSave { save() } }
                .disabled(!monitor.isEnabled)

            SecureField(
                "API Key",
                text: $apiKey,
                prompt: Text(monitor.hasAPIKey ? "Saved in the keychain" : "Required")
            )
            .onSubmit { if canSave { save() } }
            .disabled(!monitor.isEnabled)

            HStack {
                status
                Spacer()
                Button("Remove", role: .destructive) { remove() }
                    .disabled(!monitor.hasAPIKey && monitor.login.isEmpty)
                Button("Save") { save() }
                    .disabled(!canSave)
            }

            HStack(spacing: 16) {
                Link("Arrow API", destination: Self.apiURL)
                Link("API Terms", destination: Self.termsURL)
            }
            .font(.caption)
        }
        .onAppear { login = monitor.login }
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
                    Text("Asking Arrow…").foregroundStyle(.secondary)
                }
            case .accepted:
                Label("Arrow accepted the login and key.", systemImage: "checkmark.circle.fill")
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
            try monitor.saveCredentials(login: trimmedLogin, apiKey: trimmedKey)
            apiKey = ""
            error = nil
            Task { await monitor.verifyCredentials() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try monitor.removeCredentials()
            login = ""
            apiKey = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
