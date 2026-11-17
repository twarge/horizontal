import SwiftUI

extension View {
    /// The confirmation before a project's edits are written into the pools
    /// they came from (`HorizontalPoolEditCopier`): what each pool's copy is
    /// replaced with, and that the pools' files aren't taken back by Undo.
    /// The Parts pane and the updates sheet each show their own, since an
    /// alert of the window's can't come up over a sheet.
    func poolEditCopyConfirmation(_ pending: Binding<HorizontalPoolEditCopy?>,
                                  onCopy: @escaping (HorizontalPoolEditCopy) -> Void) -> some View {
        alert(pending.wrappedValue.map { "Copy changes to \($0.targetList)?" } ?? "",
              isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { copy in
            Button("Copy") { onCopy(copy) }
            Button("Cancel", role: .cancel) {}
        } message: { copy in
            Text(copy.summary)
        }
    }
}

/// The Pools pane's copy of one item's edits: the confirmation, the copy the
/// project window then makes, and why one couldn't be planned or made.
struct HorizontalPoolItemEditCopyPrompt: ViewModifier {
    @Binding var pending: HorizontalPoolEditCopy?
    @Binding var message: String?
    var copy: ((HorizontalPoolEditCopy) throws -> Void)?

    func body(content: Content) -> some View {
        content
            .poolEditCopyConfirmation($pending) { planned in
                do {
                    try copy?(planned)
                } catch {
                    message = HorizontalCanvasProjectEdit.message(for: error)
                }
            }
            .alert(
                "Could Not Copy Changes",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }
}

/// The mark the Pools pane puts beside the pools of a row that was edited in
/// the project: the Parts pane's, an arrow up to the pool that could take it.
struct HorizontalPoolItemEditMark: View {
    /// The pools the edits can be copied back to, by name.
    var targets: [String]

    var body: some View {
        Image(systemName: "arrow.up.circle")
            .foregroundStyle(.orange)
            .help(Self.help(targets))
            .accessibilityLabel("Edited in this project")
    }

    static func help(_ targets: [String]) -> String {
        "Edited in this project. \(targets.joined(separator: " and ")) \(targets.count == 1 ? "doesn't" : "don't") have the changes."
    }
}
