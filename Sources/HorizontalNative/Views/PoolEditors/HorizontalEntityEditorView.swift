import SwiftUI

/// Horizon's entity editor: name, manufacturer, prefix and tags, and the
/// gate table — name, suffix, swap group, unit (chosen from the pool) —
/// with add/delete. Adding a gate starts by picking its unit, as upstream's
/// "add gate" opens the unit browser first.
struct HorizontalEntityEditorView: View {
    var entity: HorizontalPoolEntity
    var index: HorizontalPoolLibraryIndex
    var issues: [HorizontalPoolCheckIssue]
    var isReadOnly: Bool
    var commit: (HorizontalPoolEntity, String) -> Void

    @State private var selectedGateIDs = Set<String>()
    @State private var picker: HorizontalPoolItemPickerRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                gridTextRow("Name", entity.name, "Rename Entity") { $0.name = $1 }
                GridRow {
                    Text("Manufacturer").gridColumnAlignment(.trailing)
                    HorizontalSuggestingTextField(text: entity.manufacturer, suggestions: index.manufacturers, isReadOnly: isReadOnly) { value in
                        var model = entity
                        model.manufacturer = value
                        commit(model, "Change Manufacturer")
                    }
                }
                gridTextRow("Prefix", entity.prefix, "Change Prefix") { $0.prefix = $1 }
                GridRow {
                    Text("Tags").gridColumnAlignment(.trailing)
                    HorizontalTokenField(tokens: entity.tags, suggestions: index.tags, isReadOnly: isReadOnly) { tags in
                        var model = entity
                        model.tags = tags
                        commit(model, "Change Tags")
                    }
                }
            }
            .frame(maxWidth: 520)

            HorizontalPoolItemChecksView(issues: issues)

            HStack {
                Text("Gates")
                    .font(.headline)
                Text("\(entity.gates.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    picker = HorizontalPoolItemPickerRequest(purpose: .gateUnit(gateID: nil), category: .unit, title: "Unit for the New Gate")
                } label: {
                    Label("Add Gate", systemImage: "plus")
                }
                Button {
                    deleteSelectedGates()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selectedGateIDs.isEmpty)
            }
            .disabled(isReadOnly)

            gateTable
        }
        .padding(20)
        .sheet(item: $picker) { request in
            HorizontalPoolItemPickerSheet(
                title: request.title,
                category: request.category,
                index: index,
                onPick: { item in
                    apply(request, item: item)
                    picker = nil
                },
                onCancel: { picker = nil }
            )
        }
    }

    private var gateTable: some View {
        Table(entity.sortedGates, selection: $selectedGateIDs) {
            TableColumn("Name") { gate in
                HorizontalCommittedTextField(text: gate.name, isReadOnly: isReadOnly) { value in
                    update(gate.id, "Rename Gate") { $0.name = value }
                }
            }
            .width(min: 90, ideal: 140)

            TableColumn("Suffix") { gate in
                HorizontalCommittedTextField(text: gate.suffix, isReadOnly: isReadOnly) { value in
                    update(gate.id, "Change Gate Suffix") { $0.suffix = value }
                }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Swap group") { gate in
                HorizontalCommittedTextField(text: String(gate.swapGroup), isReadOnly: isReadOnly) { value in
                    if let group = Int(value.trimmingCharacters(in: .whitespaces)), group >= 0 {
                        update(gate.id, "Change Swap Group") { $0.swapGroup = group }
                    }
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Unit") { gate in
                Button {
                    picker = HorizontalPoolItemPickerRequest(purpose: .gateUnit(gateID: gate.id), category: .unit, title: "Unit for Gate \(gate.name)")
                } label: {
                    HStack {
                        Text(index.name(.unit, uuid: gate.unitID) ?? gate.unitID)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isReadOnly)
            }
            .width(min: 160, ideal: 260)
        }
        .frame(minHeight: 200)
    }

    // MARK: - Edits

    private func gridTextRow(
        _ label: String,
        _ value: String,
        _ actionName: String,
        _ change: @escaping (inout HorizontalPoolEntity, String) -> Void
    ) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            HorizontalCommittedTextField(text: value, isReadOnly: isReadOnly) { newValue in
                var model = entity
                change(&model, newValue)
                commit(model, actionName)
            }
        }
    }

    private func update(_ gateID: String, _ actionName: String, _ change: (inout HorizontalEntityGate) -> Void) {
        guard var gate = entity.gates[gateID] else {
            return
        }
        change(&gate)
        var model = entity
        model.gates[gateID] = gate
        commit(model, actionName)
    }

    private func apply(_ request: HorizontalPoolItemPickerRequest, item: HorizontalPoolLibraryItem) {
        guard case .gateUnit(let gateID) = request.purpose else {
            return
        }
        if let gateID {
            update(gateID, "Change Gate Unit") { $0.unitID = item.uuid }
        } else {
            var model = entity
            let id = UUID().uuidString.lowercased()
            // Upstream's single-gate convention: the only gate is "Main" with no
            // suffix; further gates take the next letter.
            let name = entity.gates.isEmpty ? "Main" : Self.nextSuffix(after: entity.gates.values.map(\.suffix))
            let suffix = entity.gates.isEmpty ? "" : name
            model.gates[id] = HorizontalEntityGate(id: id, name: name, suffix: suffix, unitID: item.uuid)
            commit(model, "Add Gate")
            selectedGateIDs = [id]
        }
    }

    private func deleteSelectedGates() {
        var model = entity
        for id in selectedGateIDs {
            model.gates.removeValue(forKey: id)
        }
        commit(model, selectedGateIDs.count == 1 ? "Delete Gate" : "Delete Gates")
        selectedGateIDs.removeAll()
    }

    /// "A", "B", … "Z", "AA", … skipping suffixes already taken.
    static func nextSuffix(after taken: [String]) -> String {
        let used = Set(taken)
        var index = 0
        while true {
            var candidate = ""
            var value = index
            repeat {
                candidate = String(UnicodeScalar(UInt8(65 + value % 26))) + candidate
                value = value / 26 - 1
            } while value >= 0
            if !used.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }
}
