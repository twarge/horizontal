import SwiftUI

/// The Pools pane's Move to Trash…: asks before an item's files go to the
/// Trash, naming what uses it as Horizon's delete dialog lists Where Used,
/// and says why when the item can't go or its files couldn't be moved.
struct HorizontalPoolItemDeletionPrompt: ViewModifier {
    @Binding var pending: HorizontalPoolItemDeletion?
    @Binding var message: String?
    var onDeleted: (HorizontalPoolLibraryItem) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { deletion in
                Button(deletion.isInUse ? "Move to Trash Anyway" : "Move to Trash", role: .destructive) {
                    perform(deletion)
                }
                Button("Cancel", role: .cancel) {}
            } message: { deletion in
                Text(Self.message(for: deletion))
            }
            .alert(
                "Could Not Delete Item",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private var title: String {
        guard let deletion = pending else {
            return ""
        }
        return "Move \(deletion.item.category.singularTitle.lowercased()) “\(deletion.item.name)” to the Trash?"
    }

    static func message(for deletion: HorizontalPoolItemDeletion) -> String {
        var lines = [String]()
        if deletion.isInUse {
            lines.append(deletion.usersDescription + " They will name an item that is no longer there.")
        }
        if deletion.item.category == .package, deletion.paths.first?.lastPathComponent != "package.json" {
            lines.append("The package’s folder goes with it, its own padstacks included.")
        }
        if !deletion.keptModels.isEmpty {
            lines.append("Its 3D models outside that folder stay where they are: \(deletion.keptModels.joined(separator: ", ")).")
        }
        #if os(iOS)
        lines.append("Where the pool’s volume has no Recently Deleted, the files are deleted for good.")
        #endif
        return lines.joined(separator: "\n\n")
    }

    private func perform(_ deletion: HorizontalPoolItemDeletion) {
        pending = nil
        do {
            try deletion.perform(breakingUsers: true)
            onDeleted(deletion.item)
        } catch {
            message = "“\(deletion.item.name)” could not be moved to the Trash: \(error.localizedDescription)"
        }
    }
}
