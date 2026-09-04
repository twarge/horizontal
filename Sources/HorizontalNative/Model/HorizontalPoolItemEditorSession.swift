import Foundation
import HorizontalProjectIO
import SwiftUI

enum HorizontalPoolItemEditorError: LocalizedError {
    case missingFileURL

    var errorDescription: String? {
        switch self {
        case .missingFileURL:
            "A pool item can only be edited from a file on disk."
        }
    }
}

/// The editing state behind one open pool item document: the parsed model,
/// the pool index its cross-references resolve through, and the single
/// commit funnel that registers undo, serialises in Horizon's format and
/// hands the bytes to the document.
///
/// The host view wires `persist` to the document's archive, so every commit
/// makes the document dirty and FileDocument's Save writes what Horizon
/// would have written.
@MainActor
final class HorizontalPoolItemEditorSession: ObservableObject {
    let category: HorizontalPoolItemCategory
    let itemURL: URL
    /// The root of the pool the item belongs to (its nearest `pool.json`), or
    /// the item's own directory when it lives outside any pool.
    let poolURL: URL
    let poolName: String

    @Published private(set) var model: HorizontalPoolItemModel
    @Published private(set) var index = HorizontalPoolLibraryIndex.empty
    @Published private(set) var isIndexing = false
    @Published private(set) var lastError: String?
    /// The bytes most recently handed to the document; nil until the first
    /// commit. The save relay matches a document write against this.
    private(set) var lastSerializedData: Data?
    /// Set by the hosting view: writes the serialised item into the document.
    var persist: ((Data) -> Void)?

    private let undoTarget = HorizontalUndoTarget<HorizontalPoolItemModel>()

    init(itemURL: URL, poolURL: URL?, category: HorizontalPoolItemCategory, data: Data) throws {
        self.category = category
        self.itemURL = itemURL.standardizedFileURL
        let root = poolURL?.standardizedFileURL ?? itemURL.deletingLastPathComponent().standardizedFileURL
        self.poolURL = root
        poolName = HorizontalPoolRegistryStore.poolInfo(at: root).name
        let json = try JSONHelper.loadDictionary(from: data)
        model = try HorizontalPoolItemModel.load(category: category, json: json)
    }

    /// The window title: the item's name, falling back to its filename.
    var title: String {
        let name = model.name
        return name.isEmpty ? itemURL.deletingPathExtension().lastPathComponent : name
    }

    var subtitle: String {
        "\(category.singularTitle) — \(poolName)"
    }

    /// The library entry for this item, so the preview and the index can
    /// address it; synthesised when the scan didn't (or couldn't) find it.
    var libraryItem: HorizontalPoolLibraryItem {
        if let item = index.item(category, uuid: model.uuid) {
            return item
        }
        return HorizontalPoolLibraryItem(
            id: poolURL.path + "|" + category.rawValue + "|" + model.uuid.lowercased(),
            uuid: model.uuid.lowercased(),
            name: title,
            detail: "",
            tags: "",
            category: category,
            poolName: poolName,
            poolURL: poolURL,
            url: itemURL
        )
    }

    var validationIssues: [HorizontalPoolCheckIssue] {
        model.validationIssues()
    }

    /// Scans the item's pool, the pools it includes and the discovered base
    /// pools off the main actor, then swaps the index in.
    func rebuildIndex() async {
        isIndexing = true
        defer { isIndexing = false }
        let poolURLs = HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: poolURL)
        let items = await Task.detached(priority: .userInitiated) {
            poolURLs.flatMap { url in
                HorizontalPoolLibrary.items(inPool: url, poolName: HorizontalPoolRegistryStore.poolInfo(at: url).name)
            }
        }.value
        index = HorizontalPoolLibraryIndex(items: items)
    }

    /// The one way the model changes. A no-op in read-only operation, which
    /// the document's write path would refuse anyway.
    ///
    /// `registersUndo` is false for edits a canvas already recorded on the
    /// same undo manager (it restores its board and re-publishes the model),
    /// so one gesture never leaves two undo entries.
    func commit(
        _ newModel: HorizontalPoolItemModel,
        actionName: String,
        undoManager: UndoManager?,
        isReadOnly: Bool,
        registersUndo: Bool = true
    ) {
        guard !isReadOnly, newModel != model else {
            return
        }
        let previous = model
        if registersUndo {
            undoTarget.configure(
                currentValue: { [weak self] in self?.model ?? newModel },
                restoreValue: { [weak self] restored in self?.apply(restored) }
            )
            undoTarget.registerUndo(from: previous, actionName: actionName, undoManager: undoManager)
        }
        apply(newModel)
    }

    private func apply(_ newModel: HorizontalPoolItemModel) {
        model = newModel
        do {
            let data = try HorizontalHorizonJSONWriter.data(newModel.json())
            lastSerializedData = data
            lastError = nil
            persist?(data)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
