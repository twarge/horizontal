import SwiftUI
import UniformTypeIdentifiers

/// The package editor's tools beyond the canvas: Horizon's renumber pads,
/// generate courtyard / silkscreen, footprint generator and DXF import, as
/// sidebar buttons with their settings sheets. A decal gets DXF import only.
struct HorizontalPackageToolsSection: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    var context: HorizontalPoolEditorContext
    /// The pads currently selected on the canvas (uuids), for renumbering.
    var selectedPadIDs: Set<String>
    var drawingLayer: Int
    var layers: [Int]
    var commit: (HorizontalPoolItemModel, String) -> Void

    @State private var renumberPresented = false
    @State private var silkscreenPresented = false
    @State private var footprintPresented = false
    @State private var dxfPresented = false
    @State private var dxfImporterPresented = false
    @State private var dxfSettings = HorizontalDXFImportSettings()
    @State private var toolMessage: String?

    private var package: HorizontalPoolPackage? {
        if case .package(let package) = session.model {
            return package
        }
        return nil
    }

    var body: some View {
        Divider()
        Text("Tools")
            .font(.headline)
        VStack(alignment: .leading, spacing: 8) {
            if let package {
                HStack {
                    Button("Renumber Pads…") {
                        renumberPresented = true
                    }
                    .disabled(package.pads.count < 2)
                    Button("Generate Courtyard") {
                        generateCourtyard(package)
                    }
                    .disabled(package.pads.isEmpty && package.drawing.polygons.isEmpty)
                }
                HStack {
                    Button("Generate Silkscreen…") {
                        silkscreenPresented = true
                    }
                    .disabled(!package.drawing.polygons.values.contains { $0.layer == HorizontalBoardLayers.topPackage })
                    Button("Footprint Generator…") {
                        footprintPresented = true
                    }
                }
            }
            Button("Import DXF…") {
                dxfSettings.layer = drawingLayer
                dxfPresented = true
            }
            if let toolMessage {
                Text(toolMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isReadOnly)
        .sheet(isPresented: $renumberPresented) {
            if let package {
                HorizontalRenumberPadsSheet(
                    package: package,
                    selectedPadIDs: selectedPadIDs,
                    onApply: { renumbered in
                        renumberPresented = false
                        commit(.package(renumbered), "Renumber Pads")
                    },
                    onCancel: { renumberPresented = false }
                )
            }
        }
        .sheet(isPresented: $silkscreenPresented) {
            HorizontalSilkscreenSettingsSheet(
                onApply: { settings in
                    silkscreenPresented = false
                    generateSilkscreen(settings)
                },
                onCancel: { silkscreenPresented = false }
            )
        }
        .sheet(isPresented: $footprintPresented) {
            HorizontalFootprintGeneratorSheet(
                choices: context.padstackChoices(),
                onGenerate: { settings in
                    footprintPresented = false
                    generateFootprint(settings)
                },
                onCancel: { footprintPresented = false }
            )
        }
        .sheet(isPresented: $dxfPresented) {
            HorizontalDXFImportSheet(
                settings: $dxfSettings,
                layers: layers,
                onChoose: {
                    dxfPresented = false
                    chooseDXF()
                },
                onCancel: { dxfPresented = false }
            )
        }
        #if os(iOS)
        .fileImporter(isPresented: $dxfImporterPresented, allowedContentTypes: [UTType(filenameExtension: "dxf") ?? .data]) { result in
            if case .success(let url) = result {
                importDXF(from: url)
            }
        }
        #endif
    }

    private func generateCourtyard(_ package: HorizontalPoolPackage) {
        guard let generated = package.generatingCourtyard(context: context) else {
            toolMessage = "Nothing to enclose: place pads or a package outline first."
            return
        }
        toolMessage = package.drawing.polygons.values.contains { $0.layer == HorizontalBoardLayers.topCourtyard }
            ? "Modified the existing courtyard polygon."
            : "Created a courtyard polygon."
        commit(.package(generated), "Generate Courtyard")
    }

    private func generateSilkscreen(_ settings: HorizontalSilkscreenSettings) {
        guard let package, let generated = package.generatingSilkscreen(context: context, settings: settings) else {
            toolMessage = "Silkscreen needs a polygon on the package layer that can be expanded."
            return
        }
        toolMessage = "Silkscreen regenerated."
        commit(.package(generated), "Generate Silkscreen")
    }

    private func generateFootprint(_ settings: HorizontalFootprintGeneratorSettings) {
        guard let package else {
            return
        }
        let generated = package.appendingGeneratedPads(settings: settings, padstackJSON: context.padstackJSON(id: settings.padstackID))
        toolMessage = "Added \(generated.pads.count - package.pads.count) pads."
        commit(.package(generated), "Generate Footprint")
    }

    private func chooseDXF() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        panel.message = "Choose a DXF file to import onto the \(HorizontalBoardLayers.name(for: dxfSettings.layer)) layer."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            importDXF(from: url)
        }
        #else
        dxfImporterPresented = true
        #endif
    }

    private func importDXF(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            toolMessage = "The DXF file could not be read."
            return
        }
        let imported = HorizontalDXFImporter.parse(text, scale: dxfSettings.scale)
        guard !imported.isEmpty else {
            toolMessage = "No lines, arcs or polylines were found in the DXF."
            return
        }
        switch session.model {
        case .package(var package):
            package.drawing = package.drawing.adding(imported, layer: dxfSettings.layer, width: dxfSettings.lineWidth)
            commit(.package(package), "Import DXF")
        case .decal(var decal):
            decal.drawing = decal.drawing.adding(imported, layer: dxfSettings.layer, width: dxfSettings.lineWidth)
            commit(.decal(decal), "Import DXF")
        default:
            return
        }
        toolMessage = "Imported \(imported.lines.count) lines and \(imported.arcs.count) arcs."
    }
}

struct HorizontalDXFImportSettings: Hashable {
    var layer = HorizontalBoardLayers.topSilkscreen
    var lineWidth = 150_000.0
    /// Nanometres per drawing unit: 1 mm by default.
    var scale = 1_000_000.0
}

struct HorizontalDXFImportSheet: View {
    @Binding var settings: HorizontalDXFImportSettings
    var layers: [Int]
    var onChoose: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import DXF")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Layer").gridColumnAlignment(.trailing)
                    Picker("Layer", selection: $settings.layer) {
                        ForEach(layers, id: \.self) { layer in
                            Text(HorizontalBoardLayers.name(for: layer)).tag(layer)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Line width").gridColumnAlignment(.trailing)
                    HorizontalLengthField(nanometres: $settings.lineWidth)
                }
                GridRow {
                    Text("Drawing unit").gridColumnAlignment(.trailing)
                    Picker("Drawing unit", selection: $settings.scale) {
                        Text("Millimetres").tag(1_000_000.0)
                        Text("Inches").tag(25_400_000.0)
                        Text("Mils").tag(25_400.0)
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Choose File…", action: onChoose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}

/// A millimetre text field bound to a nanometre value.
struct HorizontalLengthField: View {
    @Binding var nanometres: Double

    var body: some View {
        HStack(spacing: 4) {
            HorizontalCommittedTextField(
                text: HorizontalPoolItemHeaderForm.millimetres(nanometres),
                isReadOnly: false
            ) { value in
                if let parsed = HorizontalPoolItemHeaderForm.nanometres(fromMillimetres: value) {
                    nanometres = parsed
                }
            }
            .frame(minWidth: 70)
            Text("mm")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Renumber pads

struct HorizontalRenumberPadsSheet: View {
    var package: HorizontalPoolPackage
    var selectedPadIDs: Set<String>
    var onApply: (HorizontalPoolPackage) -> Void
    var onCancel: () -> Void

    @State private var settings = HorizontalRenumberPadsSettings()

    /// Upstream renumbers the selected pads; with fewer than two selected,
    /// every pad.
    private var padIDs: Set<String>? {
        selectedPadIDs.count >= 2 ? Set(selectedPadIDs.map { $0.lowercased() }) : nil
    }

    private var preview: [HorizontalPad] {
        let chosen = package.sortedPads.filter { pad in padIDs.map { $0.contains(pad.id.lowercased()) } ?? true }
        return HorizontalPoolPackage.renumberOrder(of: chosen, settings: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(padIDs == nil ? "Renumber All Pads" : "Renumber \(selectedPadIDs.count) Selected Pads")
                .font(.headline)
            Picker("Order", selection: $settings.circular) {
                Text("Axis").tag(false)
                Text("Circular").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                if settings.circular {
                    GridRow {
                        Text("Origin").gridColumnAlignment(.trailing)
                        Picker("Origin", selection: $settings.origin) {
                            ForEach(HorizontalRenumberPadsSettings.Origin.allCases, id: \.self) { origin in
                                Text(origin.displayName).tag(origin)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Direction").gridColumnAlignment(.trailing)
                        Picker("Direction", selection: $settings.clockwise) {
                            Text("Clockwise").tag(true)
                            Text("Counter-clockwise").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } else {
                    GridRow {
                        Text("Priority").gridColumnAlignment(.trailing)
                        Picker("Priority", selection: $settings.xFirst) {
                            Text("Rows (x first)").tag(true)
                            Text("Columns (y first)").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Horizontal").gridColumnAlignment(.trailing)
                        Picker("Horizontal", selection: $settings.right) {
                            Text("Left to right").tag(true)
                            Text("Right to left").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Vertical").gridColumnAlignment(.trailing)
                        Picker("Vertical", selection: $settings.down) {
                            Text("Top to bottom").tag(true)
                            Text("Bottom to top").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text("Prefix").gridColumnAlignment(.trailing)
                    TextField("Prefix", text: $settings.prefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }
                GridRow {
                    Text("Start").gridColumnAlignment(.trailing)
                    Stepper(value: $settings.start, in: 1...1000) {
                        Text("\(settings.start)")
                    }
                }
                GridRow {
                    Text("Step").gridColumnAlignment(.trailing)
                    Stepper(value: $settings.step, in: 1...10) {
                        Text("\(settings.step)")
                    }
                }
            }
            Text("Result: " + preview.enumerated().map { index, pad in
                "\(pad.name) → \(settings.prefix)\(settings.start + index * settings.step)"
            }.prefix(12).joined(separator: ", ") + (preview.count > 12 ? ", …" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Renumber") {
                    onApply(package.renumberingPads(ids: padIDs, settings: settings))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

// MARK: - Silkscreen

struct HorizontalSilkscreenSettingsSheet: View {
    var onApply: (HorizontalSilkscreenSettings) -> Void
    var onCancel: () -> Void

    @State private var settings = HorizontalSilkscreenSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate Silkscreen")
                .font(.headline)
            Text("The package outline is expanded and drawn as silkscreen, with the stretches over pads left out. Existing silkscreen lines are replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Expand outline").gridColumnAlignment(.trailing)
                    HorizontalLengthField(nanometres: $settings.expandSilk)
                }
                GridRow {
                    Text("Pad clearance").gridColumnAlignment(.trailing)
                    HorizontalLengthField(nanometres: $settings.expandPad)
                }
                GridRow {
                    Text("Line width").gridColumnAlignment(.trailing)
                    HorizontalLengthField(nanometres: $settings.lineWidth)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    onApply(settings)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}

// MARK: - Footprint generator

struct HorizontalFootprintGeneratorSheet: View {
    var choices: [HorizontalPoolPadstackInfo]
    var onGenerate: (HorizontalFootprintGeneratorSettings) -> Void
    var onCancel: () -> Void

    @State private var settings = HorizontalFootprintGeneratorSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Footprint Generator")
                .font(.headline)
            Picker("Arrangement", selection: $settings.mode) {
                ForEach(HorizontalFootprintGeneratorSettings.Mode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Padstack").gridColumnAlignment(.trailing)
                    Picker("Padstack", selection: $settings.padstackID) {
                        Text("Choose…").tag("")
                        ForEach(choices) { choice in
                            Text(choice.isPackageLocal ? "\(choice.name) (package)" : choice.name).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                }
                switch settings.mode {
                case .single:
                    countRow("Pads", $settings.padCount, 1...512)
                    lengthRow("Pitch", $settings.pitch)
                case .dual:
                    countRow("Pads (total)", $settings.padCount, 2...512, step: 2)
                    lengthRow("Pitch", $settings.pitch)
                    lengthRow("Row spacing (half)", $settings.spacing)
                    GridRow {
                        Text("")
                        Toggle("Zigzag numbering", isOn: $settings.zigzag)
                    }
                case .quad:
                    countRow("Pads per vertical side", $settings.padCountV, 1...256)
                    countRow("Pads per horizontal side", $settings.padCountH, 1...256)
                    lengthRow("Pitch", $settings.pitch)
                    lengthRow("Vertical sides spacing (half)", $settings.spacing)
                    lengthRow("Horizontal sides spacing (half)", $settings.spacingV)
                case .grid:
                    countRow("Columns", $settings.padCountH, 1...64)
                    countRow("Rows", $settings.padCountV, 1...64)
                    lengthRow("Horizontal pitch", $settings.pitch)
                    lengthRow("Vertical pitch", $settings.pitchV)
                }
                lengthRow("Pad width", $settings.padWidth)
                lengthRow("Pad height", $settings.padHeight)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    onGenerate(settings)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.padstackID.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    private func countRow(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, step: Int = 1) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
            }
        }
    }

    private func lengthRow(_ label: String, _ value: Binding<Double>) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            HorizontalLengthField(nanometres: value)
        }
    }
}

// MARK: - 3D models

/// Horizon's model editor for a package: each model's file, placement and
/// heights, the default model, add and remove.
struct HorizontalPackageModelsSection: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    var commit: (HorizontalPoolItemModel, String) -> Void

    @State private var addError: String?
    #if os(iOS)
    @State private var newModelPath = ""
    #endif

    private var package: HorizontalPoolPackage? {
        if case .package(let package) = session.model {
            return package
        }
        return nil
    }

    var body: some View {
        if let package {
            Divider()
            HStack {
                Text("3D Models")
                    .font(.headline)
                Spacer()
                #if os(macOS)
                Button("Add Model…") {
                    chooseModel(package)
                }
                .disabled(isReadOnly)
                #endif
            }
            #if os(iOS)
            HStack {
                TextField("3d_models/part.step", text: $newModelPath)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    addModel(filename: newModelPath, to: package)
                    newModelPath = ""
                }
                .disabled(isReadOnly || newModelPath.isEmpty)
            }
            #endif
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let models = package.models.values.sorted { $0.filename < $1.filename }
            ForEach(models) { model in
                modelRow(model, in: package)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: HorizontalPackageModel3D, in package: HorizontalPoolPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Toggle("Default", isOn: Binding(
                    get: { package.defaultModelID == model.id },
                    set: { isDefault in
                        guard isDefault else {
                            return
                        }
                        update(package, "Change Default Model") { $0.defaultModelID = model.id }
                    }
                ))
                .poolFlagToggleStyle()
                Button {
                    update(package, "Remove Model") { edited in
                        edited.models.removeValue(forKey: model.id)
                        if edited.defaultModelID == model.id {
                            edited.defaultModelID = edited.models.keys.sorted().first ?? ""
                        }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this model")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text("Offset").gridColumnAlignment(.trailing)
                    lengthField(model.x, onCommit: update(package, "Move Model") { $0.models[model.id]?.x = $1 })
                    lengthField(model.y, onCommit: update(package, "Move Model") { $0.models[model.id]?.y = $1 })
                    lengthField(model.z, onCommit: update(package, "Move Model") { $0.models[model.id]?.z = $1 })
                }
                GridRow {
                    Text("Rotation").gridColumnAlignment(.trailing)
                    angleField(model.roll, onCommit: update(package, "Rotate Model") { $0.models[model.id]?.roll = $1 })
                    angleField(model.pitch, onCommit: update(package, "Rotate Model") { $0.models[model.id]?.pitch = $1 })
                    angleField(model.yaw, onCommit: update(package, "Rotate Model") { $0.models[model.id]?.yaw = $1 })
                }
                GridRow {
                    Text("Height").gridColumnAlignment(.trailing)
                    lengthField(model.heightTop, onCommit: update(package, "Change Model Height") { $0.models[model.id]?.heightTop = $1 })
                    lengthField(model.heightBottom, onCommit: update(package, "Change Model Height") { $0.models[model.id]?.heightBottom = $1 })
                    Text("top / bottom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .disabled(isReadOnly)
    }

    private func lengthField(_ nanometres: Double, onCommit: @escaping (Double) -> Void) -> some View {
        HorizontalCommittedTextField(text: HorizontalPoolItemHeaderForm.millimetres(nanometres), isReadOnly: isReadOnly) { value in
            if let parsed = HorizontalPoolItemHeaderForm.nanometres(fromMillimetres: value) {
                onCommit(parsed)
            }
        }
        .frame(width: 64)
    }

    private func angleField(_ angle: Int, onCommit: @escaping (Int) -> Void) -> some View {
        HorizontalCommittedTextField(text: String(format: "%.1f", Double(angle) * 360 / 65_536), isReadOnly: isReadOnly) { value in
            if let degrees = Double(value.replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces)) {
                onCommit(Int((degrees / 360 * 65_536).rounded()))
            }
        }
        .frame(width: 64)
    }

    private func update(_ package: HorizontalPoolPackage, _ actionName: String, _ change: (inout HorizontalPoolPackage) -> Void) {
        var edited = package
        change(&edited)
        commit(.package(edited), actionName)
    }

    private func update(_ package: HorizontalPoolPackage, _ actionName: String, _ change: @escaping (inout HorizontalPoolPackage, Double) -> Void) -> (Double) -> Void {
        { value in
            var edited = package
            change(&edited, value)
            commit(.package(edited), actionName)
        }
    }

    private func update(_ package: HorizontalPoolPackage, _ actionName: String, _ change: @escaping (inout HorizontalPoolPackage, Int) -> Void) -> (Int) -> Void {
        { value in
            var edited = package
            change(&edited, value)
            commit(.package(edited), actionName)
        }
    }

    /// Models are referenced by a path relative to the pool, as upstream
    /// stores them (`3d_models/…`).
    private func addModel(filename: String, to package: HorizontalPoolPackage) {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let id = UUID().uuidString.lowercased()
        update(package, "Add Model") { edited in
            edited.models[id] = HorizontalPackageModel3D(id: id, filename: trimmed)
            if edited.defaultModelID.isEmpty || edited.models[edited.defaultModelID] == nil {
                edited.defaultModelID = id
            }
        }
        addError = nil
    }

    #if os(macOS)
    private func chooseModel(_ package: HorizontalPoolPackage) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.poolURL.appendingPathComponent("3d_models", isDirectory: true)
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data, UTType(filenameExtension: "stp") ?? .data]
        panel.message = "Choose a STEP model inside the pool folder “\(session.poolURL.lastPathComponent)”."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            guard let relative = HorizontalPoolItemFactory.relativePath(of: url, within: session.poolURL) else {
                addError = "The model must live inside the pool folder so the pool stays portable."
                return
            }
            addModel(filename: relative, to: package)
        }
    }
    #endif
}
