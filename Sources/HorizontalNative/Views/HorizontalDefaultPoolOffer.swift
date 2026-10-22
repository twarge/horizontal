import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Horizon's default pool, which the app offers to clone the first time it
/// starts, as Horizon's own welcome does: thousands of parts, symbols and
/// footprints from github.com/horizon-eda/horizon-pool, cloned with the
/// built-in git (`HorizontalGitClone`) into a folder the user picks and added
/// to the registered pools.
enum HorizontalDefaultPool {
    static let remote = URL(string: "https://github.com/horizon-eda/horizon-pool.git")!
    static let uuid = "6d752bc3-29b3-45df-8cf2-1e3aacefbcc6"
    static let folderName = "horizon-pool"
    static let offeredKey = "Horizontal.defaultPoolOffer.offered"

    /// A pool with the default pool's uuid is registered already.
    static var isRegistered: Bool {
        HorizontalPoolRegistryStore.poolURLs().contains(where: isDefaultPool)
    }

    /// `folder` is the default pool: its pool.json carries the pool's uuid.
    static func isDefaultPool(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("pool.json").path)
            && HorizontalPoolRegistryStore.poolInfo(at: folder).uuid.caseInsensitiveCompare(uuid) == .orderedSame
    }

    /// Offered once, the first time the app starts, and not to someone who
    /// has the pool registered already. Pools ▸ Get Horizon Default Pool…
    /// offers it again whenever they like.
    static var shouldOfferAtLaunch: Bool {
        !UserDefaults.standard.bool(forKey: offeredKey) && !isRegistered
    }

    static func markOffered() {
        UserDefaults.standard.set(true, forKey: offeredKey)
    }

    /// Where a clone into `folder` goes: the folder itself when it is empty,
    /// otherwise a new horizon-pool folder in it. A folder that is the
    /// default pool already, or has it in a horizon-pool folder, is that
    /// clone, which is registered as it is.
    static func destination(in folder: URL) -> URL {
        if isDefaultPool(folder) { return folder }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0 != ".DS_Store" } ?? []
        return contents.isEmpty ? folder : folder.appendingPathComponent(folderName, isDirectory: true)
    }
}

/// A clone of the default pool in flight, for the offer's progress view.
@MainActor
final class HorizontalDefaultPoolClone: ObservableObject {
    enum State: Equatable {
        case offer
        case cloning(HorizontalGitClone.Progress)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .offer
    private var task: Task<Void, Never>?

    /// Clones into `folder` (or a horizon-pool folder in it) and registers the
    /// result. A clone there already is registered as it is. `scoped` is a
    /// folder from the iPad's picker, whose access has to be asked for while
    /// it is used.
    func start(in folder: URL, scoped: Bool = false) {
        guard task == nil else { return }
        state = .cloning(HorizontalGitClone.Progress(phase: .connecting))
        task = Task {
            // The picker's grant is kept open once the pool is registered,
            // as Add Pool… keeps it, so the new pool can be browsed now; the
            // registry's bookmark carries later launches. A clone that fails
            // gives it back.
            let accessing = scoped && folder.startAccessingSecurityScopedResource()
            func giveBack() { if accessing { folder.stopAccessingSecurityScopedResource() } }
            // Listed only once the folder may be read.
            let destination = HorizontalDefaultPool.destination(in: folder)
            do {
                if !HorizontalDefaultPool.isDefaultPool(destination) {
                    // Off the main actor; Cancel reaches it through the
                    // handler, as a detached task isn't this one's child.
                    let clone = Task.detached(priority: .userInitiated) { [self] in
                        try await HorizontalGitClone.clone(HorizontalDefaultPool.remote, into: destination) { progress in
                            Task { @MainActor in self.report(progress) }
                        }
                    }
                    _ = try await withTaskCancellationHandler {
                        try await clone.value
                    } onCancel: {
                        clone.cancel()
                    }
                }
                if HorizontalPoolRegistry.shared.addPool(at: destination) {
                    HorizontalPoolLibrary.invalidateCache()
                    state = .finished(destination)
                } else {
                    giveBack()
                    state = .failed("The clone in \(destination.path) has no pool.json Horizontal could read.")
                }
            } catch {
                giveBack()
                // A download cancelled midway throws URLError's cancelled.
                state = Task.isCancelled || error is CancellationError ? .offer : .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    private func report(_ progress: HorizontalGitClone.Progress) {
        if case .cloning = state {
            state = .cloning(progress)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard task == nil else { return }
        state = .offer
    }
}

/// The offer and, once taken up, the clone's progress and outcome.
struct HorizontalDefaultPoolOfferView: View {
    @ObservedObject var clone: HorizontalDefaultPoolClone
    /// Asks for the folder to clone into; the platform's picker.
    var chooseFolder: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                Text("Horizon's Default Pool")
                    .font(.title2.weight(.semibold))
            }
            content
        }
        .padding(22)
        .frame(width: 440)
    }

    @ViewBuilder
    private var content: some View {
        switch clone.state {
        case .offer:
            Text("Horizon's default pool holds thousands of parts with their symbols, footprints and 3D models. Horizontal can clone it from GitHub (about 35 MB to download) into a folder you choose and add it to your pools. It is an ordinary git repository, so git can update it later.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Pools ▸ Get Horizon Default Pool… offers this again later.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not Now", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Clone…", action: chooseFolder)
                    .keyboardShortcut(.defaultAction)
            }
        case .cloning(let progress):
            Text(Self.describe(progress))
                .monospacedDigit()
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel") { clone.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .finished(let url):
            Text("Added Horizon's default pool to your pools, from \(url.path).")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            Text("The clone didn't finish: \(message)")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again…") {
                    clone.reset()
                    chooseFolder()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func describe(_ progress: HorizontalGitClone.Progress) -> String {
        switch progress.phase {
        case .connecting:
            "Asking GitHub for the pool…"
        case .receiving:
            "Downloading: \(ByteCountFormatter.string(fromByteCount: Int64(progress.completed), countStyle: .file))"
        case .indexing:
            "Reading objects: \(progress.completed.formatted()) of \((progress.total ?? 0).formatted())"
        case .checkingOut:
            "Writing files: \(progress.completed.formatted()) of \((progress.total ?? 0).formatted())"
        }
    }
}

#if os(macOS)
/// The offer in a window of its own, shown at the first launch and from the
/// Pools menu; the folder is chosen in a panel on it.
@MainActor
final class HorizontalDefaultPoolWindow: NSObject, NSWindowDelegate {
    static let shared = HorizontalDefaultPoolWindow()

    private var window: NSWindow?
    private let clone = HorizontalDefaultPoolClone()
    private var onClose: (() -> Void)?

    func show(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        clone.reset()
        let view = HorizontalDefaultPoolOfferView(
            clone: clone,
            chooseFolder: { [weak self] in self?.chooseFolder() },
            close: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        // Titled for the Window menu; the view's heading says it on screen.
        window.title = "Horizon's Default Pool"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.message = "Choose where Horizon's default pool goes: an empty folder, or a folder to put a new “\(HorizontalDefaultPool.folderName)” folder in."
        panel.prompt = "Clone Here"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.clone.start(in: url)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A clone in flight is cancelled rather than left running unseen.
        if case .cloning = clone.state {
            clone.cancel()
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        HorizontalDefaultPool.markOffered()
        window = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}
#endif

/// The offer as a sheet, on iPad: the folder is chosen in the Files picker.
struct HorizontalDefaultPoolSheet: View {
    @StateObject private var clone = HorizontalDefaultPoolClone()
    @State private var isChoosingFolder = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HorizontalDefaultPoolOfferView(
            clone: clone,
            chooseFolder: { isChoosingFolder = true },
            close: {
                if case .cloning = clone.state { clone.cancel() }
                HorizontalDefaultPool.markOffered()
                dismiss()
            }
        )
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                clone.start(in: url, scoped: true)
            }
        }
        .interactiveDismissDisabled(isCloning)
    }

    private var isCloning: Bool {
        if case .cloning = clone.state { return true }
        return false
    }
}
