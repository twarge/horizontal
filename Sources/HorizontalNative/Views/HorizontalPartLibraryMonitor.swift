import Combine
import Foundation
import HorizontalProjectIO
import SwiftUI

/// What a project's parts are checked against: the project pool's files, the
/// parts the design uses and where, and the pools the project draws from.
struct HorizontalPartLibraryInputs: Equatable {
    var poolURL: URL?
    var files: [String: Data]
    var references: [String: [String]]
    var partIDs: [String]
    var isReadOnly: Bool
}

/// The project's parts against the pools they came from, kept current for a
/// document so it can say when they fall behind, as Horizon's project window
/// shows its pool cache status ("3 out of date") and its editors say "Pool
/// has changed". The Parts pane, the updates sheet and the document's info
/// bar all read this one review.
///
/// A review after an edit reuses the pools' cached scan: an edit changes the
/// project, not the pools. A pool item saved, a pool registered, the app
/// coming back to the front or Check Again scan the pools afresh.
@MainActor
final class HorizontalPartLibraryMonitor: ObservableObject {
    @Published private(set) var review: HorizontalPoolCacheReview?
    @Published private(set) var isChecking = false
    @Published var error: String?
    /// Which pool to take a part from where nothing records it, chosen in the
    /// updates sheet.
    @Published private(set) var sourceOverrides: [String: URL] = [:]
    /// The parts the info bar named when it was last dismissed; it comes back
    /// when that changes.
    @Published private var dismissedSignature: String?

    private var inputs: HorizontalPartLibraryInputs?
    private var task: Task<Void, Never>?
    private var registryChanges: AnyCancellable?

    init() {
        // A pool registered or taken away changes where parts can come from.
        registryChanges = HorizontalPoolRegistry.shared.$pools.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
    }

    /// Checks again for new inputs, after a moment, so a run of edits checks
    /// once. The same inputs check nothing.
    func update(_ newInputs: HorizontalPartLibraryInputs) {
        guard newInputs != inputs else { return }
        inputs = newInputs
        check(rescanningPools: false, after: .milliseconds(600))
    }

    /// Checks the same inputs again, scanning the pools afresh: something in
    /// them may have changed on disk.
    func recheck() {
        check(rescanningPools: true, after: .zero)
    }

    /// Takes the part from `url` where nothing records which pool it came from.
    func chooseSource(_ partID: String, url: URL) throws {
        guard HorizontalPoolRegistry.shared.addPool(at: url) else {
            throw HorizontalDispatchError.failed("Choose a library folder containing pool.json.")
        }
        sourceOverrides[partID] = url.standardizedFileURL
        recheck()
    }

    /// The parts the info bar is about: out of date, or in no attached pool.
    var noticeSignature: String {
        review.map(Self.noticeSignature(for:)) ?? ""
    }

    nonisolated static func noticeSignature(for review: HorizontalPoolCacheReview) -> String {
        (review.outdatedInUse.map { "u:\($0.id)" } + review.notInAttachedPoolInUse.map { "m:\($0.id)" }).sorted().joined(separator: ",")
    }

    var showsNotice: Bool {
        let signature = noticeSignature
        return !signature.isEmpty && signature != dismissedSignature
    }

    func dismissNotice() {
        dismissedSignature = noticeSignature
    }

    /// The info bar's sentence: how many are behind, and how many no attached
    /// pool has, naming the parts' references while there are few.
    var noticeText: String {
        review.map(Self.noticeText(for:)) ?? ""
    }

    nonisolated static func noticeText(for review: HorizontalPoolCacheReview) -> String {
        func describe(_ parts: [HorizontalPartLibraryReview], _ singular: String, _ plural: String) -> String? {
            guard !parts.isEmpty else { return nil }
            let references = parts.flatMap(\.references).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let named = references.count <= 4 ? " (\(references.joined(separator: ", ")))" : ""
            return "\(parts.count) \(parts.count == 1 ? singular : plural)\(named)"
        }
        return [describe(review.outdatedInUse, "part is out of date with its pool", "parts are out of date with their pools"),
                describe(review.notInAttachedPoolInUse, "part isn't in any attached pool", "parts aren't in any attached pool")]
            .compactMap { $0 }.joined(separator: "; ")
    }

    private func check(rescanningPools: Bool, after delay: Duration) {
        task?.cancel()
        guard let inputs, let poolURL = inputs.poolURL, !inputs.files.isEmpty || inputs.isReadOnly else {
            review = nil
            return
        }
        let overrides = sourceOverrides
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.isChecking = true
            defer { self.isChecking = false }
            let pools = HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: poolURL)
            do {
                let result = try await Task.detached(priority: .utility) {
                    if rescanningPools { HorizontalPoolLibrary.invalidateCache() }
                    let files = try inputs.files.isEmpty && inputs.isReadOnly
                        ? HorizontalPoolCacheUpdater.filesOnDisk(in: poolURL) : inputs.files
                    return try HorizontalPoolCacheUpdater.review(poolURL: poolURL, files: files, sourcePools: pools,
                                                                  partIDs: inputs.partIDs, references: inputs.references,
                                                                  sourceOverrides: overrides)
                }.value
                guard !Task.isCancelled else { return }
                self.review = result
            } catch {
                guard !Task.isCancelled else { return }
                self.review = nil
                self.error = HorizontalCanvasProjectEdit.message(for: error)
            }
        }
    }
}

/// Horizon's info bar for a pool cache that has fallen behind: what is out
/// of date or in no attached pool, and a way to the updates sheet.
struct HorizontalPartLibraryNotice: View {
    @ObservedObject var library: HorizontalPartLibraryMonitor
    var onReview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
            Text(library.noticeText)
                .font(.callout)
                .lineLimit(2)
            Button("Review Updates…", action: onReview)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss") { library.dismissNotice() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 1)
    }
}
