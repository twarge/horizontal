import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Updates of the registered pools that are git checkouts, for Settings'
/// Pools section and the Pools pane: whether each has news on its remote,
/// and updating it (`HorizontalGitPull`) in the background, one at a time
/// per pool. After an update the pool's items are read again.
@MainActor
final class HorizontalPoolUpdater: ObservableObject {
    static let shared = HorizontalPoolUpdater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case ahead
        case updating(HorizontalGitClone.Progress)
        case updated(commits: Int, files: Int)
        case failed(String)
    }

    @Published private(set) var statuses = [String: Status]()
    /// Bumped whenever an update changed a pool's files, for the views that
    /// list its items.
    @Published private(set) var updatesCompleted = 0
    private var checkouts = [String: Result<HorizontalGitCheckout?, Error>]()
    private var tasks = [String: Task<Void, Never>]()

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The pool's checkout, or nil when it isn't one or can't be updated.
    func checkout(at url: URL) -> HorizontalGitCheckout? {
        try? read(url).get()
    }

    /// Why a pool that is a checkout can't be updated, or nil.
    func problem(at url: URL) -> String? {
        if case .failure(let error) = read(url) { return error.localizedDescription }
        return nil
    }

    private func read(_ url: URL) -> Result<HorizontalGitCheckout?, Error> {
        if let known = checkouts[key(url)] { return known }
        let result = Result { try HorizontalGitCheckout.read(url) }
        checkouts[key(url)] = result
        return result
    }

    func status(_ url: URL) -> Status {
        statuses[key(url)] ?? .idle
    }

    func isBusy(_ url: URL) -> Bool {
        tasks[key(url)] != nil
    }

    /// Reads the checkouts again, as after a change made outside the app.
    func reload() {
        checkouts = [:]
        objectWillChange.send()
    }

    /// Asks each pool's remote where its branch is; nothing is fetched.
    func check(_ urls: [URL]) {
        for url in urls where !isBusy(url) && checkout(at: url) != nil {
            let key = key(url)
            statuses[key] = .checking
            tasks[key] = Task {
                do {
                    let availability = try await Task.detached(priority: .utility) { try await HorizontalGitPull.check(url) }.value
                    switch availability {
                    case .upToDate: statuses[key] = .upToDate
                    case .available: statuses[key] = .available
                    case .ahead: statuses[key] = .ahead
                    }
                } catch {
                    statuses[key] = .failed(error.localizedDescription)
                }
                tasks[key] = nil
            }
        }
    }

    func update(_ url: URL) {
        guard !isBusy(url), checkout(at: url) != nil else { return }
        let key = key(url)
        statuses[key] = .updating(HorizontalGitClone.Progress(phase: .connecting))
        tasks[key] = Task {
            // Off the main actor; Cancel reaches it through the handler, as a
            // detached task isn't this one's child.
            let pull = Task.detached(priority: .userInitiated) { [self] in
                try await HorizontalGitPull.update(url) { progress in
                    Task { @MainActor in self.report(progress, for: key) }
                }
            }
            do {
                let outcome = try await withTaskCancellationHandler {
                    try await pull.value
                } onCancel: {
                    pull.cancel()
                }
                switch outcome {
                case .upToDate:
                    statuses[key] = .upToDate
                case .ahead:
                    statuses[key] = .ahead
                case .updated(_, _, let commits, let files):
                    statuses[key] = .updated(commits: commits, files: files)
                    HorizontalPoolLibrary.invalidateCache(for: url)
                    HorizontalPoolPadstacks.invalidateCaches()
                    updatesCompleted += 1
                }
            } catch {
                // A download cancelled midway throws URLError's cancelled.
                statuses[key] = Task.isCancelled || error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
            checkouts[key] = nil
            tasks[key] = nil
        }
    }

    func cancel(_ url: URL) {
        tasks[key(url)]?.cancel()
    }

    private func report(_ progress: HorizontalGitClone.Progress, for key: String) {
        if case .updating = statuses[key] {
            statuses[key] = .updating(progress)
        }
    }

    static func describe(_ progress: HorizontalGitClone.Progress, host: String?) -> String {
        switch progress.phase {
        case .connecting:
            "Asking \(host ?? "the remote") what's new…"
        case .receiving:
            "Downloading: \(ByteCountFormatter.string(fromByteCount: Int64(progress.completed), countStyle: .file))"
        case .indexing:
            "Reading objects: \(progress.completed.formatted()) of \((progress.total ?? 0).formatted())"
        case .checkingOut:
            "Updating files: \(progress.completed.formatted()) of \((progress.total ?? 0).formatted())"
        }
    }
}

/// Settings' Pools section, and the Pools pane's Manage Pools sheet: the
/// registered pools, adding and removing them, and updating the ones that
/// are git checkouts from the remote they track.
struct HorizontalPoolsSettingsSection: View {
    @ObservedObject private var registry = HorizontalPoolRegistry.shared
    @ObservedObject private var updater = HorizontalPoolUpdater.shared
    @State private var isImportingPool = false
    @State private var isOfferingDefaultPool = false
    @State private var addFailure: String?

    private var gitPools: [URL] {
        registry.pools.map(\.url).filter { updater.checkout(at: $0) != nil }
    }

    var body: some View {
        Section("Pools") {
            if registry.pools.isEmpty {
                Text("No pools are registered. Add a folder that holds a pool.json, or get Horizon's default pool.")
                    .foregroundStyle(.secondary)
            }
            ForEach(registry.pools) { pool in
                row(pool)
            }
            HStack {
                Button("Add Pool…", action: addPool)
                if !HorizontalDefaultPool.isRegistered {
                    Button("Get Horizon Default Pool…", action: offerDefaultPool)
                }
                Spacer()
                Button("Check for Updates") {
                    updater.reload()
                    updater.check(gitPools)
                }
                .disabled(gitPools.isEmpty)
            }
            Text("A pool that is a git checkout updates from the branch it tracks: Horizontal fetches it over HTTPS and moves the pool on to it, and leaves a pool alone when the update would overwrite changes or commits of its own. A pool cloned over SSH is fetched over HTTPS from the same host, which works while it's public; private pools need SSH, which isn't supported yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $isImportingPool, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                register(url)
            }
        }
        .sheet(isPresented: $isOfferingDefaultPool) {
            HorizontalDefaultPoolSheet()
        }
        .alert("Not a Pool", isPresented: Binding { addFailure != nil } set: { if !$0 { addFailure = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(addFailure ?? "")” has no pool.json, so it isn't a Horizon pool.")
        }
    }

    @ViewBuilder
    private func row(_ pool: HorizontalRegisteredPool) -> some View {
        let checkout = updater.checkout(at: pool.url)
        let status = updater.status(pool.url)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pool.name)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                statusLabel(status)
                if checkout != nil {
                    if case .updating = status {
                        Button("Cancel") { updater.cancel(pool.url) }
                    } else {
                        Button("Update") { updater.update(pool.url) }
                            .disabled(updater.isBusy(pool.url))
                            .help("Fetch \(checkout?.remoteDescription ?? "the remote") over HTTPS and bring this pool up to date")
                    }
                }
                Menu {
                    #if os(macOS)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([pool.url])
                    }
                    #endif
                    Button("Remove from Pools", role: .destructive) {
                        registry.removePool(pool)
                        HorizontalPoolLibrary.invalidateCache()
                    }
                    .disabled(updater.isBusy(pool.url))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for this pool; removing it leaves its folder as it is")
            }
            Text((pool.url.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !FileManager.default.fileExists(atPath: pool.url.appendingPathComponent("pool.json").path) {
                Text("The folder or its pool.json is missing.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let checkout {
                Text("git · \(checkout.branch) at \(checkout.head.prefix(7)) · \(checkout.remoteDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let problem = updater.problem(at: pool.url) {
                Text("git · can't update: \(problem)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch status {
            case .updating(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(HorizontalPoolUpdater.describe(progress, host: checkout?.fetchURL?.host))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusLabel(_ status: HorizontalPoolUpdater.Status) -> some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Text("Up to date")
                .foregroundStyle(.secondary)
        case .available:
            Text("Update available")
                .foregroundStyle(Color.accentColor)
        case .ahead:
            Text("Has commits of its own")
                .foregroundStyle(.secondary)
        case .updated(let commits, let files):
            Text("Updated: \(commits) commit\(commits == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        case .idle, .updating, .failed:
            EmptyView()
        }
    }

    private func addPool() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a pool folder: one that holds a pool.json."
        panel.prompt = "Add Pool"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            register(url)
        }
        #else
        isImportingPool = true
        #endif
    }

    /// As the Pools pane's Add Pool… registers one: the picker's grant kept
    /// open so the registry can mint its bookmark.
    private func register(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        if registry.addPool(at: url) {
            HorizontalPoolLibrary.invalidateCache()
        } else {
            addFailure = url.lastPathComponent
        }
    }

    private func offerDefaultPool() {
        #if os(macOS)
        HorizontalDefaultPoolWindow.shared.show()
        #else
        isOfferingDefaultPool = true
        #endif
    }
}

/// The Pools section on its own, for the Pools pane's Manage Pools….
struct HorizontalManagePoolsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                HorizontalPoolsSettingsSection()
            }
            .formStyle(.grouped)
            .navigationTitle("Pools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 360)
        #endif
    }
}
