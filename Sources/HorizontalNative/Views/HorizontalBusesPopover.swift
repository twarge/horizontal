import SwiftUI

/// What Horizon's Manage Buses dialog does to a block's buses, from the
/// schematic rail: rename a member, take a member out (its rippers, and the
/// wires on them, go with it), remove a whole bus (its labels and rippers
/// too). New buses and members come from the bus label and ripper tools,
/// which make them as they place them.
enum HorizontalBusCommand: Equatable {
    case removeBus(String)
    case removeMember(bus: String, member: String)
    case renameMember(bus: String, member: String, name: String)

    /// The project edit for the command on `buses` (the block's, as the
    /// sheet has them), with its undo title; nil when the bus or member is
    /// gone, or a rename would change nothing.
    func edit(in buses: [HorizontalBusDetails]) -> (ops: [JSONDictionary], actionName: String)? {
        func bus(_ id: String) -> HorizontalBusDetails? { buses.first { $0.id.lowercased() == id.lowercased() } }
        func member(_ id: String, of bus: HorizontalBusDetails) -> HorizontalBusDetails.Member? {
            bus.members.first { $0.id.lowercased() == id.lowercased() }
        }
        switch self {
        case .removeBus(let id):
            guard let bus = bus(id) else { return nil }
            return ([["op": "remove_bus", "bus": bus.id.lowercased()]], "Remove Bus")
        case .removeMember(let busID, let memberID):
            guard let bus = bus(busID), let member = member(memberID, of: bus) else { return nil }
            return ([["op": "remove_bus_member", "bus": bus.id.lowercased(), "member": member.id.lowercased()]], "Remove Bus Member")
        case .renameMember(let busID, let memberID, let rawName):
            let name = rawName.trimmingCharacters(in: .whitespaces)
            guard let bus = bus(busID), let member = member(memberID, of: bus), !name.isEmpty, name != member.name else { return nil }
            return ([["op": "rename_bus_member", "bus": bus.id.lowercased(), "member": member.id.lowercased(), "name": name]],
                    "Rename Bus Member")
        }
    }
}

/// The schematic rail's Manage Buses button, with its popover.
struct ManageBusesToolButton: View {
    var buses: [HorizontalBusDetails]
    var netNames: [String: String]
    var isReadOnly: Bool
    var onCommand: (HorizontalBusCommand) -> Void

    @State private var isPresented = false

    var body: some View {
        HorizontalRailHelpLabel(title: "Manage buses") {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .help("Rename or remove buses and their members")
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            HorizontalBusesPopover(buses: buses, netNames: netNames, isReadOnly: isReadOnly, onCommand: onCommand)
        }
    }
}

/// Horizon's Manage Buses: every bus of the block with its members, each
/// member's name editable (Return or leaving the field renames it) beside
/// the net it carries.
struct HorizontalBusesPopover: View {
    var buses: [HorizontalBusDetails]
    /// Net names by lowercased id, for the net each member carries.
    var netNames: [String: String]
    var isReadOnly: Bool
    var onCommand: (HorizontalBusCommand) -> Void

    @State private var draftNames: [String: String] = [:]
    @FocusState private var focusedMember: String?

    private var sortedBuses: [HorizontalBusDetails] {
        buses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Buses")
                .font(.headline)
            if buses.isEmpty {
                Text("No buses yet. Label a bus or place a bus ripper to make one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sortedBuses) { bus in
                            busSection(bus)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onChange(of: focusedMember) { previous, _ in
            if let previous { commit(previous) }
        }
    }

    private func busSection(_ bus: HorizontalBusDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bus.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !isReadOnly {
                    Button(role: .destructive) {
                        onCommand(.removeBus(bus.id))
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(bus.name), its members, and the labels and rippers drawn for it")
                }
            }
            if bus.members.isEmpty {
                Text("No members.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(bus.members) { member in
                memberRow(member, of: bus)
            }
        }
    }

    private func key(_ bus: HorizontalBusDetails, _ member: HorizontalBusDetails.Member) -> String {
        "\(bus.id.lowercased())/\(member.id.lowercased())"
    }

    private func memberRow(_ member: HorizontalBusDetails.Member, of bus: HorizontalBusDetails) -> some View {
        let key = key(bus, member)
        return HStack(spacing: 6) {
            if isReadOnly {
                Text(member.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Name", text: Binding(
                    get: { draftNames[key] ?? member.name },
                    set: { draftNames[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($focusedMember, equals: key)
                .onSubmit { commit(key) }
            }
            Text(member.netID.flatMap { netNames[$0.lowercased()] } ?? "no net")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            if !isReadOnly {
                Button {
                    draftNames[key] = nil
                    onCommand(.removeMember(bus: bus.id, member: member.id))
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Take \(member.name) out of \(bus.name), with its rippers and the wires on them")
            }
        }
    }

    /// Sends a rename for the member under `key` when its draft differs.
    private func commit(_ key: String) {
        guard let draft = draftNames[key] else { return }
        draftNames[key] = nil
        let parts = key.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        onCommand(.renameMember(bus: parts[0], member: parts[1], name: draft))
    }
}
