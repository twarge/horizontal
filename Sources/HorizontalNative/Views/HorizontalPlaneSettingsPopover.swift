import SwiftUI

/// Horizon's plane dialog as a popover on the polygon: the net and fill
/// order, whether the pour follows the rules, and — when it does not —
/// every pour setting Horizon's plane editor offers.
struct HorizontalPlaneSettingsPopover: View {
    var title: String
    var confirmTitle: String
    var nets: [HorizontalSelectionPropertyOption]
    var layerName: String?
    var canDelete: Bool
    var onConfirm: (HorizontalPlaneEditorDraft) -> Void
    var onDelete: (() -> Void)?
    var onCancel: () -> Void

    @State private var draft: HorizontalPlaneEditorDraft

    init(
        title: String,
        confirmTitle: String,
        nets: [HorizontalSelectionPropertyOption],
        layerName: String?,
        draft: HorizontalPlaneEditorDraft,
        canDelete: Bool = false,
        onConfirm: @escaping (HorizontalPlaneEditorDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.nets = nets
        self.layerName = layerName
        self.canDelete = canDelete
        self.onConfirm = onConfirm
        self.onDelete = onDelete
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    private static let nanometersPerMillimeter = 1_000_000.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Net")
                    if nets.isEmpty {
                        Text("No nets on the board")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Net", selection: netSelection) {
                            ForEach(nets) { net in
                                Text(net.title).tag(net.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let layerName {
                    GridRow {
                        Text("Layer")
                        Text(layerName)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Fill order")
                    HStack(spacing: 6) {
                        TextField("0", value: $draft.priority, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Stepper("", value: $draft.priority, in: 0...100)
                            .labelsHidden()
                        Text("lower pours first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("From rules")
                    Toggle("", isOn: $draft.fromRules)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Minimum width")
                    millimeters($draft.settings.minWidth)
                }
                GridRow {
                    Text("Keep orphans")
                    HStack(spacing: 8) {
                        Toggle("", isOn: $draft.settings.keepOrphans)
                            .labelsHidden()
                            .toggleStyle(.switch)
                        Text("Fill that touches no copper on the net is dropped unless kept")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text("Style")
                    Picker("Style", selection: $draft.settings.style) {
                        Text("Round").tag(HorizontalPlaneSettings.Style.round)
                        Text("Bevel").tag(HorizontalPlaneSettings.Style.square)
                        Text("Sharp").tag(HorizontalPlaneSettings.Style.miter)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("Text style")
                    Picker("Text style", selection: $draft.settings.textStyle) {
                        Text("Expand").tag(HorizontalPlaneSettings.TextStyle.expand)
                        Text("Bounding box").tag(HorizontalPlaneSettings.TextStyle.bbox)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("Connect style")
                    Picker("Connect style", selection: connectStyle) {
                        Text("Solid").tag(HorizontalThermalSettings.ConnectStyle.solid)
                        Text("Thermal relief").tag(HorizontalThermalSettings.ConnectStyle.thermal)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("Thermal gap width")
                    millimeters($draft.settings.thermalSettings.thermalGapWidth)
                }
                GridRow {
                    Text("Thermal spoke width")
                    millimeters($draft.settings.thermalSettings.thermalSpokeWidth)
                }
                GridRow {
                    Text("Number of spokes")
                    HStack(spacing: 6) {
                        TextField("4", value: $draft.settings.thermalSettings.nSpokes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Stepper("", value: $draft.settings.thermalSettings.nSpokes, in: 1...8)
                            .labelsHidden()
                    }
                }
                GridRow {
                    Text("Thermal spoke angle")
                    HStack(spacing: 6) {
                        TextField("0", value: spokeAngleDegrees, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("°")
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Fill")
                    Picker("Fill", selection: $draft.settings.fillStyle) {
                        Text("Solid").tag(HorizontalPlaneSettings.FillStyle.solid)
                        Text("Hatch").tag(HorizontalPlaneSettings.FillStyle.hatch)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if draft.settings.fillStyle == .hatch {
                    GridRow {
                        Text("Hatch border width")
                        millimeters($draft.settings.hatchBorderWidth)
                    }
                    GridRow {
                        Text("Hatch line width")
                        millimeters($draft.settings.hatchLineWidth)
                    }
                    GridRow {
                        Text("Hatch line spacing")
                        millimeters($draft.settings.hatchLineSpacing)
                    }
                }
            }
            .disabled(draft.fromRules)
            .opacity(draft.fromRules ? 0.55 : 1)

            HStack {
                if canDelete, let onDelete {
                    Button("Delete Plane", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.netID == nil)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private var netSelection: Binding<String> {
        Binding(
            get: { draft.netID ?? nets.first?.id ?? "" },
            set: { draft.netID = $0 }
        )
    }

    /// The plane editor offers solid or thermal; a plane read back with one
    /// of the other spellings shows as thermal until changed.
    private var connectStyle: Binding<HorizontalThermalSettings.ConnectStyle> {
        Binding(
            get: { draft.settings.thermalSettings.connectStyle == .solid ? .solid : .thermal },
            set: { draft.settings.thermalSettings.connectStyle = $0 }
        )
    }

    /// Horizon stores the spoke angle in its 1/65536-turn units.
    private var spokeAngleDegrees: Binding<Double> {
        Binding(
            get: { Double(draft.settings.thermalSettings.angle) * 360 / 65_536 },
            set: { draft.settings.thermalSettings.angle = Int(($0 / 360 * 65_536).rounded()) }
        )
    }

    private func millimeters(_ nanometers: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField(
                "0",
                value: Binding(
                    get: { Double(nanometers.wrappedValue) / Self.nanometersPerMillimeter },
                    set: { nanometers.wrappedValue = Int((max($0, 0) * Self.nanometersPerMillimeter).rounded()) }
                ),
                format: .number.precision(.fractionLength(0...3))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            Text("mm")
                .foregroundStyle(.secondary)
        }
    }
}
