import SwiftUI

/// The power net editor behind the schematic rail's power symbol button:
/// Horizon's manage-power-nets dialog with placing folded in. Every net
/// has an editable name and a symbol style; `+` adds one, `×` deletes one
/// nothing is on, Place (or a double-click) drops its symbols on the sheet.
struct HorizontalPowerNetsPopover: View {
    var nets: [HorizontalPowerNetSummary]
    var isReadOnly: Bool
    var onCommand: (HorizontalPowerNetCommand) -> Void
    var onDismiss: () -> Void

    @State private var selectedNetID: String?
    @State private var draftNames: [String: String] = [:]
    @FocusState private var focusedNetID: String?

    static let styles: [(id: String, title: String)] = [
        ("gnd", "Ground"),
        ("earth", "Earth"),
        ("dot", "Dot"),
        ("antenna", "Antenna"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Power Nets")
                .font(.headline)
            if nets.isEmpty {
                Text("No power nets yet. Add one to place ground and supply symbols.")
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
                    onCommand(.add(name: nextName, style: "gnd"))
                } label: {
                    Label("Add Power Net", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add a power net")
                Spacer()
                Button("Place") {
                    if let selectedNetID {
                        place(selectedNetID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedNetID == nil || !nets.contains { $0.id == selectedNetID })
                .help("Place symbols of the selected net (or double-click a net)")
            }
        }
        .padding(12)
        .frame(width: 360)
        .disabled(isReadOnly)
        .onAppear {
            if selectedNetID == nil {
                selectedNetID = nets.first?.id
            }
        }
        .onChange(of: focusedNetID) { previous, _ in
            if let previous {
                commitName(previous)
            }
        }
    }

    private func row(for net: HorizontalPowerNetSummary) -> some View {
        let isSelected = selectedNetID == net.id
        return HStack(spacing: 8) {
            Picker("Symbol", selection: styleBinding(for: net)) {
                ForEach(Self.styles, id: \.id) { style in
                    Text(style.title).tag(style.id)
                }
            }
            .labelsHidden()
            .frame(width: 104)
            TextField("Name", text: nameBinding(for: net))
                .textFieldStyle(.roundedBorder)
                .focused($focusedNetID, equals: net.id)
                .onSubmit { commitName(net.id) }
            Button {
                onCommand(.delete(id: net.id))
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(net.isInUse ? Color.secondary.opacity(0.4) : Color.secondary)
            .disabled(net.isInUse)
            .help(net.isInUse ? "In use on the schematic" : "Delete this net")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            place(net.id)
        }
        .onTapGesture {
            selectedNetID = net.id
        }
    }

    private func nameBinding(for net: HorizontalPowerNetSummary) -> Binding<String> {
        Binding(
            get: { draftNames[net.id] ?? net.name },
            set: { draftNames[net.id] = $0 }
        )
    }

    private func styleBinding(for net: HorizontalPowerNetSummary) -> Binding<String> {
        Binding(
            get: { net.style },
            set: { style in
                if style != net.style {
                    onCommand(.setStyle(id: net.id, style: style))
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

    private func place(_ netID: String) {
        commitName(netID)
        selectedNetID = netID
        onCommand(.place(id: netID))
        onDismiss()
    }

    /// GND first, then VCC, then numbered supplies, skipping names in use.
    private var nextName: String {
        let taken = Set(nets.map { $0.name.uppercased() })
        for candidate in ["GND", "VCC", "3V3", "5V", "12V"] where !taken.contains(candidate) {
            return candidate
        }
        var index = 1
        while taken.contains("PWR\(index)") {
            index += 1
        }
        return "PWR\(index)"
    }
}
