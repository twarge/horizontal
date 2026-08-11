import SwiftUI

struct HorizontalExportSidebarView: View {
    var project: HorizontalProject
    @Binding var settings: HorizontalExportSettings
    var status: HorizontalExportStatus?
    /// True while an export is running — drives the spinner next to "Export All".
    var isExporting = false
    var safeAreaInsets: EdgeInsets
    /// macOS uses this view standalone in its workspace sidebar, so it paints its own
    /// material + edge. Inside the iOS slide-over the container provides those, so the
    /// caller passes `false` to avoid doubling them up.
    var providesChrome = true
    var onExport: (HorizontalExportSection) -> Void
    var onExportAll: () -> Void

    // Disclosure state, independent of each section's enabled flag (so a section can be
    // collapsed while enabled, or expanded to preview while disabled). Sections start
    // expanded when enabled, and enabling one opens it to reveal its options.
    @State private var expandedSections: Set<HorizontalExportSection> = []
    @State private var didInitExpansion = false

    var body: some View {
        List {
            Section("Export") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            onExportAll()
                        } label: {
                            Label("Export All", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!canExportAll || isExporting)

                        exportStatusIndicator

                        Spacer(minLength: 0)
                    }

                    // On iOS the export goes to a throwaway temp folder and the user
                    // picks the real destination via the document picker, so a
                    // directory field would be meaningless (and uneditable in the
                    // sandbox). macOS exports straight to this on-disk path.
                    #if os(macOS)
                    TextField("Export Directory", text: $settings.targetDirectory)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .font(.body)

                    if let targetDirectoryError {
                        Label(targetDirectoryError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    #endif
                }
                .padding(.vertical, 4)
            }

            exportSection(.schematicPDF, isEnabled: $settings.schematicPDF.enabled) {
                TextField("File name", text: $settings.schematicPDF.filename)
                dimensionField("Min. line width", value: $settings.schematicPDF.minimumLineWidthMM)
            }

            exportSection(.bom, isEnabled: $settings.bom.enabled) {
                TextField("File name", text: $settings.bom.filename)
                Picker("Sort column", selection: $settings.bom.sortColumn) {
                    ForEach(HorizontalBOMColumn.allCases) { column in
                        Text(column.title).tag(column)
                    }
                }
                Picker("Sort order", selection: $settings.bom.sortOrder) {
                    ForEach(HorizontalExportSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                Toggle("Include \"do not populate\" components", isOn: $settings.bom.includeNoPopulate)
                Toggle("Customize format", isOn: $settings.bom.customizeFormat)
                columnChecklist(
                    title: "Columns",
                    columns: HorizontalBOMColumn.allCases,
                    selection: $settings.bom.columns
                ) { $0.title }
            }

            exportSection(.gerber, isEnabled: $settings.gerber.enabled) {
                TextField("Base filename", text: $settings.gerber.prefix)
                Toggle("Generate Zip", isOn: $settings.gerber.zipOutput)
                Toggle("Keep only Zip archive", isOn: $settings.gerber.removeIndividualFilesAfterZip)
                    .disabled(!settings.gerber.zipOutput)
                Picker("Drill mode", selection: $settings.gerber.drillMode) {
                    ForEach(HorizontalGerberDrillMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                TextField(settings.gerber.drillMode == .individual ? "PTH suffix" : "Drill suffix", text: $settings.gerber.drillPTHSuffix)
                if settings.gerber.drillMode == .individual {
                    TextField("NPTH suffix", text: $settings.gerber.drillNPTHSuffix)
                }
                dimensionField("Outline width", value: $settings.gerber.outlineWidthMM)
                layerSuffixList(layers: $settings.gerber.layers)
            }

            exportSection(.odb, isEnabled: $settings.odb.enabled) {
                Picker("Format", selection: $settings.odb.format) {
                    ForEach(HorizontalODBExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                if settings.odb.format == .directory {
                    TextField("Directory", text: $settings.odb.directoryName)
                } else {
                    TextField("Filename", text: $settings.odb.filename)
                }
                TextField("Job name", text: $settings.odb.jobName)
                Text("Leave blank to use project name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            exportSection(.pickAndPlace, isEnabled: $settings.pickAndPlace.enabled) {
                Picker("Mode", selection: $settings.pickAndPlace.mode) {
                    ForEach(HorizontalPnPExportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if settings.pickAndPlace.mode == .merged {
                    TextField("Filename", text: $settings.pickAndPlace.filenameMerged)
                } else {
                    TextField("Top filename", text: $settings.pickAndPlace.filenameTop)
                    TextField("Bottom filename", text: $settings.pickAndPlace.filenameBottom)
                }
                Toggle("Include \"do not populate\" components", isOn: $settings.pickAndPlace.includeNoPopulate)
                Toggle("Customize format", isOn: $settings.pickAndPlace.customizeFormat)
                TextField("Position format", text: $settings.pickAndPlace.positionFormat)
                TextField("Top side", text: $settings.pickAndPlace.topSide)
                TextField("Bottom side", text: $settings.pickAndPlace.bottomSide)
                columnChecklist(
                    title: "Columns",
                    columns: HorizontalPnPColumn.allCases,
                    selection: $settings.pickAndPlace.columns
                ) { $0.title }
            }

            exportSection(.boardSTEP, isEnabled: $settings.boardSTEP.enabled) {
                TextField("File name", text: $settings.boardSTEP.filename)
                Toggle("Include 3D Models", isOn: $settings.boardSTEP.include3DModels)
                TextField("Label prefix", text: $settings.boardSTEP.labelPrefix)
                dimensionField("Minimum hole/via diameter", value: $settings.boardSTEP.minimumHoleDiameterMM)
            }

            exportSection(.boardDrawing, isEnabled: $settings.boardDrawing.enabled) {
                TextField("File name", text: $settings.boardDrawing.filename)
                dimensionField("Min. line width", value: $settings.boardDrawing.minimumLineWidthMM)
                Toggle("Reverse layers", isOn: $settings.boardDrawing.reverseLayers)
                Toggle("Mirrored", isOn: $settings.boardDrawing.mirrored)
                Toggle("Specify holes size", isOn: $settings.boardDrawing.useSpecifiedHoleDiameter)
                dimensionField("Holes diameter", value: $settings.boardDrawing.holeDiameterMM)
                    .disabled(!settings.boardDrawing.useSpecifiedHoleDiameter)
                pdfLayerList(layers: $settings.boardDrawing.layers)
            }

            exportSection(.boardDXF, isEnabled: $settings.boardDXF.enabled) {
                TextField("File name", text: $settings.boardDXF.filename)
                dimensionField("Min. line width", value: $settings.boardDXF.minimumLineWidthMM)
                Toggle("Include holes", isOn: $settings.boardDXF.includeHoles)
                Toggle("Include dimensions", isOn: $settings.boardDXF.includeDimensions)
                dxfLayerList(layers: $settings.boardDXF.layers)
            }

        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .onAppear {
            guard !didInitExpansion else { return }
            didInitExpansion = true
            expandedSections = Set(HorizontalExportSection.allCases.filter { settings.isEnabled($0) })
        }
        .padding(.top, providesChrome ? safeAreaInsets.top : 0)
        .background {
            if providesChrome {
                Rectangle().fill(.regularMaterial)
            }
        }
        .overlay(alignment: .leading) {
            if providesChrome {
                Rectangle()
                    .fill(.primary.opacity(0.1))
                    .frame(width: 0.7)
            }
        }
    }

    private var canExportAll: Bool {
        HorizontalExportSection.allCases.contains { settings.isEnabled($0) }
    }

    /// The single status line shown to the right of "Export All": a spinner while
    /// exporting, then a green check + "Export complete" (or the error) when done.
    @ViewBuilder
    private var exportStatusIndicator: some View {
        if isExporting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let status {
            HStack(spacing: 6) {
                Image(systemName: statusIcon(for: status.kind))
                    .foregroundStyle(statusColor(for: status.kind))
                Text(status.kind == .success ? "Export complete" : status.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private var targetDirectoryError: String? {
        do {
            _ = try HorizontalExportSettings.exportTargetDirectory(
                for: project,
                requestedPath: settings.targetDirectory
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @ViewBuilder
    private func exportSection<Content: View>(
        _ section: HorizontalExportSection,
        isEnabled: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Section {
            DisclosureGroup(isExpanded: expansionBinding(for: section)) {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                    Button {
                        onExport(section)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!isEnabled.wrappedValue || isExporting)
                    .padding(.top, 2)
                }
                .textFieldStyle(.roundedBorder)
                .pickerStyle(.menu)
                .disabled(!isEnabled.wrappedValue)
                .opacity(isEnabled.wrappedValue ? 1 : 0.55)
                .padding(.vertical, 6)
            } label: {
                Toggle(isOn: enableBinding(section, isEnabled)) {
                    Label(section.title, systemImage: section.symbolName)
                }
                .checkboxToggleStyle()
            }
        }
    }

    private func expansionBinding(for section: HorizontalExportSection) -> Binding<Bool> {
        Binding {
            expandedSections.contains(section)
        } set: { expanded in
            if expanded {
                expandedSections.insert(section)
            } else {
                expandedSections.remove(section)
            }
        }
    }

    /// Enabling a section also opens it so its options are immediately visible.
    private func enableBinding(_ section: HorizontalExportSection, _ isEnabled: Binding<Bool>) -> Binding<Bool> {
        Binding {
            isEnabled.wrappedValue
        } set: { enabled in
            isEnabled.wrappedValue = enabled
            if enabled {
                expandedSections.insert(section)
            }
        }
    }

    private func dimensionField(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text("mm")
                .foregroundStyle(.secondary)
        }
    }

    private func columnChecklist<Column: Identifiable & Hashable>(
        title: String,
        columns: [Column],
        selection: Binding<Set<Column>>,
        label: @escaping (Column) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(columns) { column in
                Toggle(label(column), isOn: setMembershipBinding(column, in: selection))
            }
        }
    }

    private func layerSuffixList(layers: Binding<[HorizontalExportLayerSetting]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gerber Layers")
                .font(.subheadline.weight(.semibold))
            ForEach(layers) { $layer in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(layer.name, isOn: $layer.enabled)
                    TextField("Suffix", text: $layer.filename)
                        .disabled(!layer.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func pdfLayerList(layers: Binding<[HorizontalExportLayerSetting]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layers")
                .font(.subheadline.weight(.semibold))
            ForEach(layers) { $layer in
                HStack(spacing: 8) {
                    Toggle(layer.name, isOn: $layer.enabled)
                    Text("-")
                        .foregroundStyle(.secondary)
                    Toggle("Fill", isOn: fillModeBinding($layer.mode))
                        .checkboxToggleStyle()
                    .disabled(!layer.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func dxfLayerList(layers: Binding<[HorizontalExportLayerSetting]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layers")
                .font(.subheadline.weight(.semibold))
            ForEach(layers) { $layer in
                HStack(spacing: 8) {
                    Text(layer.name)
                        .lineLimit(1)
                    Text("-")
                        .foregroundStyle(.secondary)
                    Toggle("Fill", isOn: fillModeBinding($layer.mode))
                        .checkboxToggleStyle()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func setMembershipBinding<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
        Binding {
            set.wrappedValue.contains(value)
        } set: { isMember in
            if isMember {
                set.wrappedValue.insert(value)
            } else {
                set.wrappedValue.remove(value)
            }
        }
    }

    private func fillModeBinding(_ mode: Binding<HorizontalPDFLayerMode>) -> Binding<Bool> {
        Binding {
            mode.wrappedValue == .fill
        } set: { isFilled in
            mode.wrappedValue = isFilled ? .fill : .outline
        }
    }

    private func statusIcon(for kind: HorizontalExportStatus.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func statusColor(for kind: HorizontalExportStatus.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private extension View {
    /// Applies the macOS `.checkbox` toggle style. The checkbox style is
    /// unavailable on iOS, so this is a no-op there (the default toggle
    /// style is used instead), keeping macOS behavior byte-identical.
    @ViewBuilder
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
