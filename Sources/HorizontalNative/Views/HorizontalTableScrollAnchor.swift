import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Asks a SwiftUI `Table` to bring one of its rows into view: the Pools pane
/// and the Parts pane scroll to the item a reveal or a link selected, however
/// far down a long list it is.
///
/// Not `ScrollViewReader`: on macOS 26 its `scrollTo` reaches a table's rows
/// only once they have arrived as an update. A table created with its rows
/// already in it — the Pools pane once its scan is in, a list coming back from
/// its empty state, the parametric list for another table — ignores it however
/// long after one asks, which is exactly when a reveal that came in before the
/// rows lands. So the table's own platform view is found beside this anchor
/// and scrolled directly: the NSTableView on macOS, the collection view on
/// iPadOS, whose rows are the table's rows in order.
struct HorizontalTableScrollRequest: Equatable {
    /// The row's id, as the table's selection names it.
    var rowID: String
    /// Its position among the rows the table is given, sorted and filtered.
    var row: Int
    /// How many rows the table is given. The platform view is scrolled only
    /// once it has that many — once it holds the rows `row` counts in — so a
    /// request made in the same pass as a change of rows waits for them.
    var rowCount: Int
    /// A row out of view is centred (a reveal: the row the user asked for,
    /// with the rows around it), rather than scrolled the least that shows it
    /// (keeping a selection in view).
    var centers: Bool
    /// A fresh value asks again for the same row.
    var token: Int

    /// What makes two requests the same ask: the anchor acts once per key,
    /// so a pass of the body that rebuilds the same request does nothing.
    var key: String { "\(token)|\(rowID)" }
}

extension View {
    /// Scrolls the table this modifies to `request`'s row whenever a request
    /// with a new key arrives; nil asks for nothing.
    func tableScrollRequest(_ request: HorizontalTableScrollRequest?) -> some View {
        background {
            HorizontalTableScrollAnchor(request: request)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// How long the anchor keeps looking for a table holding the request's rows:
/// a table swapping its rows, or one being created, gets them a pass or two
/// after the request; one that never does (the row went away) stops being
/// asked.
private enum HorizontalTableScrollTiming {
    static let attempts = 24
    static let interval: TimeInterval = 0.025
}

#if os(macOS)
private struct HorizontalTableScrollAnchor: NSViewRepresentable {
    var request: HorizontalTableScrollRequest?

    func makeCoordinator() -> HorizontalTableScrollCoordinator {
        HorizontalTableScrollCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        HorizontalTableScrollAnchorView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(request, anchor: view)
    }
}

/// Takes no clicks: it lies under the whole table.
private final class HorizontalTableScrollAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class HorizontalTableScrollCoordinator {
    private var lastKey: String?
    private var generation = 0

    func update(_ request: HorizontalTableScrollRequest?, anchor: NSView) {
        guard let request, request.key != lastKey else {
            return
        }
        lastKey = request.key
        generation += 1
        attempt(request, anchor: anchor, generation: generation, remaining: HorizontalTableScrollTiming.attempts)
    }

    /// Tried after the current pass, when the table has taken this pass's
    /// rows, and again until it holds the request's rows; a newer request
    /// ends the tries.
    private func attempt(_ request: HorizontalTableScrollRequest, anchor: NSView, generation: Int, remaining: Int) {
        let delay = remaining == HorizontalTableScrollTiming.attempts ? 0 : HorizontalTableScrollTiming.interval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak anchor] in
            guard let self, let anchor, generation == self.generation else {
                return
            }
            if let table = Self.tableView(near: anchor), table.numberOfRows == request.rowCount {
                Self.scroll(table, toRow: request.row, centers: request.centers)
            } else if remaining > 1 {
                attempt(request, anchor: anchor, generation: generation, remaining: remaining - 1)
            }
        }
    }

    /// The table the anchor sits behind: of the tables in the nearest
    /// ancestor that has any, the one whose scroll view covers the most of
    /// the anchor. SwiftUI hosts the table and the anchor's view as siblings
    /// somewhere up the tree, not as parent and child.
    static func tableView(near anchor: NSView) -> NSTableView? {
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        guard anchor.window != nil, anchorFrame.width > 0, anchorFrame.height > 0 else {
            return nil
        }
        var ancestor = anchor.superview
        while let view = ancestor {
            var best: (table: NSTableView, overlap: CGFloat)?
            for table in tables(in: view) {
                let container: NSView = table.enclosingScrollView ?? table
                let frame = container.convert(container.bounds, to: nil).intersection(anchorFrame)
                let overlap = frame.isNull ? 0 : frame.width * frame.height
                if overlap > (best?.overlap ?? 0) {
                    best = (table, overlap)
                }
            }
            if let best, best.overlap >= anchorFrame.width * anchorFrame.height * 0.5 {
                return best.table
            }
            ancestor = view.superview
        }
        return nil
    }

    /// SwiftUI's table is an NSOutlineView (it can disclose rows), so outline
    /// views count; the navigator's sidebar is told apart by where it is.
    private static func tables(in view: NSView) -> [NSTableView] {
        var result = [NSTableView]()
        var stack = [view]
        while let next = stack.popLast() {
            if let table = next as? NSTableView {
                result.append(table)
                continue
            }
            stack.append(contentsOf: next.subviews)
        }
        return result
    }

    /// Nothing moves when the row is wholly in view already.
    static func scroll(_ table: NSTableView, toRow row: Int, centers: Bool) {
        guard row >= 0, row < table.numberOfRows else {
            return
        }
        guard let scrollView = table.enclosingScrollView else {
            table.scrollRowToVisible(row)
            return
        }
        let clip = scrollView.contentView
        let rowRect = clip.convert(table.rect(ofRow: row), from: table)
        let insets = clip.contentInsets
        var visible = clip.bounds
        visible.origin.y += insets.top
        visible.size.height -= insets.top + insets.bottom
        if visible.minY <= rowRect.minY && rowRect.maxY <= visible.maxY {
            return
        }
        guard centers else {
            table.scrollRowToVisible(row)
            return
        }
        var bounds = clip.bounds
        bounds.origin.y += rowRect.midY - visible.midY
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
#else
private struct HorizontalTableScrollAnchor: UIViewRepresentable {
    var request: HorizontalTableScrollRequest?

    func makeCoordinator() -> HorizontalTableScrollCoordinator {
        HorizontalTableScrollCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(request, anchor: view)
    }
}

@MainActor
private final class HorizontalTableScrollCoordinator {
    private var lastKey: String?
    private var generation = 0

    func update(_ request: HorizontalTableScrollRequest?, anchor: UIView) {
        guard let request, request.key != lastKey else {
            return
        }
        lastKey = request.key
        generation += 1
        attempt(request, anchor: anchor, generation: generation, remaining: HorizontalTableScrollTiming.attempts)
    }

    private func attempt(_ request: HorizontalTableScrollRequest, anchor: UIView, generation: Int, remaining: Int) {
        let delay = remaining == HorizontalTableScrollTiming.attempts ? 0 : HorizontalTableScrollTiming.interval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak anchor] in
            guard let self, let anchor, generation == self.generation else {
                return
            }
            if let collection = Self.collectionView(near: anchor),
               let section = Self.section(of: collection, holding: request.rowCount) {
                Self.scroll(collection, to: IndexPath(item: request.row, section: section), centers: request.centers)
            } else if remaining > 1 {
                attempt(request, anchor: anchor, generation: generation, remaining: remaining - 1)
            }
        }
    }

    /// As on macOS: the collection view covering most of the anchor, in the
    /// nearest ancestor that has one.
    static func collectionView(near anchor: UIView) -> UICollectionView? {
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        guard anchor.window != nil, anchorFrame.width > 0, anchorFrame.height > 0 else {
            return nil
        }
        var ancestor = anchor.superview
        while let view = ancestor {
            var best: (view: UICollectionView, overlap: CGFloat)?
            var stack = [view]
            while let next = stack.popLast() {
                if let collection = next as? UICollectionView {
                    let frame = collection.convert(collection.bounds, to: nil).intersection(anchorFrame)
                    let overlap = frame.isNull ? 0 : frame.width * frame.height
                    if overlap > (best?.overlap ?? 0) {
                        best = (collection, overlap)
                    }
                    continue
                }
                stack.append(contentsOf: next.subviews)
            }
            if let best, best.overlap >= anchorFrame.width * anchorFrame.height * 0.5 {
                return best.view
            }
            ancestor = view.superview
        }
        return nil
    }

    /// The section that is the table's rows: the one with exactly as many
    /// items, the first such.
    static func section(of collection: UICollectionView, holding rowCount: Int) -> Int? {
        (0..<collection.numberOfSections).first { collection.numberOfItems(inSection: $0) == rowCount }
    }

    static func scroll(_ collection: UICollectionView, to indexPath: IndexPath, centers: Bool) {
        guard indexPath.item >= 0, indexPath.item < collection.numberOfItems(inSection: indexPath.section) else {
            return
        }
        let visible = collection.bounds.inset(by: collection.adjustedContentInset)
        let frame = collection.layoutAttributesForItem(at: indexPath)?.frame
        if let frame, visible.minY <= frame.minY, frame.maxY <= visible.maxY {
            return
        }
        let position: UICollectionView.ScrollPosition
        if centers {
            position = .centeredVertically
        } else if let frame, frame.maxY <= visible.minY {
            position = .top
        } else {
            position = .bottom
        }
        collection.scrollToItem(at: indexPath, at: position, animated: false)
    }
}
#endif
