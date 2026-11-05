import SwiftUI

/// The board rail's airwire filter: a button whose popover chooses which
/// nets' airwires the board draws, Horizon's airwire filter window. It shows
/// read-only too, since it changes only the view. Design ▸ Filter Airwires…
/// opens the same popover through `isPresented`.
struct BoardAirwireFilterToolButton: View {
    var board: HorizontalBoard?
    @Binding var displayOptions: BoardDisplayOptions
    @Binding var isPresented: Bool
    var highlightedNetIDs: Set<String> = []
    var onHighlightNets: (Set<String>) -> Void = { _ in }

    /// Whether the filter hides a net this board has. A net it names that
    /// the board lost is ignored, so it doesn't mark the button.
    private var isFiltering: Bool {
        guard let board else {
            return false
        }
        return displayOptions.hiddenAirwireNetIDs.contains { board.netDetails[$0] != nil }
    }

    var body: some View {
        HorizontalRailHelpLabel(title: "Filter airwires") {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help(isFiltering ? "Filter airwires (some nets are hidden)" : "Filter airwires")
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                BoardAirwireFilterPanel(
                    board: board,
                    displayOptions: $displayOptions,
                    highlightedNetIDs: highlightedNetIDs,
                    onHighlightNets: onHighlightNets
                )
            }
        }
    }
}

/// The filter's controls: the board's nets with airwires, each with its count
/// and a switch, narrowed by a search and a net class, with Show All and
/// Hide All for what is listed. A click on a row highlights its net.
struct BoardAirwireFilterPanel: View {
    var board: HorizontalBoard?
    @Binding var displayOptions: BoardDisplayOptions
    var highlightedNetIDs: Set<String> = []
    var onHighlightNets: (Set<String>) -> Void = { _ in }

    @State private var search = ""
    @State private var netClassID: String?

    private static let rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let board {
                content(rows: BoardAirwireFilter.rows(board: board, options: displayOptions))
            } else {
                Text("Airwires")
                    .font(.headline)
                Text("No board file was loaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    @ViewBuilder
    private func content(rows: [BoardAirwireFilter.Row]) -> some View {
        let classes = BoardAirwireFilter.netClasses(in: rows)
        let classID = classes.contains { $0.id == netClassID } ? netClassID : nil
        let matched = BoardAirwireFilter.matching(rows, search: search, netClassID: classID)
        let hiddenCount = rows.filter { !$0.isShown }.count

        HStack(alignment: .firstTextBaseline) {
            Text("Airwires")
                .font(.headline)
            Spacer()
            if !rows.isEmpty {
                Text(hiddenCount == 0 ? "All \(rows.count) nets shown" : "\(rows.count - hiddenCount) of \(rows.count) nets shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        if !displayOptions.connectionLines {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                Text("Connections are off, so no airwires draw whatever the filter says.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Show") {
                    displayOptions.connectionLines = true
                }
                .help("Turn the Connections switch on")
            }
        }

        if rows.isEmpty {
            Text("Every connection is routed: the board has no airwires.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                TextField("Search Nets", text: $search)
                    .textFieldStyle(.roundedBorder)
                if !classes.isEmpty {
                    Picker("Net Class", selection: $netClassID) {
                        Text("All Classes").tag(String?.none)
                        ForEach(classes) { netClass in
                            Text(netClass.name).tag(Optional(netClass.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if matched.isEmpty {
                Text("No net matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight * 2)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matched) { row in
                            rowView(row)
                        }
                    }
                }
                .frame(height: min(CGFloat(matched.count) * Self.rowHeight, 320))
            }

            HStack {
                Button("Show All") {
                    displayOptions.setAirwiresShown(true, forNets: matched.map(\.id))
                }
                .disabled(matched.allSatisfy(\.isShown))
                Button("Hide All") {
                    displayOptions.setAirwiresShown(false, forNets: matched.map(\.id))
                }
                .disabled(matched.allSatisfy { !$0.isShown })
                Spacer()
                if matched.count != rows.count {
                    Text("\(matched.count) listed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .help("Show or hide the airwires of every net listed")
        }
    }

    private func rowView(_ row: BoardAirwireFilter.Row) -> some View {
        let isHighlighted = highlightedNetIDs.contains(row.id)
        return HStack(spacing: 8) {
            shownToggle(row)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isShown ? .primary : .secondary)
            Spacer(minLength: 4)
            if let netClassName = row.netClassName {
                Text(netClassName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(row.airwireCount.formatted())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
                .help(row.airwireCount == 1 ? "1 airwire" : "\(row.airwireCount) airwires")
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // A second click on the one net highlighted clears it.
            onHighlightNets(highlightedNetIDs == [row.id] ? [] : [row.id])
        }
        .help("Click to highlight \(row.name)")
    }

    @ViewBuilder
    private func shownToggle(_ row: BoardAirwireFilter.Row) -> some View {
        let isShown = Binding {
            row.isShown
        } set: { isShown in
            displayOptions.setAirwiresShown(isShown, forNets: [row.id])
        }
        #if os(macOS)
        Toggle("Show \(row.name)", isOn: isShown)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(row.isShown ? "Hide this net's airwires" : "Show this net's airwires")
        #else
        Button {
            isShown.wrappedValue.toggle()
        } label: {
            Image(systemName: row.isShown ? "checkmark.square.fill" : "square")
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .foregroundStyle(row.isShown ? Color.accentColor : Color.secondary)
        .accessibilityLabel(row.isShown ? "Hide \(row.name)" : "Show \(row.name)")
        #endif
    }
}
