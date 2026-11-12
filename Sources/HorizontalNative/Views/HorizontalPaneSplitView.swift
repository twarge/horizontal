import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The side-by-side pane splitter, shared by the macOS workspace and the iPad
// project view. Extracted from the (macOS-only) ProjectDocumentView so iOS can
// show two panes at once too; the layout math is unchanged.

struct ResizablePaneSplitView<Content: View>: View {
    var panes: [HorizontalPane]
    @Binding var sizeFractions: [HorizontalPane: CGFloat]
    var minimumPaneWidth: CGFloat = 280
    var handleWidth: CGFloat = 10
    /// How much of the leading pane lies under the navigator sidebar, which
    /// the split runs beneath. The leading pane's minimum adds it, so a
    /// leading pane dragged narrow still shows `minimumPaneWidth` of itself
    /// beside the sidebar rather than a sliver.
    var leadingInset: CGFloat = 0
    /// Panes that stay mounted once shown. One of them hidden keeps its place
    /// among the slots, at no width and out of sight, so it is the same view
    /// when it comes back, with its state, rather than one built afresh.
    var keepsMounted: Set<HorizontalPane> = []
    @ViewBuilder var content: (HorizontalPane, Bool) -> Content

    @State private var activeDrag: SplitDrag?
    @State private var shownPanes = ShownPanes()

    var body: some View {
        GeometryReader { proxy in
            let layout = paneLayout(totalWidth: proxy.size.width)
            let slots = paneSlots()

            HStack(spacing: 0) {
                ForEach(slots) { slot in
                    let isShown = slot.index != nil
                    let pane = slot.pane

                    // A pane never paints past its own width. Content wider
                    // than a narrow pane (a toolbar that couldn't shrink) is
                    // centred on it, so it ran over the panes on both sides:
                    // the Parts pane's background covered the right of the
                    // Pools pane, a band left of its own table, and the
                    // divider between them, which then couldn't be grabbed.
                    //
                    // Shown or kept hidden, a pane goes through the same
                    // modifiers, which only take other values: a branch would
                    // make it another view, and hiding it would unmount it.
                    // Hidden, what the pane can't shrink (its rail) is moved
                    // far past the window's edge, where no click finds it.
                    content(pane, slot.index == panes.startIndex)
                        .frame(width: slot.index.map { layout.widths[$0] } ?? 0)
                        .clipped()
                        .opacity(isShown ? 1 : 0)
                        .offset(x: isShown ? 0 : Self.hiddenPaneOffset)
                        .allowsHitTesting(isShown)
                        .accessibilityHidden(!isShown)

                    if let index = slot.index, index < panes.index(before: panes.endIndex) {
                        // Above both its panes, so it is always the divider
                        // that takes a drag there.
                        SplitHandle()
                            .frame(width: handleWidth)
                            .zIndex(1)
                            .gesture(
                                DragGesture(
                                    minimumDistance: 0,
                                    coordinateSpace: .named(ResizablePaneSplitDragCoordinateSpace.name)
                                )
                                    .onChanged { value in
                                        resize(
                                            handleIndex: index,
                                            translation: value.translation.width,
                                            layout: layout
                                        )
                                    }
                                    .onEnded { _ in
                                        activeDrag = nil
                                    }
                            )
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: ResizablePaneSplitDragCoordinateSpace.name)
        }
    }

    private func paneLayout(totalWidth: CGFloat) -> PaneLayout {
        let handleSpace = handleWidth * CGFloat(max(panes.count - 1, 0))
        let contentWidth = max(totalWidth - handleSpace, 0)
        let widths = paneWidths(contentWidth: contentWidth)
        return PaneLayout(widths: widths, contentWidth: contentWidth)
    }

    /// The shown panes, in order, then the kept panes hidden now. Being in
    /// the same `ForEach` under the same id is what keeps a pane mounted
    /// from shown to hidden and back.
    private func paneSlots() -> [PaneSlot] {
        let hidden = shownPanes.record(panes, keeping: keepsMounted)
        return panes.enumerated().map { PaneSlot(index: $0.offset, pane: $0.element) }
            + hidden.map { PaneSlot(index: nil, pane: $0) }
    }

    /// How far right a hidden pane is drawn: past any window, so nothing in it
    /// that overflows its zero width lies over a shown pane.
    private static var hiddenPaneOffset: CGFloat { 100_000 }

    private func paneWidths(contentWidth: CGFloat) -> [CGFloat] {
        guard !panes.isEmpty else {
            return []
        }

        guard contentWidth > 0 else {
            return Array(repeating: 0, count: panes.count)
        }

        guard contentWidth >= panes.indices.reduce(CGFloat.zero, { $0 + minimumWidth(at: $1) }) else {
            // Too narrow for every minimum: even shares of what the sidebar
            // leaves, the leading pane's taking the sidebar's part too.
            let inset = min(max(leadingInset, 0), contentWidth)
            var widths = Array(repeating: (contentWidth - inset) / CGFloat(panes.count), count: panes.count)
            widths[panes.startIndex] += inset
            return widths
        }

        let fractions = normalizedFractions()
        var widths = fractions.map { $0 * contentWidth }
        var lockedIndices = Set<Int>()
        var didLockWidth = true

        while didLockWidth {
            didLockWidth = false
            let remainingWidth = contentWidth - lockedIndices.reduce(CGFloat.zero) { $0 + minimumWidth(at: $1) }
            let remainingFraction = panes.indices
                .filter { !lockedIndices.contains($0) }
                .reduce(CGFloat.zero) { $0 + fractions[$1] }

            guard remainingFraction > 0 else {
                break
            }

            for index in panes.indices where !lockedIndices.contains(index) {
                widths[index] = remainingWidth * fractions[index] / remainingFraction
                if widths[index] < minimumWidth(at: index) {
                    widths[index] = minimumWidth(at: index)
                    lockedIndices.insert(index)
                    didLockWidth = true
                }
            }
        }

        return widths
    }

    /// The least a pane is given: `minimumPaneWidth` of it in view.
    private func minimumWidth(at index: Int) -> CGFloat {
        minimumPaneWidth + (index == panes.startIndex ? max(leadingInset, 0) : 0)
    }

    private func normalizedFractions() -> [CGFloat] {
        guard !panes.isEmpty else {
            return []
        }

        let fallbackFraction = 1 / CGFloat(panes.count)
        let rawFractions = panes.map { max(sizeFractions[$0] ?? fallbackFraction, 0.01) }
        let total = rawFractions.reduce(CGFloat.zero, +)
        guard total > 0 else {
            return Array(repeating: fallbackFraction, count: panes.count)
        }

        return rawFractions.map { $0 / total }
    }

    private func resize(handleIndex: Int, translation: CGFloat, layout: PaneLayout) {
        guard handleIndex >= panes.startIndex,
              handleIndex < panes.index(before: panes.endIndex),
              layout.contentWidth > 0 else {
            return
        }

        let drag: SplitDrag
        if let activeDrag, activeDrag.handleIndex == handleIndex {
            drag = activeDrag
        } else {
            drag = SplitDrag(
                handleIndex: handleIndex,
                widths: layout.widths,
                contentWidth: layout.contentWidth
            )
            activeDrag = drag
        }

        let leftIndex = handleIndex
        let rightIndex = handleIndex + 1
        let pairWidth = drag.widths[leftIndex] + drag.widths[rightIndex]
        // A pair too narrow for both minimums shares them out in proportion.
        var leftMinimum = minimumWidth(at: leftIndex)
        var rightMinimum = minimumWidth(at: rightIndex)
        if leftMinimum + rightMinimum > pairWidth {
            let scale = pairWidth / max(leftMinimum + rightMinimum, 1)
            leftMinimum *= scale
            rightMinimum *= scale
        }
        let proposedLeftWidth = (drag.widths[leftIndex] + translation)
            .clamped(to: leftMinimum...max(pairWidth - rightMinimum, leftMinimum))

        var resizedWidths = drag.widths
        resizedWidths[leftIndex] = proposedLeftWidth
        resizedWidths[rightIndex] = pairWidth - proposedLeftWidth
        applyFractions(for: resizedWidths, contentWidth: drag.contentWidth)
    }

    private func applyFractions(for widths: [CGFloat], contentWidth: CGFloat) {
        guard contentWidth > 0 else {
            return
        }

        var newFractions = sizeFractions
        for (index, pane) in panes.enumerated() {
            newFractions[pane] = widths[index] / contentWidth
        }
        sizeFractions = newFractions
    }

    private struct PaneLayout {
        var widths: [CGFloat]
        var contentWidth: CGFloat
    }

    /// A pane's place in the split: its index among the shown panes, or nil
    /// for a kept pane that is hidden.
    private struct PaneSlot: Identifiable {
        var index: Int?
        var pane: HorizontalPane

        var id: HorizontalPane {
            pane
        }
    }

    /// The kept panes the split has shown. Recorded as the slots are built,
    /// rather than in state set afterwards, so the pass that hides a pane
    /// already knows to keep it: a pass without it would unmount it.
    private final class ShownPanes {
        private var panes = Set<HorizontalPane>()

        /// Takes note of `shown` and gives the kept panes shown before and
        /// hidden now.
        func record(_ shown: [HorizontalPane], keeping kept: Set<HorizontalPane>) -> [HorizontalPane] {
            panes.formUnion(shown.filter { kept.contains($0) })
            return HorizontalPane.allCases.filter { panes.contains($0) && kept.contains($0) && !shown.contains($0) }
        }
    }

    private struct SplitDrag {
        var handleIndex: Int
        var widths: [CGFloat]
        var contentWidth: CGFloat
    }
}

private enum ResizablePaneSplitDragCoordinateSpace {
    static let name = "ResizablePaneSplitDragCoordinateSpace"
}

private struct SplitHandle: View {
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .overlay {
                Capsule()
                    .fill(separatorColor.opacity(isHovered ? 0.85 : 0.32))
                    .frame(width: isHovered ? 2 : 1)
            }
            #if os(iOS) || os(visionOS)
            // Touch has no hover to reveal the divider, so the iPad handle carries a
            // visible grabber — the same affordance as a sheet's grabber, rotated.
            .overlay {
                Capsule()
                    .fill(.primary.opacity(0.28))
                    .frame(width: 4, height: 44)
            }
            #endif
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            #endif
            .accessibilityLabel("Resize panes")
    }

    private var separatorColor: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}
