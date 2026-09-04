import SwiftUI

/// What the part editor needs from the rest of the pool: the entity's gates
/// and their units' pins, the package's pads (mechanical ones left out, as
/// upstream drops them from the pad map), the package's 3D models, and, for
/// a derived part, everything its base chain resolves to.
struct HorizontalPartEditorContext: Equatable, Sendable {
    struct Pin: Identifiable, Hashable, Sendable {
        var gateID: String
        var gateName: String
        var pinID: String
        var pinName: String

        var id: String { gateID + "/" + pinID }
        var displayName: String { gateName + "." + pinName }
    }

    struct Pad: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
    }

    struct Model3D: Identifiable, Hashable, Sendable {
        var id: String
        var filename: String
    }

    var entityID: String?
    var packageID: String?
    var entityName: String?
    var packageName: String?
    var baseName: String?
    var pins: [Pin] = []
    var pads: [Pad] = []
    var models: [Model3D] = []
    var defaultModelID: String?
    /// Resolved through the base chain, for inherited attributes and for
    /// materialising them when the base is cleared.
    var baseAttributes: [HorizontalPartAttributeKind: String] = [:]
    var baseTags: [String] = []
    var baseModelID: String?
    var basePadMap: [String: HorizontalPartPadMapEntry] = [:]
    var baseOverridePrefix: HorizontalPartOverridePrefix = .no
    var basePrefix = ""

    /// Loads everything from the index (disk reads; call off the main actor).
    static func load(
        entityID: String?,
        packageID: String?,
        baseID: String?,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPartEditorContext {
        var context = HorizontalPartEditorContext()
        var resolvedEntityID = entityID
        var resolvedPackageID = packageID

        // Walk the base chain (bounded, like the preview builder).
        var baseCursor = baseID
        var depth = 0
        var seenBase = false
        while let current = baseCursor, depth < 8, let json = index.json(.part, uuid: current),
              let base = try? HorizontalPoolPartItem(json: json) {
            if !seenBase {
                context.baseName = index.name(.part, uuid: current) ?? base.name
                seenBase = true
            }
            for kind in HorizontalPartAttributeKind.allCases where context.baseAttributes[kind] == nil {
                let attribute = base.attribute(kind)
                if !attribute.inherited || base.baseID == nil {
                    context.baseAttributes[kind] = attribute.value
                }
            }
            if context.baseTags.isEmpty || base.inheritTags {
                context.baseTags = Array(Set(context.baseTags + base.tags)).sorted()
            }
            if context.baseModelID == nil, !base.inheritModel || base.baseID == nil {
                context.baseModelID = base.modelID
            }
            if context.basePadMap.isEmpty, base.baseID == nil {
                context.basePadMap = base.padMap
            }
            if base.overridePrefix != .inherit || base.baseID == nil {
                if context.baseOverridePrefix == .no, context.basePrefix.isEmpty {
                    context.baseOverridePrefix = base.overridePrefix == .inherit ? .no : base.overridePrefix
                    context.basePrefix = base.prefix
                }
            }
            if base.baseID == nil {
                resolvedEntityID = base.entityID
                resolvedPackageID = base.packageID
            }
            baseCursor = base.baseID
            depth += 1
        }
        context.entityID = resolvedEntityID
        context.packageID = resolvedPackageID

        if let entityID = resolvedEntityID,
           let entityJSON = index.json(.entity, uuid: entityID),
           let entity = try? HorizontalPoolEntity(json: entityJSON) {
            context.entityName = entity.name
            var unitCache = [String: HorizontalPoolUnit]()
            for gate in entity.sortedGates {
                let unit: HorizontalPoolUnit?
                if let cached = unitCache[gate.unitID] {
                    unit = cached
                } else if let unitJSON = index.json(.unit, uuid: gate.unitID),
                          let loaded = try? HorizontalPoolUnit(json: unitJSON) {
                    unitCache[gate.unitID] = loaded
                    unit = loaded
                } else {
                    unit = nil
                }
                for pin in unit?.sortedPins ?? [] {
                    context.pins.append(Pin(gateID: gate.id, gateName: gate.name, pinID: pin.id, pinName: pin.primaryName))
                }
            }
        } else if let entityID = resolvedEntityID {
            context.entityName = index.name(.entity, uuid: entityID)
        }

        if let packageID = resolvedPackageID,
           let packageJSON = index.json(.package, uuid: packageID),
           let package = try? HorizontalPoolPackage(json: packageJSON) {
            context.packageName = package.name
            var padstackTypes = [String: String]()
            for pad in package.sortedPads {
                let key = pad.padstackID.lowercased()
                if padstackTypes[key] == nil {
                    let padstackJSON = index.json(.padstack, uuid: pad.padstackID)
                    padstackTypes[key] = padstackJSON?.string("padstack_type") ?? ""
                }
                if padstackTypes[key] != "mechanical" {
                    context.pads.append(Pad(id: pad.id, name: pad.name))
                }
            }
            context.models = package.models.values
                .sorted { $0.filename < $1.filename }
                .map { Model3D(id: $0.id, filename: $0.filename) }
            context.defaultModelID = package.defaultModelID.isEmpty ? nil : package.defaultModelID
        } else if let packageID = resolvedPackageID {
            context.packageName = index.name(.package, uuid: packageID)
        }
        return context
    }
}

/// Horizon's part editor: the five attributes with per-attribute
/// inheritance, entity/package/base references, tags, 3D model, orderable
/// MPNs, flags, prefix override, and the pin-to-pad map with Map, Unmap,
/// Automap and Copy from another part.
struct HorizontalPartEditorView: View {
    var part: HorizontalPoolPartItem
    var index: HorizontalPoolLibraryIndex
    var issues: [HorizontalPoolCheckIssue]
    var isReadOnly: Bool
    /// Where `tables.json` is looked for, the part's own pool last so it
    /// overrides the pools it includes.
    var poolURLs: [URL] = []
    var commit: (HorizontalPoolPartItem, String) -> Void

    @State private var parametricTables: [HorizontalParametricTable] = []

    @State private var context: HorizontalPartEditorContext?
    @State private var picker: HorizontalPoolItemPickerRequest?
    @State private var selectedPinIDs = Set<String>()
    @State private var selectedPadIDs = Set<String>()

    private struct LoadKey: Equatable {
        var entityID: String?
        var packageID: String?
        var baseID: String?
        var indexCount: Int
    }

    private var loadKey: LoadKey {
        LoadKey(entityID: part.entityID, packageID: part.packageID, baseID: part.baseID, indexCount: index.items(in: .part).count)
    }

    private var hasBase: Bool {
        part.baseID != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                attributesSection
                referencesSection
                HStack(alignment: .top, spacing: 32) {
                    tagsAndModelSection
                    flagsAndPrefixSection
                }
                orderableMPNsSection
                parametricSection
                HorizontalPoolItemChecksView(issues: issues + unmappedPinIssues)
                padMapSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: poolURLs.map(\.path).joined(separator: "|")) {
            let urls = poolURLs
            parametricTables = await Task.detached(priority: .utility) {
                HorizontalPoolParametricTables.load(poolURLs: urls)
            }.value
        }
        .task(id: loadKey) {
            let key = loadKey
            let index = index
            context = await Task.detached(priority: .userInitiated) {
                HorizontalPartEditorContext.load(
                    entityID: key.entityID,
                    packageID: key.packageID,
                    baseID: key.baseID,
                    index: index
                )
            }.value
        }
        .sheet(item: $picker) { request in
            HorizontalPoolItemPickerSheet(
                title: request.title,
                category: request.category,
                index: index,
                excludedUUIDs: request.excludedUUIDs,
                onPick: { item in
                    apply(request, item: item)
                    picker = nil
                },
                onCancel: { picker = nil }
            )
        }
    }

    // MARK: - Attributes

    private var attributesSection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(HorizontalPartAttributeKind.allCases, id: \.self) { kind in
                let attribute = part.attribute(kind)
                GridRow {
                    Text(kind.displayName)
                        .gridColumnAlignment(.trailing)
                    HorizontalCommittedTextField(
                        text: attribute.inherited ? (context?.baseAttributes[kind] ?? "") : attribute.value,
                        isReadOnly: isReadOnly || attribute.inherited
                    ) { value in
                        update("Change \(kind.displayName)") {
                            $0.attributes[kind] = HorizontalPartAttribute(inherited: false, value: value)
                        }
                    }
                    if hasBase {
                        Toggle("Inherit", isOn: Binding(
                            get: { attribute.inherited },
                            set: { inherited in
                                update("Change \(kind.displayName) Inheritance") {
                                    $0.attributes[kind] = HorizontalPartAttribute(
                                        inherited: inherited,
                                        value: inherited ? attribute.value : (context?.baseAttributes[kind] ?? attribute.value)
                                    )
                                }
                            }
                        ))
                        .disabled(isReadOnly)
                    }
                }
            }
        }
        .frame(maxWidth: 640)
    }

    // MARK: - References

    private var referencesSection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Entity").gridColumnAlignment(.trailing)
                Text(context?.entityName ?? part.entityID ?? "–")
                    .lineLimit(1)
                if !hasBase {
                    Button("Change…") {
                        picker = HorizontalPoolItemPickerRequest(purpose: .partEntity, category: .entity, title: "Entity")
                    }
                    .disabled(isReadOnly)
                }
            }
            GridRow {
                Text("Package").gridColumnAlignment(.trailing)
                Text(context?.packageName ?? part.packageID ?? "–")
                    .lineLimit(1)
                if !hasBase {
                    Button("Change…") {
                        picker = HorizontalPoolItemPickerRequest(purpose: .partPackage, category: .package, title: "Package")
                    }
                    .disabled(isReadOnly)
                }
            }
            GridRow {
                Text("Base part").gridColumnAlignment(.trailing)
                Text(context?.baseName ?? part.baseID ?? "None")
                    .lineLimit(1)
                    .foregroundStyle(hasBase ? .primary : .secondary)
                HStack {
                    Button(hasBase ? "Change…" : "Set…") {
                        picker = HorizontalPoolItemPickerRequest(
                            purpose: .partBase,
                            category: .part,
                            title: "Base Part",
                            excludedUUIDs: [part.uuid.lowercased()]
                        )
                    }
                    if hasBase {
                        Button("Clear", action: clearBase)
                    }
                }
                .disabled(isReadOnly)
            }
        }
    }

    // MARK: - Tags, model

    private var tagsAndModelSection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Tags").gridColumnAlignment(.trailing)
                HorizontalCommittedTextField(text: part.tags.joined(separator: " "), isReadOnly: isReadOnly) { value in
                    update("Change Tags") { $0.tags = HorizontalPoolItemHeaderForm.tags(from: value) }
                }
                .frame(minWidth: 200)
            }
            if hasBase {
                GridRow {
                    Text("")
                    Toggle("Inherit tags from base", isOn: Binding(
                        get: { part.inheritTags },
                        set: { value in update("Change Tag Inheritance") { $0.inheritTags = value } }
                    ))
                    .disabled(isReadOnly)
                }
            }
            GridRow {
                Text("3D model").gridColumnAlignment(.trailing)
                Picker("3D model", selection: Binding(
                    get: { effectiveModelID },
                    set: { value in
                        update("Change 3D Model") {
                            $0.modelID = value
                            $0.inheritModel = false
                        }
                    }
                )) {
                    ForEach(context?.models ?? []) { model in
                        Text(model.filename).tag(model.id)
                    }
                    if let current = effectiveModelID, !(context?.models.contains { $0.id == current } ?? false) {
                        Text(current == HorizontalPoolPartItem.nilModelID ? "None" : current).tag(current)
                    }
                }
                .labelsHidden()
                .disabled(isReadOnly || (hasBase && part.inheritModel))
            }
            if hasBase {
                GridRow {
                    Text("")
                    Toggle("Inherit model from base", isOn: Binding(
                        get: { part.inheritModel },
                        set: { value in update("Change Model Inheritance") { $0.inheritModel = value } }
                    ))
                    .disabled(isReadOnly)
                }
            }
        }
    }

    private var effectiveModelID: String? {
        if hasBase, part.inheritModel {
            return context?.baseModelID ?? context?.defaultModelID
        }
        return part.modelID ?? context?.defaultModelID
    }

    // MARK: - Flags, prefix

    private var flagsAndPrefixSection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(HorizontalPartFlag.allCases, id: \.self) { flag in
                GridRow {
                    Text(flag.displayName).gridColumnAlignment(.trailing)
                    Picker(flag.displayName, selection: Binding(
                        get: { part.flags[flag] ?? .clear },
                        set: { state in update("Change Flag") { $0.flags[flag] = state } }
                    )) {
                        Text("Clear").tag(HorizontalPartFlagState.clear)
                        Text("Set").tag(HorizontalPartFlagState.set)
                        if hasBase {
                            Text("Inherit").tag(HorizontalPartFlagState.inherit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(isReadOnly)
                }
            }
            GridRow {
                Text("Prefix").gridColumnAlignment(.trailing)
                HStack {
                    Picker("Prefix", selection: Binding(
                        get: { part.overridePrefix },
                        set: { value in update("Change Prefix Override") { $0.overridePrefix = value } }
                    )) {
                        Text("From entity").tag(HorizontalPartOverridePrefix.no)
                        Text("Override").tag(HorizontalPartOverridePrefix.yes)
                        if hasBase {
                            Text("Inherit").tag(HorizontalPartOverridePrefix.inherit)
                        }
                    }
                    .labelsHidden()
                    if part.overridePrefix == .yes {
                        HorizontalCommittedTextField(text: part.prefix, isReadOnly: isReadOnly) { value in
                            update("Change Prefix") { $0.prefix = value }
                        }
                        .frame(width: 80)
                    }
                }
                .disabled(isReadOnly)
            }
        }
    }

    // MARK: - Orderable MPNs

    private var orderableMPNsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Orderable MPNs")
                    .font(.headline)
                Spacer()
                Button {
                    update("Add Orderable MPN") { $0.orderableMPNs[UUID().uuidString.lowercased()] = "" }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(isReadOnly)
            }
            ForEach(part.orderableMPNs.keys.sorted(), id: \.self) { id in
                HStack {
                    HorizontalCommittedTextField(text: part.orderableMPNs[id] ?? "", isReadOnly: isReadOnly) { value in
                        update("Change Orderable MPN") { $0.orderableMPNs[id] = value }
                    }
                    Button {
                        update("Remove Orderable MPN") { $0.orderableMPNs.removeValue(forKey: id) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly)
                }
            }
            if part.orderableMPNs.isEmpty {
                Text("None — the MPN itself is orderable.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: 640)
    }

    // MARK: - Pad map

    private var padMapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pin to Pad Map")
                .font(.headline)
            if hasBase {
                Text("A derived part maps its pads through its base part.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pins")
                            .font(.subheadline.weight(.semibold))
                        pinTable
                    }
                    VStack(spacing: 8) {
                        Button("Map →", action: mapSelection)
                            .disabled(selectedPinIDs.count != 1 || selectedPadIDs.isEmpty)
                        Button("Unmap", action: unmapSelection)
                            .disabled(selectedPadIDs.isEmpty)
                        Button("Automap", action: automap)
                            .disabled(context?.pads.isEmpty ?? true)
                        Button("Copy from…") {
                            picker = HorizontalPoolItemPickerRequest(
                                purpose: .partCopyPadMap,
                                category: .part,
                                title: "Copy Pad Map From",
                                excludedUUIDs: [part.uuid.lowercased()]
                            )
                        }
                    }
                    .frame(width: 110)
                    .padding(.top, 24)
                    .disabled(isReadOnly)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pads")
                            .font(.subheadline.weight(.semibold))
                        padTable
                    }
                }
                HStack {
                    Text("\(mappedPinCount) of \(context?.pins.count ?? 0) pins mapped")
                    Spacer()
                    Text("\(part.padMap.count) of \(context?.pads.count ?? 0) pads mapped")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var pinTable: some View {
        Table(context?.pins ?? [], selection: $selectedPinIDs) {
            TableColumn("Gate") { pin in Text(pin.gateName) }
                .width(min: 60, ideal: 90)
            TableColumn("Pin") { pin in Text(pin.pinName) }
                .width(min: 80, ideal: 140)
            TableColumn("Mapped") { pin in
                Image(systemName: isMapped(pin) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isMapped(pin) ? .green : .secondary)
            }
            .width(60)
        }
        .frame(minHeight: 260)
    }

    private var padTable: some View {
        Table(context?.pads ?? [], selection: $selectedPadIDs) {
            TableColumn("Pad") { pad in Text(pad.name) }
                .width(min: 60, ideal: 90)
            TableColumn("Gate") { pad in
                Text(mappedPin(for: pad)?.gateName ?? "")
            }
            .width(min: 60, ideal: 90)
            TableColumn("Pin") { pad in
                Text(mappedPin(for: pad)?.pinName ?? "")
                    .foregroundStyle(part.padMap[pad.id] != nil && mappedPin(for: pad) == nil ? .red : .primary)
            }
            .width(min: 80, ideal: 140)
        }
        .frame(minHeight: 260)
    }

    private func isMapped(_ pin: HorizontalPartEditorContext.Pin) -> Bool {
        part.padMap.values.contains { $0.gateID == pin.gateID && $0.pinID == pin.pinID }
    }

    private func mappedPin(for pad: HorizontalPartEditorContext.Pad) -> HorizontalPartEditorContext.Pin? {
        guard let entry = part.padMap[pad.id] else {
            return nil
        }
        return context?.pins.first { $0.gateID == entry.gateID && $0.pinID == entry.pinID }
    }

    private var mappedPinCount: Int {
        (context?.pins ?? []).filter(isMapped).count
    }

    /// `check_part`'s "Unmapped pin" warnings, which need the entity.
    private var unmappedPinIssues: [HorizontalPoolCheckIssue] {
        guard !hasBase, let context else {
            return []
        }
        return context.pins.filter { !isMapped($0) }.map { .warning("Unmapped pin \($0.displayName)") }
    }

    // MARK: - Edits

    // MARK: - Parametric

    private var selectedParametricTable: HorizontalParametricTable? {
        guard let name = part.parametric["table"] else {
            return nil
        }
        return parametricTables.first { $0.name == name }
    }

    /// Horizon's parametric editor: the table the part belongs to and a
    /// field per column, quantities entered with SI prefixes.
    private var parametricSection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Parametric table").gridColumnAlignment(.trailing)
                Picker("Parametric table", selection: Binding(
                    get: { part.parametric["table"] ?? "" },
                    set: { name in
                        update("Change Parametric Table") { edited in
                            if name.isEmpty {
                                edited.parametric = [:]
                            } else {
                                edited.parametric = ["table": name]
                            }
                        }
                    }
                )) {
                    Text("None").tag("")
                    ForEach(parametricTables) { table in
                        Text(table.displayName).tag(table.name)
                    }
                    if let name = part.parametric["table"], !parametricTables.contains(where: { $0.name == name }) {
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .disabled(isReadOnly)
            }
            if let table = selectedParametricTable {
                ForEach(table.columns) { column in
                    GridRow {
                        Text(column.displayName + (column.required ? "" : " (optional)")).gridColumnAlignment(.trailing)
                        parametricField(column)
                    }
                }
            } else if part.parametric["table"] != nil {
                GridRow {
                    Text("")
                    Text("This table is not defined in the pool's tables.json; the stored values are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func parametricField(_ column: HorizontalParametricColumn) -> some View {
        let raw = part.parametric[column.name] ?? ""
        switch column.kind {
        case .enumeration:
            Picker(column.displayName, selection: Binding(
                get: { raw },
                set: { value in
                    update("Change \(column.displayName)") { edited in
                        if value.isEmpty {
                            edited.parametric.removeValue(forKey: column.name)
                        } else {
                            edited.parametric[column.name] = value
                        }
                    }
                }
            )) {
                Text("—").tag("")
                ForEach(column.items, id: \.self) { item in
                    Text(item).tag(item)
                }
                if !raw.isEmpty, !column.items.contains(raw) {
                    Text(raw).tag(raw)
                }
            }
            .labelsHidden()
            .disabled(isReadOnly)
        case .quantity:
            HStack(spacing: 4) {
                HorizontalCommittedTextField(text: column.format(raw), isReadOnly: isReadOnly) { value in
                    update("Change \(column.displayName)") { edited in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            edited.parametric.removeValue(forKey: column.name)
                        } else if let number = HorizontalPoolParametricTables.parseQuantity(trimmed) {
                            edited.parametric[column.name] = HorizontalPoolParametricTables.storedQuantity(number)
                        }
                    }
                }
                .frame(minWidth: 120)
                if !column.unit.isEmpty {
                    Text(column.unit)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func update(_ actionName: String, _ change: (inout HorizontalPoolPartItem) -> Void) {
        var model = part
        change(&model)
        commit(model, actionName)
    }

    private func mapSelection() {
        guard let context,
              let pinID = selectedPinIDs.first,
              let pin = context.pins.first(where: { $0.id == pinID }) else {
            return
        }
        let pads = selectedPadIDs
        update(pads.count == 1 ? "Map Pin" : "Map Pins") { model in
            for padID in pads {
                model.padMap[padID] = HorizontalPartPadMapEntry(gateID: pin.gateID, pinID: pin.pinID)
            }
        }
        // Upstream advances both selections so mapping a run of pads is one
        // click per pad.
        if let pinIndex = context.pins.firstIndex(where: { $0.id == pinID }), pinIndex + 1 < context.pins.count {
            selectedPinIDs = [context.pins[pinIndex + 1].id]
        }
        if pads.count == 1, let padID = pads.first,
           let padIndex = context.pads.firstIndex(where: { $0.id == padID }), padIndex + 1 < context.pads.count {
            selectedPadIDs = [context.pads[padIndex + 1].id]
        }
    }

    private func unmapSelection() {
        let pads = selectedPadIDs
        update(pads.count == 1 ? "Unmap Pad" : "Unmap Pads") { model in
            for padID in pads {
                model.padMap.removeValue(forKey: padID)
            }
        }
    }

    /// Pads whose name matches a pin name get that pin (the selected pads,
    /// or all of them when nothing is selected).
    private func automap() {
        guard let context else {
            return
        }
        let targets = selectedPadIDs.isEmpty ? Set(context.pads.map(\.id)) : selectedPadIDs
        update("Automap Pads") { model in
            for pad in context.pads where targets.contains(pad.id) {
                if let pin = context.pins.first(where: { $0.pinName == pad.name }) {
                    model.padMap[pad.id] = HorizontalPartPadMapEntry(gateID: pin.gateID, pinID: pin.pinID)
                }
            }
        }
    }

    private func apply(_ request: HorizontalPoolItemPickerRequest, item: HorizontalPoolLibraryItem) {
        switch request.purpose {
        case .partEntity:
            update("Change Entity") { model in
                model.entityID = item.uuid
                model.padMap.removeAll()
            }
        case .partPackage:
            let newPadIDs: Set<String>
            if let json = index.json(.package, uuid: item.uuid), let package = try? HorizontalPoolPackage(json: json) {
                newPadIDs = Set(package.pads.keys.map { $0.lowercased() })
            } else {
                newPadIDs = []
            }
            update("Change Package") { model in
                model.packageID = item.uuid
                model.padMap = model.padMap.filter { newPadIDs.contains($0.key.lowercased()) }
            }
        case .partBase:
            update("Set Base Part") { model in
                model.baseID = item.uuid
            }
        case .partCopyPadMap:
            copyPadMap(from: item)
        default:
            break
        }
    }

    /// Materialises everything inherited from the base, then drops it.
    private func clearBase() {
        guard let context else {
            return
        }
        update("Clear Base Part") { model in
            for kind in HorizontalPartAttributeKind.allCases where model.attribute(kind).inherited {
                model.attributes[kind] = HorizontalPartAttribute(inherited: false, value: context.baseAttributes[kind] ?? "")
            }
            if model.inheritTags {
                model.tags = Array(Set(model.tags + context.baseTags)).sorted()
                model.inheritTags = false
            }
            if model.inheritModel {
                model.modelID = context.baseModelID ?? model.modelID
            }
            model.inheritModel = true
            for flag in HorizontalPartFlag.allCases where model.flags[flag] == .inherit {
                model.flags[flag] = .clear
            }
            if model.overridePrefix == .inherit {
                model.overridePrefix = context.baseOverridePrefix
                model.prefix = context.basePrefix
            }
            model.entityID = context.entityID
            model.packageID = context.packageID
            model.padMap = context.basePadMap
            model.baseID = nil
        }
    }

    /// Upstream's "copy from other part": pads are matched by NAME between
    /// the two packages, and only mappings whose gate and pin exist in this
    /// part's entity are taken.
    private func copyPadMap(from item: HorizontalPoolLibraryItem) {
        guard let context else {
            return
        }
        let otherContext = HorizontalPartEditorContext.load(
            entityID: nil, packageID: nil, baseID: item.uuid, index: index
        )
        guard let otherJSON = index.json(.part, uuid: item.uuid),
              let other = try? HorizontalPoolPartItem(json: otherJSON) else {
            return
        }
        let otherPadMap = other.baseID == nil ? other.padMap : otherContext.basePadMap
        let otherPadsByID = Dictionary(uniqueKeysWithValues: otherContext.pads.map { ($0.id.lowercased(), $0.name) })
        var entriesByPadName = [String: HorizontalPartPadMapEntry]()
        for (padID, entry) in otherPadMap {
            if let name = otherPadsByID[padID.lowercased()] {
                entriesByPadName[name] = entry
            }
        }
        let validPins = Set(context.pins.map { $0.gateID.lowercased() + "/" + $0.pinID.lowercased() })
        update("Copy Pad Map") { model in
            for pad in context.pads {
                guard let entry = entriesByPadName[pad.name],
                      validPins.contains(entry.gateID.lowercased() + "/" + entry.pinID.lowercased()) else {
                    continue
                }
                model.padMap[pad.id] = entry
            }
        }
    }
}
