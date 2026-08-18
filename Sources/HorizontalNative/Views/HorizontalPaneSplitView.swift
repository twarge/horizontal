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
    @ViewBuilder var content: (HorizontalPane, Bool) -> Content

    @State private var activeDrag: SplitDrag?

    var body: some View {
        GeometryReader { proxy in
            let layout = paneLayout(totalWidth: proxy.size.width)
            let slots = paneSlots()

            HStack(spacing: 0) {
                ForEach(slots) { slot in
                    let index = slot.index
                    let pane = slot.pane

                    content(pane, index == panes.startIndex)
                        .frame(width: layout.widths[index])

                    if index < panes.index(before: panes.endIndex) {
                        SplitHandle()
                            .frame(width: handleWidth)
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

    private func paneSlots() -> [PaneSlot] {
        panes.enumerated().map { PaneSlot(index: $0.offset, pane: $0.element) }
    }

    private func paneWidths(contentWidth: CGFloat) -> [CGFloat] {
        guard !panes.isEmpty else {
            return []
        }

        guard contentWidth > 0 else {
            return Array(repeating: 0, count: panes.count)
        }

        guard contentWidth >= minimumPaneWidth * CGFloat(panes.count) else {
            return Array(repeating: contentWidth / CGFloat(panes.count), count: panes.count)
        }

        let fractions = normalizedFractions()
        var widths = fractions.map { $0 * contentWidth }
        var lockedIndices = Set<Int>()
        var didLockWidth = true

        while didLockWidth {
            didLockWidth = false
            let remainingWidth = contentWidth - minimumPaneWidth * CGFloat(lockedIndices.count)
            let remainingFraction = panes.indices
                .filter { !lockedIndices.contains($0) }
                .reduce(CGFloat.zero) { $0 + fractions[$1] }

            guard remainingFraction > 0 else {
                break
            }

            for index in panes.indices where !lockedIndices.contains(index) {
                widths[index] = remainingWidth * fractions[index] / remainingFraction
                if widths[index] < minimumPaneWidth {
                    widths[index] = minimumPaneWidth
                    lockedIndices.insert(index)
                    didLockWidth = true
                }
            }
        }

        return widths
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
        let minimumWidth = min(minimumPaneWidth, max(pairWidth / 2, 1))
        let proposedLeftWidth = (drag.widths[leftIndex] + translation)
            .clamped(to: minimumWidth...(pairWidth - minimumWidth))

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

    private struct PaneSlot: Identifiable {
        var index: Int
        var pane: HorizontalPane

        var id: HorizontalPane {
            pane
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
            #if os(iOS)
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
