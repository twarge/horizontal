import SwiftUI

/// A selection inspector row whose editor has a width of its own, the
/// Rules / Custom picker of a track's Width from, a via's Shape from or a
/// plane's Settings from: its label, its editor and its trailing controls
/// (the All toggle) on one line where the row is wide enough for the editor
/// between the other two, else the editor on a line of its own under them.
/// Either way the row is no wider than it is given.
///
/// On one line as an `HStack`, with the picker held at its own width and an
/// empty unit column beside it, the Width from row was 332 points wide in the
/// selection sidebar, whose list gives a row 308. The inspector took the
/// width of its widest row, so every row's All toggle stood two thirds past
/// the list row's edge, where a click doesn't reach it: with several tracks
/// selected, All could be pressed only at its left edge, and Width from went
/// to the one track shown. A via's three choices put every All of the via
/// group past the sidebar's edge altogether.
///
/// A layout rather than a `ViewThatFits`: one with a segmented picker in both
/// of its layouts kept SwiftUI updating without end in the sidebar's list
/// (`HorizontalRouteInspectorView.sourceHeader`). The subviews are the label,
/// the editor and the trailing controls, in that order.
struct HorizontalSelectionPropertyRowLayout: Layout {
    var spacing: CGFloat
    /// Between the label's line and the editor's, when the editor is under it.
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let parts = Parts(subviews, spacing: spacing) else {
            return .zero
        }
        let width = proposal.width ?? parts.oneLineWidth
        if parts.oneLineWidth <= width {
            return CGSize(width: width, height: parts.oneLineHeight)
        }
        let editor = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(
            width: max(width, parts.wrappedMinimumWidth),
            height: parts.labelLineHeight + lineSpacing + editor.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let parts = Parts(subviews, spacing: spacing) else {
            return
        }
        let wraps = parts.oneLineWidth > bounds.width
        let labelLineY = wraps ? bounds.minY + parts.labelLineHeight / 2 : bounds.midY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: labelLineY), anchor: .leading, proposal: ProposedViewSize(parts.label))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: labelLineY), anchor: .trailing, proposal: ProposedViewSize(parts.trailing))
        if wraps {
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + parts.labelLineHeight + lineSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: min(parts.editor.width, bounds.width), height: nil)
            )
        } else {
            subviews[1].place(
                at: CGPoint(x: bounds.minX + parts.label.width + spacing, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(parts.editor)
            )
        }
    }

    /// The subviews at their own sizes.
    private struct Parts {
        var label: CGSize
        var editor: CGSize
        /// The narrowest the editor goes, on a line of its own.
        var editorMinimumWidth: CGFloat
        var trailing: CGSize
        var spacing: CGFloat

        init?(_ subviews: Subviews, spacing: CGFloat) {
            guard subviews.count == 3 else {
                return nil
            }
            label = subviews[0].sizeThatFits(.unspecified)
            editor = subviews[1].sizeThatFits(.unspecified)
            editorMinimumWidth = subviews[1].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            trailing = subviews[2].sizeThatFits(.unspecified)
            self.spacing = spacing
        }

        /// No gap for trailing controls that aren't there: a group's own row
        /// has no All toggle.
        private var trailingGap: CGFloat {
            trailing.width > 0 ? spacing : 0
        }

        var oneLineWidth: CGFloat {
            label.width + spacing + editor.width + trailingGap + trailing.width
        }

        var oneLineHeight: CGFloat {
            max(label.height, editor.height, trailing.height)
        }

        var labelLineHeight: CGFloat {
            max(label.height, trailing.height)
        }

        var wrappedMinimumWidth: CGFloat {
            max(label.width + trailingGap + trailing.width, editorMinimumWidth)
        }
    }
}
