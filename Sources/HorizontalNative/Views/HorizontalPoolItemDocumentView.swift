import HorizontalProjectIO
import SwiftUI

/// The document window for one pool item: the item's editor beside its
/// preview, backed by an editor session whose commits flow into the
/// document (dirty state, Save, undo) like any other document edit.
///
/// Until a kind has its full editor, this shows the item's header fields —
/// the values Horizon's own editors keep in their title-bar popover — plus
/// its checks and the same preview the library pane draws.
struct HorizontalPoolItemDocumentView: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    @Binding var document: HorizontalProjectDocument

    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    private var isReadOnly: Bool {
        appearanceSettings.isReadOnlyOperationEnabled
    }

    var body: some View {
        HorizontalPoolItemEditorContent(session: session, isReadOnly: isReadOnly, commit: commit)
            .navigationTitle(session.title)
            .task {
                let binding = $document
                session.persist = { data in
                    binding.wrappedValue.archive.root = .regularFile(data)
                }
                await session.rebuildIndex()
            }
            .focusedSceneValue(\.horizonReadOnlyOperation, isReadOnly)
            .onReceive(
                NotificationCenter.default.publisher(for: HorizontalProjectDocument.didWriteNotification)
                    .receive(on: RunLoop.main)
            ) { notification in
                relaySaveIfOurs(notification)
            }
    }

    private func commit(_ model: HorizontalPoolItemModel, _ actionName: String) {
        session.commit(model, actionName: actionName, undoManager: undoManager, isReadOnly: isReadOnly)
    }

    /// Every document write posts `didWriteNotification`; the one carrying the
    /// bytes this session last serialised is this item's save. Announce it so
    /// open projects refresh their copy of the file and browsers rescan.
    private func relaySaveIfOurs(_ notification: Notification) {
        guard let archive = notification.object as? HorizontalProjectArchive,
              let data = session.lastSerializedData,
              archive.root == .regularFile(data) else {
            return
        }
        HorizontalPoolLibrary.announceItemSaved(session: session, data: data)
    }
}

extension HorizontalPoolLibrary {
    /// Invalidates the scan caches and posts `itemDidSaveNotification` for an
    /// item whose bytes just went to disk.
    @MainActor
    static func announceItemSaved(session: HorizontalPoolItemEditorSession, data: Data) {
        invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
        let payload = ItemDidSavePayload(
            url: session.itemURL,
            category: session.category,
            uuid: session.model.uuid,
            data: data
        )
        NotificationCenter.default.post(
            name: itemDidSaveNotification,
            object: nil,
            userInfo: [itemDidSavePayloadKey: payload]
        )
    }
}

/// The editor beside the preview — what both hosts show.
struct HorizontalPoolItemEditorContent: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    /// The undo manager canvas editors record their own steps on; the
    /// document's when nil (the iPad cover supplies its own).
    var undoManager: UndoManager? = nil
    var commit: (HorizontalPoolItemModel, String) -> Void

    @Environment(\.undoManager) private var environmentUndoManager

    var body: some View {
        Group {
            switch session.model {
            case .package, .padstack, .decal:
                HorizontalPoolCanvasEditorView(
                    session: session,
                    isReadOnly: isReadOnly,
                    undoManager: undoManager ?? environmentUndoManager,
                    commit: commit
                )
            case .symbol, .frame:
                HorizontalPoolSchematicEditorView(
                    session: session,
                    isReadOnly: isReadOnly,
                    undoManager: undoManager ?? environmentUndoManager,
                    commit: commit
                )
            case .unit(let unit):
                ScrollView {
                    HorizontalUnitEditorView(
                        unit: unit,
                        issues: session.validationIssues,
                        isReadOnly: isReadOnly,
                        index: session.index
                    ) { commit(.unit($0), $1) }
                }
            case .entity(let entity):
                ScrollView {
                    HorizontalEntityEditorView(
                        entity: entity,
                        index: session.index,
                        issues: session.validationIssues,
                        isReadOnly: isReadOnly
                    ) { commit(.entity($0), $1) }
                }
            case .part(let part):
                HorizontalPartEditorView(
                    part: part,
                    index: session.index,
                    issues: session.validationIssues,
                    isReadOnly: isReadOnly,
                    poolURLs: HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: session.poolURL).reversed()
                ) { commit(.part($0), $1) }
            default:
                HStack(spacing: 0) {
                    ScrollView {
                        HorizontalPoolItemHeaderForm(session: session, isReadOnly: isReadOnly, commit: commit)
                            .padding(20)
                    }
                    .frame(width: 380)
                    Divider()
                    HorizontalPoolItemPreviewView(item: session.libraryItem, index: session.index)
                        .id(session.model.uuid)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS)
/// iPadOS has no way to open a second document scene from inside one, so the
/// library pane's "Edit…" presents the editor over the project instead. The
/// session writes straight to the item's file on each commit (the file is
/// inside the open project package, or in a registered pool the app holds a
/// bookmark for), with an undo manager of its own.
struct HorizontalPoolItemEditorCover: View {
    let item: HorizontalPoolLibraryItem
    var onDismiss: () -> Void

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    @State private var session: HorizontalPoolItemEditorSession?
    @State private var loadError: String?
    @State private var undoManager = UndoManager()

    private var isReadOnly: Bool {
        appearanceSettings.isReadOnlyOperationEnabled
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    HorizontalPoolItemEditorContent(session: session, isReadOnly: isReadOnly, undoManager: undoManager) { model, actionName in
                        session.commit(model, actionName: actionName, undoManager: undoManager, isReadOnly: isReadOnly)
                    }
                    .navigationTitle(session.title)
                } else if let loadError {
                    ContentUnavailableView("Could Not Open Item", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        undoManager.undo()
                    }
                    .disabled(!undoManager.canUndo)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
        .task {
            do {
                let data = try Data(contentsOf: item.url)
                let session = try HorizontalPoolItemEditorSession(
                    itemURL: item.url,
                    poolURL: item.poolURL,
                    category: item.category,
                    data: data
                )
                session.persist = { [weak session] data in
                    guard let session else {
                        return
                    }
                    do {
                        try data.write(to: session.itemURL, options: [.atomic])
                        HorizontalPoolLibrary.announceItemSaved(session: session, data: data)
                    } catch {
                        // Surfaced through the session's error banner on the
                        // next commit; the model itself stays edited.
                        print("[pool] could not write \(session.itemURL.lastPathComponent): \(error)")
                    }
                }
                self.session = session
                await session.rebuildIndex()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
#endif

// MARK: - Header form

/// The kind-specific header fields. Text fields commit when editing ends
/// (Return or focus loss), so one edit is one undo step; toggles and pickers
/// commit at once.
struct HorizontalPoolItemHeaderForm: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    var commit: (HorizontalPoolItemModel, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.category.singularTitle)
                    .font(.title2.weight(.semibold))
                Spacer()
                if isReadOnly {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                fields
            }

            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            checks

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                infoRow("UUID", session.model.uuid)
                infoRow("Pool", session.poolName)
                infoRow("File", session.itemURL.lastPathComponent)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fields: some View {
        switch session.model {
        case .unit(let unit):
            textRow("Name", unit.name, "Rename Unit") { value in
                var model = unit
                model.name = value
                commit(.unit(model), "Rename Unit")
            }
            manufacturerRow(unit.manufacturer) { value in
                var model = unit
                model.manufacturer = value
                commit(.unit(model), "Change Manufacturer")
            }
        case .entity(let entity):
            textRow("Name", entity.name, "Rename Entity") { value in
                var model = entity
                model.name = value
                commit(.entity(model), "Rename Entity")
            }
            manufacturerRow(entity.manufacturer) { value in
                var model = entity
                model.manufacturer = value
                commit(.entity(model), "Change Manufacturer")
            }
            textRow("Prefix", entity.prefix, "Change Prefix") { value in
                var model = entity
                model.prefix = value
                commit(.entity(model), "Change Prefix")
            }
            tagsRow(entity.tags) { tags in
                var model = entity
                model.tags = tags
                commit(.entity(model), "Change Tags")
            }
        case .part(let part):
            ForEach(HorizontalPartAttributeKind.allCases, id: \.self) { kind in
                let attribute = part.attribute(kind)
                GridRow {
                    Text(kind.displayName)
                        .gridColumnAlignment(.trailing)
                    HStack {
                        HorizontalCommittedTextField(
                            text: attribute.value,
                            isReadOnly: isReadOnly || attribute.inherited
                        ) { value in
                            var model = part
                            model.attributes[kind] = HorizontalPartAttribute(inherited: attribute.inherited, value: value)
                            commit(.part(model), "Change \(kind.displayName)")
                        }
                        if part.baseID != nil {
                            Toggle("Inherit", isOn: Binding(
                                get: { attribute.inherited },
                                set: { inherited in
                                    var model = part
                                    model.attributes[kind] = HorizontalPartAttribute(inherited: inherited, value: attribute.value)
                                    commit(.part(model), "Change \(kind.displayName) Inheritance")
                                }
                            ))
                            .disabled(isReadOnly)
                        }
                    }
                }
            }
            tagsRow(part.tags) { tags in
                var model = part
                model.tags = tags
                commit(.part(model), "Change Tags")
            }
            if part.baseID != nil {
                toggleRow("Inherit tags", part.inheritTags) { value in
                    var model = part
                    model.inheritTags = value
                    commit(.part(model), "Change Tag Inheritance")
                }
                infoRow("Base part", session.index.name(.part, uuid: part.baseID ?? "") ?? part.baseID ?? "")
            } else {
                infoRow("Entity", session.index.name(.entity, uuid: part.entityID ?? "") ?? part.entityID ?? "")
                infoRow("Package", session.index.name(.package, uuid: part.packageID ?? "") ?? part.packageID ?? "")
            }
        case .symbol(let symbol):
            textRow("Name", symbol.name, "Rename Symbol") { value in
                var model = symbol
                model.name = value
                commit(.symbol(model), "Rename Symbol")
            }
            infoRow("Unit", session.index.name(.unit, uuid: symbol.unitID) ?? symbol.unitID)
            toggleRow("Can expand", symbol.canExpand) { value in
                var model = symbol
                model.canExpand = value
                commit(.symbol(model), "Change Can Expand")
            }
        case .package(let package):
            textRow("Name", package.name, "Rename Package") { value in
                var model = package
                model.name = value
                commit(.package(model), "Rename Package")
            }
            manufacturerRow(package.manufacturer) { value in
                var model = package
                model.manufacturer = value
                commit(.package(model), "Change Manufacturer")
            }
            tagsRow(package.tags) { tags in
                var model = package
                model.tags = tags
                commit(.package(model), "Change Tags")
            }
            if let alternateForID = package.alternateForID {
                infoRow("Alternate for", session.index.name(.package, uuid: alternateForID) ?? alternateForID)
            }
        case .padstack(let padstack):
            textRow("Name", padstack.name, "Rename Padstack") { value in
                var model = padstack
                model.name = value
                commit(.padstack(model), "Rename Padstack")
            }
            textRow("Well-known name", padstack.wellKnownName, "Change Well-known Name") { value in
                var model = padstack
                model.wellKnownName = value
                commit(.padstack(model), "Change Well-known Name")
            }
            GridRow {
                Text("Type")
                    .gridColumnAlignment(.trailing)
                Picker("Type", selection: Binding(
                    get: { padstack.type },
                    set: { type in
                        var model = padstack
                        model.type = type
                        commit(.padstack(model), "Change Padstack Type")
                    }
                )) {
                    ForEach(HorizontalPadstackType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .disabled(isReadOnly)
            }
        case .frame(let frame):
            textRow("Name", frame.name, "Rename Frame") { value in
                var model = frame
                model.name = value
                commit(.frame(model), "Rename Frame")
            }
            lengthRow("Width", frame.width) { value in
                var model = frame
                model.width = value
                commit(.frame(model), "Change Frame Width")
            }
            lengthRow("Height", frame.height) { value in
                var model = frame
                model.height = value
                commit(.frame(model), "Change Frame Height")
            }
        case .decal(let decal):
            textRow("Name", decal.name, "Rename Decal") { value in
                var model = decal
                model.name = value
                commit(.decal(model), "Rename Decal")
            }
        }
    }

    private var checks: some View {
        HorizontalPoolItemChecksView(issues: session.validationIssues)
    }

    // MARK: Rows

    private func textRow(
        _ label: String,
        _ value: String,
        _ actionName: String,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            HorizontalCommittedTextField(text: value, isReadOnly: isReadOnly, onCommit: onCommit)
        }
    }

    private func manufacturerRow(_ value: String, onCommit: @escaping (String) -> Void) -> some View {
        GridRow {
            Text("Manufacturer")
                .gridColumnAlignment(.trailing)
            HorizontalSuggestingTextField(text: value, suggestions: session.index.manufacturers, isReadOnly: isReadOnly, onCommit: onCommit)
        }
    }

    private func tagsRow(_ tags: [String], onCommit: @escaping ([String]) -> Void) -> some View {
        GridRow {
            Text("Tags")
                .gridColumnAlignment(.trailing)
            HorizontalTokenField(tokens: tags, suggestions: session.index.tags, isReadOnly: isReadOnly, onCommit: onCommit)
        }
    }

    private func lengthRow(_ label: String, _ nanometres: Double, onCommit: @escaping (Double) -> Void) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                HorizontalCommittedTextField(
                    text: Self.millimetres(nanometres),
                    isReadOnly: isReadOnly
                ) { value in
                    if let parsed = Self.nanometres(fromMillimetres: value) {
                        onCommit(parsed)
                    }
                }
                Text("mm")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleRow(_ label: String, _ value: Bool, onCommit: @escaping (Bool) -> Void) -> some View {
        GridRow {
            Text("")
            Toggle(label, isOn: Binding(get: { value }, set: onCommit))
                .disabled(isReadOnly)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "–" : value)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Conversions

    /// Space- or comma-separated tags, kept unique and sorted as upstream's
    /// `std::set` would write them.
    static func tags(from text: String) -> [String] {
        let pieces = text
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
        return Array(Set(pieces)).sorted()
    }

    static func millimetres(_ nanometres: Double) -> String {
        let value = nanometres / 1_000_000
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    static func nanometres(fromMillimetres text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite else {
            return nil
        }
        return (value * 1_000_000).rounded()
    }
}

/// A text field that reports its value once editing ends — Return or losing
/// focus — and re-syncs from the model only while unfocused, so a re-render
/// mid-edit never wipes half-typed input (the same shape as the selection
/// inspector's fields).
struct HorizontalCommittedTextField: View {
    var text: String
    var isReadOnly: Bool
    var onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .disabled(isReadOnly)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !isFocused {
                    draft = newValue
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitIfChanged()
                }
            }
            .onSubmit {
                commitIfChanged()
            }
    }

    private func commitIfChanged() {
        guard draft != text else {
            return
        }
        onCommit(draft)
    }
}
