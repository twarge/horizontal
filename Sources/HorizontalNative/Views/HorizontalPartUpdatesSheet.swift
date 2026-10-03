import SwiftUI
import UniformTypeIdentifiers

struct HorizontalPartUpdatesSheet: View {
    var review: HorizontalPoolCacheReview
    var isReadOnly: Bool
    var isRefreshing: Bool
    var onRefresh: () -> Void
    var onChooseSource: (String, URL) throws -> Void
    var onUpdate: (HorizontalPoolCacheReview, Set<String>, Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var checked = Set<String>()
    @State private var selection: String?
    @State private var selectedChange: String?
    @State private var showAll = false
    @State private var allowProjectChanges = false
    @State private var error: String?
    @State private var previews: HorizontalPoolUpdatePreviews?
    @State private var isChoosingSource = false
    @State private var sourcePartID: String?

    private var rows: [HorizontalPartLibraryReview] {
        review.parts.filter { showAll || $0.status != .current && $0.status != .projectOnly }
            .sorted {
                if $0.references.isEmpty != $1.references.isEmpty { return !$0.references.isEmpty }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
    private var selected: HorizontalPartLibraryReview? { review.parts.first { $0.id == selection } }
    private var change: HorizontalPoolCacheChange? {
        selected?.changes.first { $0.path == selectedChange } ?? selected?.changes.first
    }
    private var affected: [HorizontalPartLibraryReview] { review.affectedParts(selecting: checked) }
    private var needsConfirmation: Bool {
        let paths = Set(review.parts.filter { checked.contains($0.id) }.flatMap(\.changes).map(\.path))
        return affected.flatMap(\.changes).contains { paths.contains($0.path) && ($0.locallyModified || $0.unverified) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Update Project Parts").font(.headline)
                Spacer()
                Toggle("Show all parts", isOn: $showAll)
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .help("Check source libraries again")
                    .disabled(isRefreshing)
            }
            .padding(16)
            Divider()
            if horizontalSizeClass == .compact {
                partList.frame(height: 150)
                Divider()
                ScrollView { detail }
            } else {
                HStack(spacing: 0) {
                    partList.frame(width: 280)
                    Divider()
                    detail
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !checked.isEmpty {
                    Text("Affected: " + affected.map { $0.references.isEmpty ? $0.name : $0.references.joined(separator: ", ") }.joined(separator: "; "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if needsConfirmation {
                    Toggle("Replace local edits and unverified project copies", isOn: $allowProjectChanges)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Update Selected") {
                        do {
                            try onUpdate(review, checked, allowProjectChanges)
                            dismiss()
                        } catch { self.error = HorizontalCanvasProjectEdit.message(for: error) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checked.isEmpty || isReadOnly || isRefreshing || needsConfirmation && !allowProjectChanges)
                }
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 850, idealWidth: 1000, minHeight: 600, idealHeight: 720)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .fileImporter(isPresented: $isChoosingSource, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let sourcePartID else { return }
                try onChooseSource(sourcePartID, url)
            } catch { self.error = HorizontalCanvasProjectEdit.message(for: error) }
        }
        .onAppear {
            checked = Set(review.parts.filter { $0.canUpdate && !$0.references.isEmpty && !$0.needsConfirmation }.map(\.id))
            selection = rows.first?.id
        }
        .onChange(of: review.digest) { _, _ in
            checked.formIntersection(Set(review.parts.filter(\.canUpdate).map(\.id)))
            allowProjectChanges = false
            error = nil
        }
        .onChange(of: selection) { _, _ in selectedChange = nil }
        .task(id: "\(selection ?? ""): \(review.digest)") {
            guard let selected else { previews = nil; return }
            let files = review.projectFiles
            let changes = selected.changes
            do {
                let result = try await Task.detached(priority: .utility) {
                    try HorizontalPoolUpdatePreviews(files: files, changes: changes)
                }.value
                guard !Task.isCancelled else { return }
                previews = result
            } catch { previews = nil }
        }
    }

    private var partList: some View {
        List(selection: $selection) {
            ForEach(rows) { part in
                HStack(spacing: 10) {
                    Toggle("Update \(part.name)", isOn: Binding(
                        get: { checked.contains(part.id) },
                        set: { if $0 { checked.insert(part.id) } else { checked.remove(part.id) } }
                    ))
                    .labelsHidden()
                    .disabled(!part.canUpdate || isReadOnly || isRefreshing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(part.name).lineLimit(1)
                        Label(part.status.title, systemImage: part.status.symbol)
                            .font(.caption).foregroundStyle(.secondary)
                        if !part.references.isEmpty {
                            Text(part.references.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(part.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 12) {
                Text(selected.name).font(.title3.weight(.semibold))
                if !selected.message.isEmpty { Text(selected.message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if selected.status == .sourceUnavailable {
                    Button { sourcePartID = selected.id; isChoosingSource = true } label: {
                        Label("Choose Source Library", systemImage: "folder")
                    }
                    .disabled(isRefreshing)
                }
                if selected.changes.isEmpty {
                    Text(selected.status.title).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Picker("Changed item", selection: Binding(get: { change?.path ?? "" }, set: { selectedChange = $0 })) {
                        ForEach(selected.changes) { item in Text(item.title).tag(item.path) }
                    }
                    if let change {
                        Text(change.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Changed: " + change.fields.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: ", "))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let reason = change.blockingReason { Text(reason).foregroundStyle(.red) }
                        if ["pins", "pads", "placement", "junctions", "lines", "polygons", "shapes", "holes"].contains(where: { change.fields.contains($0) }) {
                            Text("Geometry changed. Review connections, clearances, and copper fills after updating.")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        if let previews, change.path.hasSuffix(".json") {
                            HStack(spacing: 0) {
                                previewColumn("Project", path: change.path, root: previews.before, index: previews.beforeIndex)
                                Divider()
                                previewColumn("Library", path: change.path, root: previews.after, index: previews.afterIndex)
                            }
                            .frame(minHeight: 200, idealHeight: 260, maxHeight: 360)
                        } else {
                            Text("3D model content changed.").foregroundStyle(.secondary)
                            Spacer()
                        }
                        DisclosureGroup("JSON Comparison") {
                            ScrollView([.horizontal, .vertical]) {
                                HStack(alignment: .top, spacing: 20) {
                                    Text(prettyJSON(change.before)).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(prettyJSON(change.after)).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            .frame(height: 140)
                        }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("No Library Changes", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewColumn(_ title: String, path: String, root: URL, index: HorizontalPoolLibraryIndex) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold))
            HorizontalPoolItemPreviewView(item: HorizontalPoolLibrary.items(inPool: root, poolName: title).first {
                $0.url == root.appendingPathComponent(path)
            }, index: index)
            .id(root.path + path)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prettyJSON(_ data: Data?) -> String {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "-" }
        return text
    }
}

/// Preview bytes are materialized privately; unsaved project files never come from disk.
private final class HorizontalPoolUpdatePreviews: @unchecked Sendable {
    let directory: URL
    let before: URL
    let after: URL
    let beforeIndex: HorizontalPoolLibraryIndex
    let afterIndex: HorizontalPoolLibraryIndex

    init(files: [String: Data], changes: [HorizontalPoolCacheChange]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-library-review-\(UUID().uuidString)")
        before = directory.appendingPathComponent("project")
        after = directory.appendingPathComponent("library")
        var next = files
        for change in changes { next[change.path] = change.after }
        do {
            for (root, contents) in [(before, files), (after, next)] {
                for (path, data) in contents where path.hasSuffix(".json") && !path.hasPrefix(".horizontal/") {
                    let url = try HorizontalPoolCacheProvenance.safeURL(path, in: root)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        beforeIndex = HorizontalPoolLibraryIndex(items: HorizontalPoolLibrary.items(inPool: before, poolName: "Project"))
        afterIndex = HorizontalPoolLibraryIndex(items: HorizontalPoolLibrary.items(inPool: after, poolName: "Library"))
    }

    deinit {
        HorizontalPoolLibrary.invalidateCache(for: before)
        HorizontalPoolLibrary.invalidateCache(for: after)
        try? FileManager.default.removeItem(at: directory)
    }
}
