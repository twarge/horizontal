import SwiftUI

/// The library browser's preview pane: a drawing for symbols, frames,
/// packages, padstacks and decals, a table for units and entities, and for
/// parts their data, their symbols and their footprint. Sits below the item
/// list; follows the selection.
struct HorizontalPoolItemPreviewView: View {
    var item: HorizontalPoolLibraryItem?
    var index: HorizontalPoolLibraryIndex
    /// Takes the browser to an item a part's data links to (its entity,
    /// units, symbols, package…). Nil shows those names as plain text.
    var onReveal: ((HorizontalPoolRevealRequest) -> Void)? = nil

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview: HorizontalPoolItemPreview?
    @State private var loadedItemID: HorizontalPoolLibraryItem.ID?
    @State private var symbolQuarterTurns = 0
    @State private var symbolMirrored = false

    private struct LoadKey: Equatable {
        var itemID: String?
        var quarterTurns: Int
        var mirrored: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(itemID: item?.id, quarterTurns: symbolQuarterTurns, mirrored: symbolMirrored)
    }

    var body: some View {
        ZStack {
            if let item {
                if let preview, loadedItemID == item.id {
                    previewContent(preview, item: item)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Text("Select an item to preview it.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadKey) {
            await load()
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: HorizontalPoolItemPreview, item: HorizontalPoolLibraryItem) -> some View {
        switch preview {
        case .symbol(let artwork):
            HorizontalSymbolPreviewCanvas(artwork: artwork, palette: schematicPalette)
                .overlay(alignment: .topTrailing) {
                    if item.category == .symbol {
                        symbolControls
                    }
                }
        case .board(let geometry, let hiddenLayers):
            HorizontalBoardPreviewCanvas(geometry: geometry, hiddenLayers: hiddenLayers, palette: boardPalette)
        case .table(let table):
            HorizontalPoolPreviewTableView(table: table, onReveal: onReveal)
        case .part(let part):
            // Horizon's part preview: the data on top, the entity's symbols
            // below it, the footprint beside both. The data and the symbols
            // split the column's height; the data scrolls.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HorizontalPoolPreviewTableView(table: part.table, onReveal: onReveal)
                    if !part.gates.isEmpty {
                        Divider()
                        HorizontalPoolPartSymbolView(gates: part.gates, palette: schematicPalette)
                            .id(item.id)
                    }
                }
                if let geometry = part.package {
                    Divider()
                    HorizontalBoardPreviewCanvas(
                        geometry: geometry,
                        hiddenLayers: HorizontalPoolPreviewBuilder.packageHiddenLayers,
                        palette: boardPalette
                    )
                    .frame(minWidth: 180, idealWidth: 280, maxWidth: 360)
                }
            }
        case .unavailable(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    /// Horizon's symbol preview offers the four orientations and mirroring,
    /// because a symbol carries a text placement per view.
    private var symbolControls: some View {
        HStack(spacing: 6) {
            Picker("Rotation", selection: $symbolQuarterTurns) {
                Text("0°").tag(0)
                Text("90°").tag(1)
                Text("180°").tag(2)
                Text("270°").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Toggle("Mirror", isOn: $symbolMirrored)
                .toggleStyle(.button)
        }
        .controlSize(.small)
        .padding(8)
    }

    private var schematicPalette: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .schematic, colorScheme: colorScheme)
    }

    private var boardPalette: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    private func load() async {
        guard let item else {
            preview = nil
            loadedItemID = nil
            return
        }
        let index = index
        // Horizon angles: 65536 per turn, so a quarter turn is 16384.
        let transform = HorizontalPlacementTransform(
            shift: .zero,
            angle: symbolQuarterTurns * 16_384,
            mirrored: symbolMirrored
        )
        let result = await Task.detached(priority: .userInitiated) {
            HorizontalPoolPreviewBuilder.preview(for: item, index: index, symbolTransform: transform)
        }.value
        guard !Task.isCancelled else {
            return
        }
        preview = result
        loadedItemID = item.id
    }
}

// MARK: - Canvases

private struct HorizontalSymbolPreviewCanvas: View {
    var artwork: HorizontalSymbolPreviewArtwork
    var palette: HorizontalCanvasPalette

    var body: some View {
        Canvas { context, size in
            let transform = HorizontalCanvasTransform(
                bounds: HorizontalPoolPreviewDrawing.bounds(for: artwork.points),
                size: size,
                fitInsets: HorizontalPoolPreviewDrawing.fitInsets
            )
            HorizontalPoolPreviewDrawing.strokePolygons(artwork.polygons, color: palette.pin, context: context, transform: transform)
            HorizontalPoolPreviewDrawing.strokeSegments(artwork.lines, color: palette.pin, context: context, transform: transform)
            HorizontalPoolPreviewDrawing.strokeSegments(artwork.pins, color: palette.pin, context: context, transform: transform)
            HorizontalPoolPreviewDrawing.strokeCircles(artwork.pinCircles, color: palette.pin, context: context, transform: transform)
            HorizontalPoolPreviewDrawing.strokeTexts(artwork.texts, color: palette.pinAnnotation, context: context, transform: transform)
        }
        .background(palette.background)
    }
}

/// A part's symbols, Horizon's entity preview: a gate menu ("A: Opamp") when
/// the entity has several, a symbol menu when the gate's unit has several,
/// and the chosen symbol drawn below them. A unit's choice of symbol holds
/// for every gate that uses the unit.
private struct HorizontalPoolPartSymbolView: View {
    var gates: [HorizontalPoolPartPreview.Gate]
    var palette: HorizontalCanvasPalette

    @State private var gateID: String?
    @State private var symbolIDByUnit: [String: String] = [:]

    private var gate: HorizontalPoolPartPreview.Gate? {
        gates.first { $0.id == gateID } ?? gates.first
    }

    private func symbol(of gate: HorizontalPoolPartPreview.Gate) -> HorizontalPoolPartPreview.Symbol? {
        gate.symbols.first { $0.id == symbolIDByUnit[gate.unitID] } ?? gate.symbols.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let gate {
                header(gate)
                Divider()
                drawing(gate)
            }
        }
    }

    /// A lone gate goes unnamed: it is the entity's only one, and its unit's
    /// name is the symbol's more often than not. The menus narrow, their
    /// titles truncating, in a narrow pane.
    private func header(_ gate: HorizontalPoolPartPreview.Gate) -> some View {
        HStack(spacing: 6) {
            if gates.count > 1 {
                Text("Gate")
                    .foregroundStyle(.secondary)
                Picker("Gate", selection: Binding(get: { gate.id }, set: { gateID = $0 })) {
                    ForEach(gates) { gate in
                        Text(gate.title).tag(gate.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            Text("Symbol")
                .foregroundStyle(.secondary)
                .padding(.leading, gates.count > 1 ? 4 : 0)
            if gate.symbols.count > 1, let current = symbol(of: gate) {
                Picker("Symbol", selection: Binding(get: { current.id }, set: { symbolIDByUnit[gate.unitID] = $0 })) {
                    ForEach(gate.symbols) { symbol in
                        Text(symbol.name).tag(symbol.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            } else {
                Text(symbol(of: gate)?.name ?? "None")
                    .foregroundStyle(gate.symbols.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func drawing(_ gate: HorizontalPoolPartPreview.Gate) -> some View {
        let symbol = symbol(of: gate)
        if let artwork = symbol?.artwork {
            HorizontalSymbolPreviewCanvas(artwork: artwork, palette: palette)
        } else {
            // Past the preview's limit (an entity with dozens of units), or
            // a file that can't be read.
            Text(symbol.map { "“\($0.name)” isn’t drawn here." }
                 ?? "No browsed pool has a symbol for the unit “\(gate.unitName)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.background)
        }
    }
}

private struct HorizontalBoardPreviewCanvas: View {
    var geometry: HorizontalPackageGeometry
    var hiddenLayers: Set<Int>
    var palette: HorizontalCanvasPalette

    var body: some View {
        Canvas { context, size in
            let transform = HorizontalCanvasTransform(
                bounds: HorizontalPoolPreviewDrawing.bounds(for: geometry.points),
                size: size,
                fitInsets: HorizontalPoolPreviewDrawing.fitInsets
            )
            // One pass per layer, lowest first, so the top side reads as the
            // front the way the board canvas draws it.
            for layer in drawnLayers {
                let color = palette.layerColor(for: layer)
                let filled = HorizontalPoolPreviewDrawing.isCopperLayer(layer)
                HorizontalPoolPreviewDrawing.drawPolygons(
                    geometry.pads.filter { $0.layer == layer },
                    color: color,
                    filled: filled,
                    context: context,
                    transform: transform
                )
                HorizontalPoolPreviewDrawing.drawPolygons(
                    geometry.polygons.filter { $0.layer == layer },
                    color: color,
                    filled: filled,
                    context: context,
                    transform: transform
                )
                HorizontalPoolPreviewDrawing.drawPolygons(
                    geometry.keepouts.map(\.polygon).filter { $0.layer == layer },
                    color: color.opacity(0.7),
                    filled: false,
                    context: context,
                    transform: transform
                )
                HorizontalPoolPreviewDrawing.strokeSegments(
                    geometry.lines.filter { $0.layer == layer },
                    color: color,
                    context: context,
                    transform: transform
                )
                HorizontalPoolPreviewDrawing.strokeArcs(
                    geometry.arcs.filter { $0.layer == layer },
                    color: color,
                    context: context,
                    transform: transform
                )
                HorizontalPoolPreviewDrawing.strokeTexts(
                    geometry.texts.filter { $0.layer == layer },
                    color: color,
                    context: context,
                    transform: transform
                )
            }
            HorizontalPoolPreviewDrawing.drawHoles(
                geometry.holes,
                fill: palette.background,
                stroke: palette.hole,
                context: context,
                transform: transform
            )
        }
        .background(palette.background)
    }

    private var drawnLayers: [Int] {
        var layers = Set<Int>()
        layers.formUnion(geometry.pads.compactMap(\.layer))
        layers.formUnion(geometry.polygons.compactMap(\.layer))
        layers.formUnion(geometry.keepouts.compactMap(\.polygon.layer))
        layers.formUnion(geometry.lines.compactMap(\.layer))
        layers.formUnion(geometry.arcs.compactMap(\.layer))
        layers.formUnion(geometry.texts.compactMap(\.layer))
        return layers.subtracting(hiddenLayers).sorted()
    }
}

/// Stroke-and-fill primitives for the preview canvases, in world coordinates
/// through a fitted canvas transform.
enum HorizontalPoolPreviewDrawing {
    static let fitInsets = HorizontalCanvasInsets(top: 14, leading: 14, bottom: 14, trailing: 14)

    /// The region to fit: the drawing's bounds with a margin, widened to a
    /// square when it is degenerate (a lone horizontal line, a single point)
    /// so the transform never sees an empty rect.
    static func bounds(for points: [HorizontalPoint]) -> HorizontalRect {
        var rect = HorizontalRect(points: points)
        let extent = max(rect.width, rect.height, 1_000_000)
        if rect.width < extent * 0.05 || rect.height < extent * 0.05 {
            rect = HorizontalRect(center: rect.center, size: extent)
        }
        return rect.expanded(by: extent * 0.04)
    }

    static func isCopperLayer(_ layer: Int) -> Bool {
        layer == HorizontalBoardLayers.topCopper
            || layer == HorizontalBoardLayers.bottomCopper
            || (HorizontalBoardLayers.in8Copper...HorizontalBoardLayers.in1Copper).contains(layer)
    }

    static func strokeSegments(
        _ segments: [HorizontalSegment],
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        var pathsByWidth = [CGFloat: Path]()
        for segment in segments {
            let width = transform.strokeWidth(segment.width, minimum: 1)
            pathsByWidth[width, default: Path()].addLines([transform.point(segment.from), transform.point(segment.to)])
        }
        for (width, path) in pathsByWidth {
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    static func strokeArcs(
        _ arcs: [HorizontalArc],
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for arc in arcs {
            let points = arc.polyline(precision: 48)
            guard points.count >= 2 else {
                continue
            }
            var path = Path()
            path.addLines(points.map(transform.point))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: transform.strokeWidth(arc.width, minimum: 1), lineCap: .round, lineJoin: .round)
            )
        }
    }

    static func strokeCircles(
        _ circles: [HorizontalCircle],
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for circle in circles {
            let center = transform.point(circle.center)
            let radius = transform.length(circle.radius)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: transform.strokeWidth(0, minimum: 1))
        }
    }

    static func strokePolygons(
        _ polygons: [HorizontalPolygon],
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        drawPolygons(polygons, color: color, filled: false, context: context, transform: transform)
    }

    static func drawPolygons(
        _ polygons: [HorizontalPolygon],
        color: Color,
        filled: Bool,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for polygon in polygons {
            let vertices = polygon.renderVertices(arcPrecision: 32)
            guard vertices.count >= 2 else {
                continue
            }
            var path = Path()
            path.addLines(vertices.map(transform.point))
            path.closeSubpath()
            if filled {
                context.fill(path, with: .color(color.opacity(0.9)))
            } else {
                context.stroke(path, with: .color(color), lineWidth: transform.strokeWidth(0, minimum: 1))
            }
        }
    }

    static func strokeTexts(
        _ texts: [HorizontalText],
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for text in texts {
            let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
            guard !segments.isEmpty else {
                continue
            }
            var path = Path()
            for (from, to) in segments {
                path.addLines([transform.point(from), transform.point(to)])
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: transform.strokeWidth(text.width, minimum: 1), lineCap: .round, lineJoin: .round)
            )
        }
    }

    static func drawHoles(
        _ holes: [HorizontalHole],
        fill: Color,
        stroke: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for hole in holes {
            let outline = hole.outlinePoints(precision: 32)
            guard outline.count >= 3 else {
                continue
            }
            var path = Path()
            path.addLines(outline.map(transform.point))
            path.closeSubpath()
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(stroke), lineWidth: transform.strokeWidth(0, minimum: 1))
        }
    }
}

// MARK: - Tables

private struct HorizontalPoolPreviewTableView: View {
    var table: HorizontalPoolItemPreviewTable
    var onReveal: ((HorizontalPoolRevealRequest) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !table.fields.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(table.fields) { field in
                            GridRow {
                                Text(field.label)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                fieldValue(field)
                            }
                        }
                    }
                }
                ForEach(table.sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.headline)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                            GridRow {
                                ForEach(section.columns, id: \.self) { column in
                                    Text(column)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text(cell.isEmpty ? "-" : cell)
                                            .foregroundStyle(cell.isEmpty ? .tertiary : .primary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func fieldValue(_ field: HorizontalPoolItemPreviewTable.Field) -> some View {
        if !field.links.isEmpty {
            HorizontalPoolPreviewFlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(field.links) { link in
                    itemLink(link)
                }
            }
        } else if field.label == "Datasheet", let url = HorizontalDatasheetLink.url(field.value) {
            Link(HorizontalDatasheetLink.shortText(url), destination: url)
                .lineLimit(1)
                .help(field.value)
        } else {
            Text(field.value)
        }
    }

    /// An item the part leads to, as the Parts pane draws its links: the
    /// name in the accent colour, the pointing hand over it, and what tells
    /// it apart after it. One no browsed pool has stays plain text.
    @ViewBuilder
    private func itemLink(_ link: HorizontalPoolItemLink) -> some View {
        let note = link.note.isEmpty ? nil : Text(link.note).foregroundStyle(.secondary)
        if link.isResolved, let onReveal {
            Button {
                onReveal(HorizontalPoolRevealRequest(category: link.category, uuid: link.uuid))
            } label: {
                HStack(spacing: 4) {
                    Text(link.name)
                        .foregroundStyle(Color.accentColor)
                    note
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .help("Show the \(link.role.menuTitle.lowercased()) “\(link.name)” in the list")
        } else {
            HStack(spacing: 4) {
                Text(link.name)
                note
            }
            .help(link.isResolved ? "" : "No browsed pool has this \(link.role.menuTitle.lowercased()) (\(link.uuid)).")
        }
    }
}

/// Lays its views out in rows, left to right, wrapping when the next one
/// doesn't fit: a part's several units, symbols or padstacks in the one
/// column a field's value has.
private struct HorizontalPoolPreviewFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    /// The first row's baseline, so the field's label lines up with it in
    /// the grid rather than with the bottom of several rows.
    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else {
            return nil
        }
        return bounds.minY + first.dimensions(in: .unspecified)[.firstTextBaseline]
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Rows for a width; nil (the ideal size) is one row. A view wider than
    /// the width gets a row of its own, as wide as the width, and wraps
    /// within it (a unit with a long name).
    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [Row] {
        var rows = [Row]()
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if let width, size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let widthWith = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if let width, !row.items.isEmpty, widthWith > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty {
            rows.append(row)
        }
        return rows
    }
}
