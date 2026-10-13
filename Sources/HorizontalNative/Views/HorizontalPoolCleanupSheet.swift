import SwiftUI

/// Horizon's "Clean up Pool Cache": the project pool's cached items nothing
/// in the design reaches, each with a checkbox, removed as one undoable step.
struct HorizontalPoolCleanupSheet: View {
    var review: HorizontalPoolCacheCleanupReview
    var isReadOnly: Bool
    var onRemove: (HorizontalPoolCacheCleanupReview, Set<String>) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checked = Set<String>()
    @State private var error: String?

    private var groups: [(kind: String, title: String, items: [HorizontalPoolCacheCleanupItem])] {
        var order = [String]()
        var byKind = [String: [HorizontalPoolCacheCleanupItem]]()
        for item in review.items {
            if byKind[item.kind] == nil { order.append(item.kind) }
            byKind[item.kind, default: []].append(item)
        }
        return order.map { kind in
            let items = byKind[kind] ?? []
            return (kind, HorizontalPoolItemCategory(rawValue: kind)?.title ?? "3D Models", items)
        }
    }

    private var checkedBytes: Int {
        review.items.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean Up Project Pool").font(.headline)
                Text("Items in the project pool that nothing in the design uses: no component, sheet frame, board decal or via names them, or anything they depend on.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if review.items.isEmpty {
                ContentUnavailableView("Nothing in the project pool is unused.", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.kind) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                HStack {
                    if !review.items.isEmpty {
                        Button("Select All") { checked = Set(review.items.map(\.id)) }
                        Button("Select None") { checked = [] }
                        Text("\(checked.count) of \(review.items.count) selected, \(Self.size(checkedBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Remove Selected", role: .destructive) {
                        do {
                            try onRemove(review, checked)
                            dismiss()
                        } catch { self.error = HorizontalCanvasProjectEdit.message(for: error) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checked.isEmpty || isReadOnly)
                }
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 560)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        // Everything starts ticked, as in Horizon.
        .onAppear { checked = Set(review.items.map(\.id)) }
    }

    private func row(_ item: HorizontalPoolCacheCleanupItem) -> some View {
        Toggle(isOn: Binding(
            get: { checked.contains(item.id) },
            set: { if $0 { checked.insert(item.id) } else { checked.remove(item.id) } }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    Text(item.paths.count == 1 ? item.paths[0] : "\(item.paths[0]) and \(item.paths.count - 1) more")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(Self.size(item.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .disabled(isReadOnly)
        .help(item.paths.joined(separator: "\n"))
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
