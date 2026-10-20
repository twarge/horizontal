import SwiftUI

/// One of a block's port nets, as the Ports popover lists it.
struct HorizontalPortNetSummary: Identifiable, Equatable {
    var id: String
    var name: String
    var direction: HorizontalPinDirection
    /// Drawn on the block's symbol.
    var isPlaced: Bool
    /// Wired to something on the block's own sheets, which Horizon won't
    /// delete.
    var isInUse: Bool
}

/// What the Ports popover asks of the host: Horizon's Manage Port Nets.
enum HorizontalPortNetCommand: Equatable {
    case add(name: String)
    case rename(id: String, name: String)
    case setDirection(id: String, direction: HorizontalPinDirection)
    /// Only a net nothing on the block's sheets is wired to.
    case delete(id: String)
}

/// Horizon's Manage Port Nets: the block's ports, by name and direction,
/// with a way to add one and to delete one nothing uses.
struct HorizontalPortNetsPopover: View {
    var nets: [HorizontalPortNetSummary]
    var isReadOnly: Bool
    var onCommand: (HorizontalPortNetCommand) -> Void

    @State private var draftNames: [String: String] = [:]
    @FocusState private var focusedNetID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Port Nets")
                .font(.headline)
            if nets.isEmpty {
                Text("No ports yet. A port is a net of this block that the sheets using it wire to; add one, then place it on the symbol.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(nets) { net in
                            row(for: net)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            HStack {
                Button {
                    onCommand(.add(name: nextName))
                } label: {
                    Label("Add Port Net", systemImage: "plus")
                }
                .help("Add a port net to this block")
                Spacer()
                Text("Unplaced ports are listed beside the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 400)
        .disabled(isReadOnly)
        .onChange(of: focusedNetID) { previous, _ in
            if let previous {
                commitName(previous)
            }
        }
    }

    private func row(for net: HorizontalPortNetSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: net.isPlaced ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(net.isPlaced ? Color.accentColor : Color.secondary)
                .help(net.isPlaced ? "Drawn on the symbol" : "Not on the symbol yet")
            TextField("Name", text: nameBinding(for: net))
                .textFieldStyle(.roundedBorder)
                .focused($focusedNetID, equals: net.id)
                .onSubmit { commitName(net.id) }
            Picker("Direction", selection: directionBinding(for: net)) {
                ForEach(HorizontalPinDirection.editorOrder, id: \.self) { direction in
                    Text(direction.displayName).tag(direction)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button {
                onCommand(.delete(id: net.id))
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(net.isInUse ? Color.secondary.opacity(0.4) : Color.secondary)
            .disabled(net.isInUse)
            .help(net.isInUse ? "Wired on this block's sheets" : "Delete this port net")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func nameBinding(for net: HorizontalPortNetSummary) -> Binding<String> {
        Binding(
            get: { draftNames[net.id] ?? net.name },
            set: { draftNames[net.id] = $0 }
        )
    }

    private func directionBinding(for net: HorizontalPortNetSummary) -> Binding<HorizontalPinDirection> {
        Binding(
            get: { net.direction },
            set: { direction in
                if direction != net.direction {
                    onCommand(.setDirection(id: net.id, direction: direction))
                }
            }
        )
    }

    private func commitName(_ netID: String) {
        guard let draft = draftNames[netID] else {
            return
        }
        draftNames.removeValue(forKey: netID)
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != nets.first(where: { $0.id == netID })?.name else {
            return
        }
        onCommand(.rename(id: netID, name: trimmed))
    }

    /// Horizon names a new port net "port"; the next free one here.
    private var nextName: String {
        let taken = Set(nets.map { $0.name.lowercased() })
        guard taken.contains("port") else {
            return "port"
        }
        var index = 2
        while taken.contains("port\(index)") {
            index += 1
        }
        return "port\(index)"
    }
}

/// Horizon's block symbol editor, in the project window: the block's symbol
/// on the schematic canvas in its block flavour, its ports placed from the
/// unplaced column as a symbol's pins are, and its port nets managed beside
/// it. Every edit is written to the symbol file as the canvas makes it; the
/// canvas owns the undo.
struct HorizontalBlockSymbolEditorPane: View {
    var blockSymbol: HorizontalBlockSymbol
    /// Bumped by the host when the symbol or the block changed outside the
    /// canvas — an undo, a port net added — so the canvas takes it up.
    var revision: Int
    var poolURL: URL
    var portNets: [HorizontalPortNetSummary]
    var isReadOnly: Bool
    var undoManager: UndoManager?
    var safeAreaInsets: EdgeInsets
    var showsTools: Bool
    var isKeyboardFocused: Bool
    @Binding var displayOptions: SchematicDisplayOptions
    var selectionToolSettings: Binding<HorizontalSelectionToolSettings>
    var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    var drawingToolCommand: HorizontalDrawingToolCommand?
    var onDrawingTool: (HorizontalDrawingPrimitive) -> Void
    var onChange: (HorizontalBlockSymbol) -> Void
    var onPortNetCommand: (HorizontalPortNetCommand) -> Void
    var onSelectionDetailsChange: (HorizontalSelectionDetailState) -> Void
    var onCanvasCommandActionsChange: (HorizontalCanvasCommandActions?) -> Void
    var onToolbarHover: (Bool) -> Void

    @State private var sheet: HorizontalSchematicSheet?
    @State private var viewport = CanvasViewport()
    @State private var syncRevision = 0
    @State private var canvasActions: HorizontalCanvasCommandActions?
    @State private var portsPopoverPresented = false
    /// The file the canvas last wrote, so the host handing it back doesn't
    /// re-project the sheet under the canvas.
    @State private var committedJSON: HorizontalPreservedJSON?

    var body: some View {
        PaneOverlayContainer(
            pane: .schematic,
            safeAreaInsets: safeAreaInsets,
            showsTools: showsTools,
            showsInfoButton: false,
            isKeyboardFocused: isKeyboardFocused,
            onToolbarHover: onToolbarHover
        ) {
            if let sheet {
                SchematicCanvasView(
                    sheet: sheet,
                    viewport: $viewport,
                    displayOptions: displayOptions,
                    fitSafeAreaInsets: safeAreaInsets,
                    undoManager: undoManager,
                    selectionToolSettings: selectionToolSettings.wrappedValue,
                    isReadOnly: isReadOnly,
                    onSheetChange: { canvasChanged($0) },
                    onSelectionDetailsChange: onSelectionDetailsChange,
                    onCanvasCommandActionsChange: {
                        canvasActions = $0
                        onCanvasCommandActionsChange($0)
                    },
                    selectionPropertyChangeCommand: selectionPropertyChangeCommand,
                    drawingToolCommand: drawingToolCommand,
                    poolURL: poolURL,
                    mode: .blockSymbol,
                    symbolEditorContext: blockSymbol.context(poolURL: poolURL),
                    syncRevision: syncRevision
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } info: {
            EmptyView()
        } layers: {
            SchematicLayerControls(displayOptions: $displayOptions)
        } grid: {
            GridControlsPanel(title: "Grid", grid: .constant(sheet?.grid ?? .schematicDefault), isEditable: false)
        } tools: {
            SelectionToolButton(settings: selectionToolSettings)
            if !isReadOnly {
                DrawingToolButtonGroup(primitives: [.line, .rectangle, .circle, .arc], onSelect: onDrawingTool)
                AddTextToolButton {
                    canvasActions?.dispatch(.addText)
                }
                HorizontalRailHelpLabel(title: "Port nets") {
                    Button {
                        portsPopoverPresented.toggle()
                    } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                    .help("The block's port nets: add, rename, set direction")
                }
                .popover(isPresented: $portsPopoverPresented, arrowEdge: .trailing) {
                    HorizontalPortNetsPopover(nets: portNets, isReadOnly: isReadOnly, onCommand: onPortNetCommand)
                }
                PlacePinToolButton {
                    canvasActions?.dispatch(.placePin)
                }
                PlaceRefdesValueToolButton {
                    canvasActions?.dispatch(.placeRefdesAndValue)
                }
                ResizeSymbolToolButton {
                    canvasActions?.dispatch(.resizeSymbol)
                }
                .disabled(canvasActions?.canResizeSymbol != true)
            }
        }
        .onAppear {
            if sheet == nil {
                sheet = blockSymbol.makeSheet(poolURL: poolURL)
            }
        }
        .onChange(of: revision) { _, _ in
            reproject()
        }
        .onChange(of: blockSymbol) { _, newValue in
            guard newValue.sourceJSON != committedJSON else {
                return
            }
            reproject()
        }
    }

    private func reproject() {
        sheet = blockSymbol.makeSheet(poolURL: poolURL)
        syncRevision += 1
    }

    private func canvasChanged(_ edited: HorizontalSchematicSheet) {
        sheet = edited
        let updated = blockSymbol.applying(sheet: edited)
        committedJSON = HorizontalPreservedJSON(updated.json())
        onChange(updated)
    }
}
