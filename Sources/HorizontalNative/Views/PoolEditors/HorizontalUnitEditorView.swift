import SwiftUI

/// Horizon's unit editor: name and manufacturer, and the pin table — primary
/// name, alternate names, direction, swap group — with add/delete. A
/// direction change applies to every selected pin when the edited pin is
/// part of the selection, as upstream propagates it.
struct HorizontalUnitEditorView: View {
    var unit: HorizontalPoolUnit
    var issues: [HorizontalPoolCheckIssue]
    var isReadOnly: Bool
    var commit: (HorizontalPoolUnit, String) -> Void

    @State private var selectedPinIDs = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    HorizontalCommittedTextField(text: unit.name, isReadOnly: isReadOnly) { value in
                        var model = unit
                        model.name = value
                        commit(model, "Rename Unit")
                    }
                }
                GridRow {
                    Text("Manufacturer").gridColumnAlignment(.trailing)
                    HorizontalCommittedTextField(text: unit.manufacturer, isReadOnly: isReadOnly) { value in
                        var model = unit
                        model.manufacturer = value
                        commit(model, "Change Manufacturer")
                    }
                }
            }
            .frame(maxWidth: 520)

            HorizontalPoolItemChecksView(issues: issues)

            HStack {
                Text("Pins")
                    .font(.headline)
                Text("\(unit.pins.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addPin()
                } label: {
                    Label("Add Pin", systemImage: "plus")
                }
                Button {
                    deleteSelectedPins()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selectedPinIDs.isEmpty)
            }
            .disabled(isReadOnly)

            pinTable
        }
        .padding(20)
    }

    private var pinTable: some View {
        Table(unit.sortedPins, selection: $selectedPinIDs) {
            TableColumn("Name") { pin in
                HorizontalCommittedTextField(text: pin.primaryName, isReadOnly: isReadOnly) { value in
                    update(pin.id, "Rename Pin") { $0.primaryName = value }
                }
            }
            .width(min: 90, ideal: 140)

            TableColumn("Alternate names") { pin in
                HorizontalCommittedTextField(
                    text: pin.alternateNames.map(\.name).joined(separator: ", "),
                    isReadOnly: isReadOnly
                ) { value in
                    update(pin.id, "Change Alternate Names") { edited in
                        edited.alternateNames = Self.alternateNames(from: value, keeping: edited.alternateNames, direction: edited.direction)
                    }
                }
            }
            .width(min: 140, ideal: 240)

            TableColumn("Direction") { pin in
                Picker("Direction", selection: Binding(
                    get: { pin.direction },
                    set: { direction in setDirection(direction, of: pin) }
                )) {
                    ForEach(HorizontalPinDirection.editorOrder, id: \.self) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .labelsHidden()
                .disabled(isReadOnly)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Swap group") { pin in
                HorizontalCommittedTextField(text: String(pin.swapGroup), isReadOnly: isReadOnly) { value in
                    if let group = Int(value.trimmingCharacters(in: .whitespaces)), group >= 0 {
                        update(pin.id, "Change Swap Group") { $0.swapGroup = group }
                    }
                }
            }
            .width(min: 70, ideal: 90)
        }
        .frame(minHeight: 240)
    }

    // MARK: - Edits

    private func update(_ pinID: String, _ actionName: String, _ change: (inout HorizontalUnitPin) -> Void) {
        guard var pin = unit.pins[pinID] else {
            return
        }
        change(&pin)
        var model = unit
        model.pins[pinID] = pin
        commit(model, actionName)
    }

    /// Upstream propagates a direction change to the whole selection when
    /// the row being edited is selected.
    private func setDirection(_ direction: HorizontalPinDirection, of pin: HorizontalUnitPin) {
        var model = unit
        let targets = selectedPinIDs.contains(pin.id) && selectedPinIDs.count > 1 ? selectedPinIDs : [pin.id]
        for id in targets {
            model.pins[id]?.direction = direction
        }
        commit(model, "Change Pin Direction")
    }

    private func addPin() {
        var model = unit
        let id = UUID().uuidString.lowercased()
        let numbers = unit.pins.values.compactMap { Int($0.primaryName) }
        let name = unit.pins.isEmpty ? "1" : (numbers.count == unit.pins.count ? String((numbers.max() ?? 0) + 1) : "")
        let direction = selectedPinIDs.first.flatMap { unit.pins[$0]?.direction } ?? .input
        model.pins[id] = HorizontalUnitPin(id: id, primaryName: name, direction: direction)
        commit(model, "Add Pin")
        selectedPinIDs = [id]
    }

    private func deleteSelectedPins() {
        var model = unit
        for id in selectedPinIDs {
            model.pins.removeValue(forKey: id)
        }
        commit(model, selectedPinIDs.count == 1 ? "Delete Pin" : "Delete Pins")
        selectedPinIDs.removeAll()
    }

    /// Comma-separated alternate names. Names that were already there keep
    /// their id and direction; new ones get a fresh id and the pin's own
    /// direction, as upstream's editor seeds them.
    static func alternateNames(
        from text: String,
        keeping existing: [HorizontalUnitPinAlternateName],
        direction: HorizontalPinDirection
    ) -> [HorizontalUnitPinAlternateName] {
        var remaining = existing
        var result = [HorizontalUnitPinAlternateName]()
        for piece in text.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                continue
            }
            if let index = remaining.firstIndex(where: { $0.name == name }) {
                result.append(remaining.remove(at: index))
            } else {
                result.append(HorizontalUnitPinAlternateName(id: UUID().uuidString.lowercased(), name: name, direction: direction))
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}

/// Upstream's check results for the item, when there are any.
struct HorizontalPoolItemChecksView: View {
    var issues: [HorizontalPoolCheckIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { issue in
                    Label {
                        Text(issue.message)
                    } icon: {
                        Image(systemName: issue.level == .failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.level == .failure ? .red : .orange)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
