import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

private let horizonRuleNullUUID = "00000000-0000-0000-0000-000000000000"
private let horizonRuleAnyLayer = 10000

#if os(macOS)
@MainActor
final class HorizontalBoardRulesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<HorizontalBoardRulesWindow>?

    func show(
        projectName: String,
        board: HorizontalBoard?,
        netClasses: [HorizontalNetClass],
        initialRules: JSONDictionary,
        isReadOnly: Bool,
        onRulesChange: @escaping (JSONDictionary) -> Void,
        onChecksRun: @escaping (HorizontalBoardRulesResultState) -> Void
    ) {
        let rootView = HorizontalBoardRulesWindow(
            projectName: projectName,
            board: board,
            netClasses: netClasses,
            initialRules: initialRules,
            isReadOnly: isReadOnly,
            onRulesChange: onRulesChange,
            onChecksRun: onChecksRun
        )

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Board Rules"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1080, height: 720))
            window.minSize = NSSize(width: 1080, height: 680)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("Horizontal Board Rules")
            self.hostingController = hostingController
            self.window = window
        }

        window?.title = "\(projectName) Board Rules"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

struct HorizontalBoardRulesWindow: View {
    var projectName: String
    var board: HorizontalBoard?
    var netClasses: [HorizontalNetClass]
    var initialRules: JSONDictionary
    var isReadOnly: Bool
    var onRulesChange: (JSONDictionary) -> Void
    var onChecksRun: (HorizontalBoardRulesResultState) -> Void

    @State private var rules: JSONDictionary
    @State private var selectedKind: HorizontalBoardRuleKind = .clearanceCopper
    @State private var selectedRuleID: String?
    @State private var selectedTab: HorizontalBoardRuleEditorTab = .editor
    @State private var checkMessages: [HorizontalBoardRuleCheckMessage] = []
    @State private var statusMessage: String?

    init(
        projectName: String,
        board: HorizontalBoard?,
        netClasses: [HorizontalNetClass],
        initialRules: JSONDictionary,
        isReadOnly: Bool,
        onRulesChange: @escaping (JSONDictionary) -> Void,
        onChecksRun: @escaping (HorizontalBoardRulesResultState) -> Void
    ) {
        self.projectName = projectName
        self.board = board
        self.netClasses = netClasses
        self.initialRules = initialRules
        self.isReadOnly = isReadOnly
        self.onRulesChange = onRulesChange
        self.onChecksRun = onChecksRun
        _rules = State(initialValue: initialRules)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ruleFamilyList
                    .frame(width: 260)
                Divider()
                if selectedKind.isMulti {
                    ruleInstanceList
                        .frame(width: 250)
                    Divider()
                }
                editorArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        // The minimum size sizes the macOS window; on iPad the view fills the
        // presenting sheet/cover instead (a forced 1080pt min overflows portrait).
        #if os(macOS)
        .frame(minWidth: 1080, minHeight: 680)
        #endif
        .onAppear {
            ensureSelection()
            runStructuralChecks()
        }
        .onChange(of: selectedKind) { _, _ in
            ensureSelection()
            statusMessage = nil
        }
        .onChange(of: selectedRuleID) { _, _ in
            statusMessage = nil
        }
    }

    private var context: HorizontalBoardRuleContext {
        HorizontalBoardRuleContext(board: board, netClasses: netClasses)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Board Rules")
                    .font(.title3.weight(.semibold))
                Text(projectName)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            Picker("", selection: $selectedTab) {
                ForEach(HorizontalBoardRuleEditorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            Button("Run Checks") {
                let messages = runStructuralChecks()
                onChecksRun(HorizontalBoardRulesResultState(
                    ruleTitle: selectedKind.title,
                    messages: messages,
                    checkedAt: Date()
                ))
                selectedTab = .checks
            }
            .disabled(!selectedKind.canCheck && !selectedKind.needsMatchAll)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if isReadOnly {
                Label("Read-only operation is enabled. Rules can be inspected and copied, but not saved.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            } else {
                Text("Changes apply immediately. \(selectedKind.footerDescription)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(totalRuleCount) rule instances")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var ruleFamilyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rules")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            HorizontalSelectionList(
                selection: Binding(
                    get: { selectedKind },
                    set: { newValue in
                        if let newValue {
                            selectedKind = newValue
                        }
                    }
                ),
                items: HorizontalBoardRuleKind.visibleCases,
                id: { $0 }
            ) { kind in
                HorizontalBoardRuleFamilyRow(kind: kind, count: count(for: kind))
            }
            .listStyle(.sidebar)
        }
    }

    private var ruleInstanceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Instances")
                    .font(.headline)
                Spacer()
                Button {
                    addRuleInstance()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add \(selectedKind.title) rule")
                .disabled(isReadOnly)

                Button {
                    removeSelectedRuleInstance()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove selected rule")
                .disabled(isReadOnly || selectedRuleID == nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            let instances = selectedKind.instances(in: rules, context: context)
            if instances.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No rules")
                        .font(.headline)
                    Text("Add a rule to create the GTK-style priority list.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HorizontalSelectionList(
                    selection: $selectedRuleID,
                    items: instances,
                    id: { $0.id }
                ) { instance in
                    HorizontalBoardRuleInstanceRow(instance: instance)
                }
                .listStyle(.inset)
            }

            HStack(spacing: 8) {
                Button {
                    moveSelectedRuleInstance(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Move rule up")
                .disabled(isReadOnly || selectedRuleID == nil)

                Button {
                    moveSelectedRuleInstance(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Move rule down")
                .disabled(isReadOnly || selectedRuleID == nil)

                Spacer()
                if selectedKind.needsMatchAll && !selectedKind.lastRuleIsCatchAll(in: rules) {
                    Label("Last rule needs to be catch-all.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var editorArea: some View {
        Group {
            switch selectedTab {
            case .editor:
                if let binding = selectedRuleBinding {
                    HorizontalBoardRuleEditorView(
                        kind: selectedKind,
                        rule: binding,
                        context: context,
                        isReadOnly: isReadOnly
                    )
                } else {
                    ContentUnavailableView(
                        "No Rule Selected",
                        systemImage: "checklist",
                        description: Text("Choose or add a rule instance to edit.")
                    )
                }
            case .checks:
                HorizontalBoardRuleChecksView(messages: checkMessages, kind: selectedKind)
            }
        }
    }

    private var selectedRuleBinding: Binding<JSONDictionary>? {
        if selectedKind.isMulti {
            guard let selectedRuleID else {
                return nil
            }
            return Binding {
                let bucket = rules[selectedKind.rawValue] as? JSONDictionary ?? [:]
                return bucket[selectedRuleID] as? JSONDictionary ?? selectedKind.defaultRule(context: context, order: 0)
            } set: { updatedRule in
                var updatedRules = rules
                var bucket = updatedRules[selectedKind.rawValue] as? JSONDictionary ?? [:]
                bucket[selectedRuleID] = updatedRule
                updatedRules[selectedKind.rawValue] = bucket
                setRules(updatedRules)
            }
        }

        return Binding {
            rules[selectedKind.rawValue] as? JSONDictionary ?? selectedKind.defaultRule(context: context, order: -1)
        } set: { updatedRule in
            var updatedRules = rules
            updatedRules[selectedKind.rawValue] = updatedRule
            setRules(updatedRules)
        }
    }

    private var totalRuleCount: Int {
        HorizontalBoardRuleKind.visibleCases.reduce(0) { partial, kind in
            partial + max(1, count(for: kind))
        }
    }

    private func count(for kind: HorizontalBoardRuleKind) -> Int {
        if kind.isMulti {
            return (rules[kind.rawValue] as? JSONDictionary)?.count ?? 0
        }
        return rules[kind.rawValue] == nil ? 0 : 1
    }

    private func ensureSelection() {
        guard selectedKind.isMulti else {
            selectedRuleID = nil
            return
        }
        let instances = selectedKind.instances(in: rules, context: context)
        if let selectedRuleID, instances.contains(where: { $0.id == selectedRuleID }) {
            return
        }
        selectedRuleID = instances.first?.id
    }

    private func addRuleInstance() {
        guard selectedKind.isMulti else {
            return
        }
        var bucket = rules[selectedKind.rawValue] as? JSONDictionary ?? [:]
        let id = UUID().uuidString.lowercased()
        let order = bucket.values.compactMap { ($0 as? JSONDictionary)?.int("order") }.max().map { $0 + 1 } ?? 0
        bucket[id] = selectedKind.defaultRule(context: context, order: order)
        var updatedRules = rules
        updatedRules[selectedKind.rawValue] = bucket
        selectedRuleID = id
        setRules(updatedRules)
    }

    private func removeSelectedRuleInstance() {
        guard selectedKind.isMulti, let selectedRuleID else {
            return
        }
        var bucket = rules[selectedKind.rawValue] as? JSONDictionary ?? [:]
        bucket.removeValue(forKey: selectedRuleID)
        var updatedRules = rules
        updatedRules[selectedKind.rawValue] = bucket
        self.selectedRuleID = nil
        setRules(updatedRules)
        ensureSelection()
    }

    private func moveSelectedRuleInstance(by delta: Int) {
        guard selectedKind.isMulti, let selectedRuleID else {
            return
        }
        var bucket = rules[selectedKind.rawValue] as? JSONDictionary ?? [:]
        var ordered = selectedKind.instances(in: rules, context: context)
        guard let index = ordered.firstIndex(where: { $0.id == selectedRuleID }) else {
            return
        }
        let newIndex = max(0, min(ordered.count - 1, index + delta))
        guard newIndex != index else {
            return
        }
        ordered.move(fromOffsets: IndexSet(integer: index), toOffset: newIndex > index ? newIndex + 1 : newIndex)
        for (order, instance) in ordered.enumerated() {
            var rule = bucket[instance.id] as? JSONDictionary ?? [:]
            rule["order"] = order
            bucket[instance.id] = rule
        }
        var updatedRules = rules
        updatedRules[selectedKind.rawValue] = bucket
        setRules(updatedRules)
    }

    @discardableResult
    private func runStructuralChecks() -> [HorizontalBoardRuleCheckMessage] {
        let messages = HorizontalBoardRulesValidator.validate(rules: rules, selectedKind: selectedKind, context: context)
        checkMessages = messages
        return messages
    }

    private func setRules(_ updatedRules: JSONDictionary) {
        rules = updatedRules
        runStructuralChecks()
        guard !isReadOnly else {
            statusMessage = "Read-only mode is enabled."
            return
        }
        onRulesChange(updatedRules)
        statusMessage = "Rules updated."
    }
}

private enum HorizontalBoardRuleEditorTab: String, CaseIterable, Identifiable {
    case editor
    case checks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor:
            return "Editor"
        case .checks:
            return "Checks"
        }
    }
}

private enum HorizontalBoardRuleKind: String, CaseIterable, Identifiable, Hashable {
    case clearanceCopper = "clearance_copper"
    case clearanceCopperOther = "clearance_copper_other"
    case clearanceCopperKeepout = "clearance_copper_keepout"
    case clearanceSameNet = "clearance_same_net"
    case clearanceSilkscreenExposedCopper = "clearance_silkscreen_exposed_copper"
    case heightRestrictions = "height_restrictions"
    case trackWidth = "track_width"
    case holeSize = "hole_size"
    case via = "via"
    case viaDefinitions = "via_definitions"
    case plane = "plane"
    case thermals = "thermals"
    case diffpair = "diffpair"
    case parameters = "parameters"
    case shortedPads = "shorted_pads"
    case netTies = "net_ties"
    case layerPair = "layer_pair"
    case preflightChecks = "preflight_checks"
    case boardConnectivity = "board_connectivity"

    var id: String { rawValue }

    static var visibleCases: [HorizontalBoardRuleKind] {
        allCases.filter { $0 != .heightRestrictions }
    }

    var title: String {
        switch self {
        case .clearanceCopper:
            return "Copper clearance"
        case .clearanceCopperOther:
            return "Clearance Copper - Other"
        case .clearanceCopperKeepout:
            return "Clearance Copper - Keepout"
        case .clearanceSameNet:
            return "Same net clearance"
        case .clearanceSilkscreenExposedCopper:
            return "Clearance Silkscreen - Exposed copper"
        case .heightRestrictions:
            return "Height restrictions"
        case .trackWidth:
            return "Track width"
        case .holeSize:
            return "Hole size"
        case .via:
            return "Vias"
        case .viaDefinitions:
            return "Via definitions"
        case .plane:
            return "Planes"
        case .thermals:
            return "Thermals"
        case .diffpair:
            return "Diffpair"
        case .parameters:
            return "Parameters"
        case .shortedPads:
            return "Shorted Pads"
        case .netTies:
            return "Net ties"
        case .layerPair:
            return "Layer pairs"
        case .preflightChecks:
            return "Preflight checks"
        case .boardConnectivity:
            return "Connectivity"
        }
    }

    var isMulti: Bool {
        switch self {
        case .clearanceCopper, .clearanceCopperOther, .clearanceCopperKeepout, .clearanceSameNet,
             .trackWidth, .holeSize, .via, .plane, .thermals, .diffpair, .shortedPads, .layerPair:
            return true
        case .clearanceSilkscreenExposedCopper, .heightRestrictions, .viaDefinitions, .parameters,
             .netTies, .preflightChecks, .boardConnectivity:
            return false
        }
    }

    var canCheck: Bool {
        switch self {
        case .clearanceCopper, .clearanceCopperOther, .clearanceCopperKeepout, .clearanceSameNet,
             .clearanceSilkscreenExposedCopper, .heightRestrictions, .trackWidth, .holeSize, .plane,
             .shortedPads, .netTies, .preflightChecks, .boardConnectivity:
            return true
        case .via, .viaDefinitions, .thermals, .diffpair, .parameters, .layerPair:
            return false
        }
    }

    var canApply: Bool {
        switch self {
        case .trackWidth, .parameters, .via, .viaDefinitions, .plane, .shortedPads:
            return true
        case .clearanceCopper, .clearanceCopperOther, .clearanceCopperKeepout, .clearanceSameNet,
             .clearanceSilkscreenExposedCopper, .heightRestrictions, .holeSize, .thermals,
             .diffpair, .netTies, .layerPair, .preflightChecks, .boardConnectivity:
            return false
        }
    }

    var needsMatchAll: Bool {
        switch self {
        case .clearanceCopper, .clearanceCopperOther, .clearanceCopperKeepout, .trackWidth, .via, .plane:
            return true
        case .clearanceSameNet, .clearanceSilkscreenExposedCopper, .heightRestrictions, .holeSize,
             .viaDefinitions, .thermals, .diffpair, .parameters, .shortedPads, .netTies,
             .layerPair, .preflightChecks, .boardConnectivity:
            return false
        }
    }

    var footerDescription: String {
        var traits = [String]()
        if isMulti {
            traits.append("priority list")
        }
        if canCheck {
            traits.append("checkable")
        }
        if canApply {
            traits.append("applies geometry")
        }
        if needsMatchAll {
            traits.append("last rule should match all")
        }
        return traits.isEmpty ? "GTK-compatible board rule." : traits.joined(separator: ", ")
    }

    func defaultRule(context: HorizontalBoardRuleContext, order: Int) -> JSONDictionary {
        var rule: JSONDictionary = [
            "enabled": true,
            "order": order
        ]

        switch self {
        case .clearanceCopper:
            rule["match_1"] = context.defaultMatch()
            rule["match_2"] = context.defaultMatch()
            rule["layer"] = horizonRuleAnyLayer
            rule["routing_offset"] = 50_000
            rule["clearances"] = []
        case .clearanceCopperOther, .clearanceSameNet:
            rule["match"] = context.defaultMatch()
            rule["layer"] = horizonRuleAnyLayer
            rule["clearances"] = []
            if self == .clearanceCopperOther {
                rule["routing_offset"] = 50_000
            }
        case .clearanceCopperKeepout:
            rule["match"] = context.defaultMatch()
            rule["match_keepout"] = HorizontalBoardRuleContext.defaultKeepoutMatch()
            rule["routing_offset"] = 50_000
            rule["clearances"] = JSONDictionary()
        case .clearanceSilkscreenExposedCopper:
            rule["clearance_top"] = 100_000
            rule["clearance_bottom"] = 100_000
            rule["pads_only"] = true
        case .heightRestrictions:
            break
        case .trackWidth:
            rule["match"] = context.defaultMatch()
            rule["widths"] = context.defaultTrackWidths()
        case .holeSize:
            rule["match"] = context.defaultMatch()
            rule["diameter_min"] = 200_000
            rule["diameter_max"] = 10_000_000
        case .via:
            rule["match"] = context.defaultMatch()
            rule["padstack"] = ""
            rule["parameter_set"] = [
                "via_diameter": 500_000,
                "hole_diameter": 200_000
            ] as JSONDictionary
        case .viaDefinitions:
            rule["via_definitions"] = JSONDictionary()
        case .plane:
            rule["match"] = context.defaultMatch()
            rule["layer"] = horizonRuleAnyLayer
            rule["settings"] = HorizontalBoardRuleContext.defaultPlaneSettings(thermalGap: 200_000)
        case .thermals:
            rule["match"] = context.defaultMatch()
            rule["match_component"] = HorizontalBoardRuleContext.defaultComponentMatch()
            rule["layer"] = horizonRuleAnyLayer
            rule["pad_mode"] = "all"
            rule["pads"] = []
            for (key, value) in HorizontalBoardRuleContext.defaultPlaneSettings(thermalGap: 200_000) {
                rule[key] = value
            }
        case .diffpair:
            rule["net_class"] = context.defaultNetClassID
            rule["layer"] = horizonRuleAnyLayer
            rule["track_width"] = 150_000
            rule["track_gap"] = 150_000
            rule["via_gap"] = 250_000
        case .parameters:
            rule["solder_mask_expansion"] = 100_000
            rule["paste_mask_contraction"] = 0
            rule["courtyard_expansion"] = 250_000
            rule["via_solder_mask_expansion"] = 100_000
            rule["hole_solder_mask_expansion"] = 100_000
        case .shortedPads:
            rule["match"] = context.defaultMatch()
            rule["match_component"] = HorizontalBoardRuleContext.defaultComponentMatch()
        case .netTies, .preflightChecks, .boardConnectivity:
            break
        case .layerPair:
            rule["match"] = context.defaultMatch()
            rule["layers"] = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
        }
        return rule
    }

    func instances(in rules: JSONDictionary, context: HorizontalBoardRuleContext) -> [HorizontalBoardRuleInstance] {
        guard isMulti else {
            return []
        }
        let bucket = rules[rawValue] as? JSONDictionary ?? [:]
        return bucket.compactMap { key, value in
            guard let rule = value as? JSONDictionary else {
                return nil
            }
            return HorizontalBoardRuleInstance(
                id: key,
                title: brief(for: rule, context: context),
                enabled: rule.bool("enabled") ?? true,
                order: rule.int("order") ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.id < rhs.id
            }
            return lhs.order < rhs.order
        }
    }

    func brief(for rule: JSONDictionary, context: HorizontalBoardRuleContext) -> String {
        switch self {
        case .clearanceCopper:
            let lhs = context.matchBrief(rule.dictionary("match_1"))
            let rhs = context.matchBrief(rule.dictionary("match_2"))
            return "\(lhs) / \(rhs)\n\(context.layerName(rule.int("layer") ?? horizonRuleAnyLayer))"
        case .clearanceCopperOther, .clearanceSameNet, .trackWidth, .holeSize, .via, .layerPair:
            return "Match \(context.matchBrief(rule.dictionary("match")))"
        case .clearanceCopperKeepout:
            return "\(context.matchBrief(rule.dictionary("match"))) / \(context.keepoutMatchBrief(rule.dictionary("match_keepout")))"
        case .plane:
            return "Match \(context.matchBrief(rule.dictionary("match")))\n\(context.layerName(rule.int("layer") ?? horizonRuleAnyLayer))"
        case .thermals:
            return "\(context.componentMatchBrief(rule.dictionary("match_component")))\n\(context.matchBrief(rule.dictionary("match")))"
        case .diffpair:
            return "Net class \(context.netClassName(rule.string("net_class") ?? ""))\n\(context.layerName(rule.int("layer") ?? horizonRuleAnyLayer))"
        case .shortedPads:
            return "\(context.componentMatchBrief(rule.dictionary("match_component")))\n\(context.matchBrief(rule.dictionary("match")))"
        case .clearanceSilkscreenExposedCopper, .heightRestrictions, .viaDefinitions, .parameters,
             .netTies, .preflightChecks, .boardConnectivity:
            return title
        }
    }

    func lastRuleIsCatchAll(in rules: JSONDictionary) -> Bool {
        guard isMulti else {
            return true
        }
        guard let last = instances(in: rules, context: HorizontalBoardRuleContext(board: nil, netClasses: [])).last,
              let rule = (rules[rawValue] as? JSONDictionary)?[last.id] as? JSONDictionary else {
            return false
        }
        switch self {
        case .clearanceCopper:
            return isAll(rule.dictionary("match_1")) && isAll(rule.dictionary("match_2")) && rule.int("layer", fallback: horizonRuleAnyLayer) == horizonRuleAnyLayer
        case .clearanceCopperOther, .clearanceSameNet, .plane:
            return isAll(rule.dictionary("match")) && rule.int("layer", fallback: horizonRuleAnyLayer) == horizonRuleAnyLayer
        case .clearanceCopperKeepout:
            return isAll(rule.dictionary("match")) && (rule.dictionary("match_keepout")?.string("mode") ?? "all") == "all"
        case .trackWidth, .holeSize, .via:
            return isAll(rule.dictionary("match"))
        case .thermals, .diffpair, .shortedPads, .layerPair,
             .clearanceSilkscreenExposedCopper, .heightRestrictions, .viaDefinitions, .parameters,
             .netTies, .preflightChecks, .boardConnectivity:
            return true
        }
    }

    private func isAll(_ match: JSONDictionary?) -> Bool {
        (match?.string("mode") ?? "all") == "all"
    }
}

private struct HorizontalBoardRuleContext {
    var board: HorizontalBoard?
    var netClasses: [HorizontalNetClass]

    var defaultNetClassID: String {
        netClasses.first?.id ?? horizonRuleNullUUID
    }

    var layerOptions: [Int] {
        var layers = [horizonRuleAnyLayer]
        if let board {
            layers.append(contentsOf: board.stackupLayers.map(\.layer))
            layers.append(contentsOf: board.userLayers.map(\.id))
        } else {
            layers.append(contentsOf: HorizontalBoardLayers.all)
        }
        layers.append(HorizontalBoardLayers.topSilkscreen)
        layers.append(HorizontalBoardLayers.bottomSilkscreen)
        layers.append(HorizontalBoardLayers.outline)
        return Array(Set(layers)).sorted { lhs, rhs in
            if lhs == horizonRuleAnyLayer {
                return true
            }
            if rhs == horizonRuleAnyLayer {
                return false
            }
            return lhs > rhs
        }
    }

    var copperLayers: [Int] {
        if let board, !board.stackupLayers.isEmpty {
            return board.stackupLayers.map(\.layer).sorted(by: >)
        }
        return [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.in2Copper, HorizontalBoardLayers.bottomCopper]
    }

    var netOptions: [HorizontalNetDetails] {
        board?.netDetails.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? []
    }

    func layerName(_ layer: Int) -> String {
        if layer == horizonRuleAnyLayer {
            return "Any Layer"
        }
        if let userLayer = board?.userLayers.first(where: { $0.id == layer }) {
            return userLayer.name
        }
        return HorizontalBoardLayers.name(for: layer)
    }

    func netName(_ id: String) -> String {
        if id == horizonRuleNullUUID || id.isEmpty {
            return "None"
        }
        return board?.netDetails[id]?.name ?? "Unknown net"
    }

    func netClassName(_ id: String) -> String {
        if id == horizonRuleNullUUID || id.isEmpty {
            return "Default"
        }
        return netClasses.first { $0.id.lowercased() == id.lowercased() }?.name ?? "Unknown net class"
    }

    func defaultMatch() -> JSONDictionary {
        [
            "mode": "all",
            "net": horizonRuleNullUUID,
            "net_class": defaultNetClassID,
            "net_name_regex": ""
        ]
    }

    static func defaultComponentMatch() -> JSONDictionary {
        [
            "mode": "component",
            "component": horizonRuleNullUUID,
            "part": horizonRuleNullUUID,
            "components": []
        ]
    }

    static func defaultKeepoutMatch() -> JSONDictionary {
        [
            "mode": "all",
            "component": horizonRuleNullUUID,
            "keepout_class": ""
        ]
    }

    static func defaultPlaneSettings(thermalGap: Int) -> JSONDictionary {
        [
            "connect_style": "solid",
            "thermal_gap_width": thermalGap,
            "thermal_spoke_width": 200_000,
            "n_spokes": 4,
            "angle": 0,
            "min_width": 200_000,
            "keep_orphans": false,
            "style": "round",
            "text_style": "expand",
            "fill_style": "solid",
            "hatch_border_width": 500_000,
            "hatch_line_spacing": 500_000,
            "hatch_line_width": 200_000
        ]
    }

    func defaultTrackWidths() -> JSONDictionary {
        copperLayers.reduce(into: JSONDictionary()) { result, layer in
            result[String(layer)] = [
                "min": 100_000,
                "def": layer == HorizontalBoardLayers.topCopper || layer == HorizontalBoardLayers.bottomCopper ? 200_000 : 300_000,
                "max": 10_000_000
            ] as JSONDictionary
        }
    }

    func matchBrief(_ match: JSONDictionary?) -> String {
        guard let match else {
            return "All"
        }
        switch match.string("mode") ?? "all" {
        case "all":
            return "All"
        case "net":
            return "Net \(netName(match.string("net") ?? ""))"
        case "nets":
            let count = (match["nets"] as? [Any])?.count ?? 0
            return count == 1 ? "One net" : "\(count) nets"
        case "net_class":
            return "Net class \(netClassName(match.string("net_class") ?? ""))"
        case "net_name_regex":
            return "Net name regex \(match.string("net_name_regex") ?? "")"
        case "net_class_regex":
            return "Net class regex \(match.string("net_class_regex") ?? "")"
        default:
            return "Custom"
        }
    }

    func componentMatchBrief(_ match: JSONDictionary?) -> String {
        guard let match else {
            return "Component"
        }
        switch match.string("mode") ?? "component" {
        case "component":
            return "Component"
        case "components":
            let count = (match["components"] as? [Any])?.count ?? 0
            return count == 1 ? "One component" : "\(count) components"
        case "part":
            return "Part"
        default:
            return "Component"
        }
    }

    func keepoutMatchBrief(_ match: JSONDictionary?) -> String {
        guard let match else {
            return "All keepouts"
        }
        switch match.string("mode") ?? "all" {
        case "all":
            return "All keepouts"
        case "component":
            return "Component keepout"
        case "keepout_class":
            return "Keepout class \(match.string("keepout_class") ?? "")"
        default:
            return "Keepout"
        }
    }
}

private struct HorizontalBoardRuleInstance: Identifiable {
    var id: String
    var title: String
    var enabled: Bool
    var order: Int
}

private struct HorizontalBoardRuleFamilyRow: View {
    var kind: HorizontalBoardRuleKind
    var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(kind.canCheck ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if kind.isMulti {
                        Text("\(count)")
                    }
                    if kind.canCheck {
                        Text("Check")
                    }
                    if kind.canApply {
                        Text("Apply")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var iconName: String {
        if kind.canApply {
            return "wand.and.stars"
        }
        if kind.canCheck {
            return "checkmark.seal"
        }
        return "slider.horizontal.3"
    }
}

private struct HorizontalBoardRuleInstanceRow: View {
    var instance: HorizontalBoardRuleInstance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: instance.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(instance.enabled ? .green : .secondary)
                .font(.caption)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(instance.title)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct HorizontalBoardRuleEditorView: View {
    var kind: HorizontalBoardRuleKind
    @Binding var rule: JSONDictionary
    var context: HorizontalBoardRuleContext
    var isReadOnly: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Rule") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enabled", isOn: boolBinding("enabled", default: true))
                    }
                    .padding(6)
                }

                switch kind {
                case .clearanceCopper:
                    HorizontalRuleClearanceCopperEditor(rule: $rule, context: context)
                case .clearanceCopperOther:
                    HorizontalRuleClearanceCopperOtherEditor(rule: $rule, context: context)
                case .clearanceCopperKeepout:
                    HorizontalRuleClearanceCopperKeepoutEditor(rule: $rule, context: context)
                case .clearanceSameNet:
                    HorizontalRuleClearanceSameNetEditor(rule: $rule, context: context)
                case .clearanceSilkscreenExposedCopper:
                    GroupBox("Clearance") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Pads only", isOn: boolBinding("pads_only", default: true))
                            HorizontalRuleDimensionField(label: "Top clearance", value: mmBinding("clearance_top", defaultNanometers: 100_000))
                            HorizontalRuleDimensionField(label: "Bottom clearance", value: mmBinding("clearance_bottom", defaultNanometers: 100_000))
                        }
                        .padding(6)
                    }
                case .heightRestrictions:
                    TextRuleExplanation("Height restriction checks use board height restriction objects. No additional serialized settings are required by GTK.")
                case .trackWidth:
                    HorizontalRuleMatchEditor(title: "Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    HorizontalRuleTrackWidthsEditor(widths: dictionaryBinding("widths", default: context.defaultTrackWidths()), context: context)
                case .holeSize:
                    HorizontalRuleMatchEditor(title: "Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    GroupBox("Hole Diameter") {
                        VStack(alignment: .leading, spacing: 10) {
                            HorizontalRuleDimensionField(label: "Minimum", value: mmBinding("diameter_min", defaultNanometers: 200_000))
                            HorizontalRuleDimensionField(label: "Maximum", value: mmBinding("diameter_max", defaultNanometers: 10_000_000))
                        }
                        .padding(6)
                    }
                case .via:
                    HorizontalRuleMatchEditor(title: "Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    GroupBox("Via") {
                        VStack(alignment: .leading, spacing: 10) {
                            HorizontalRuleTextField(label: "Padstack", value: stringBinding("padstack", default: ""))
                            HorizontalRuleParameterSetEditor(parameters: dictionaryBinding("parameter_set", default: ["via_diameter": 500_000, "hole_diameter": 200_000]))
                        }
                        .padding(6)
                    }
                case .viaDefinitions:
                    HorizontalRuleViaDefinitionsEditor(viaDefinitions: dictionaryBinding("via_definitions", default: [:]), context: context)
                case .plane:
                    HorizontalRuleMatchEditor(title: "Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    layerSection
                    HorizontalRulePlaneSettingsEditor(settings: dictionaryBinding("settings", default: HorizontalBoardRuleContext.defaultPlaneSettings(thermalGap: 200_000)))
                case .thermals:
                    HorizontalRuleMatchComponentEditor(match: dictionaryBinding("match_component", default: HorizontalBoardRuleContext.defaultComponentMatch()))
                    HorizontalRuleMatchEditor(title: "Net Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    layerSection
                    GroupBox("Pads and Thermals") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Pads", selection: stringBinding("pad_mode", default: "all")) {
                                Text("All").tag("all")
                                Text("Specific pads").tag("pads")
                            }
                            HorizontalRuleStringListEditor(title: "Pads", values: arrayStringBinding("pads"))
                            HorizontalRulePlaneSettingsFields(settings: $rule)
                        }
                        .padding(6)
                    }
                case .diffpair:
                    GroupBox("Diffpair") {
                        VStack(alignment: .leading, spacing: 10) {
                            HorizontalRuleNetClassPicker(label: "Net class", value: stringBinding("net_class", default: context.defaultNetClassID), context: context)
                            HorizontalRuleLayerPicker(label: "Layer", value: intBinding("layer", default: horizonRuleAnyLayer), context: context)
                            HorizontalRuleDimensionField(label: "Track width", value: mmBinding("track_width", defaultNanometers: 150_000))
                            HorizontalRuleDimensionField(label: "Track gap", value: mmBinding("track_gap", defaultNanometers: 150_000))
                            HorizontalRuleDimensionField(label: "Via gap", value: mmBinding("via_gap", defaultNanometers: 250_000))
                        }
                        .padding(6)
                    }
                case .parameters:
                    GroupBox("Board Parameters") {
                        VStack(alignment: .leading, spacing: 10) {
                            HorizontalRuleDimensionField(label: "Solder mask expansion", value: mmBinding("solder_mask_expansion", defaultNanometers: 100_000))
                            HorizontalRuleDimensionField(label: "Paste mask contraction", value: mmBinding("paste_mask_contraction", defaultNanometers: 0))
                            HorizontalRuleDimensionField(label: "Courtyard expansion", value: mmBinding("courtyard_expansion", defaultNanometers: 250_000))
                            HorizontalRuleDimensionField(label: "Via solder mask expansion", value: mmBinding("via_solder_mask_expansion", defaultNanometers: 100_000))
                            HorizontalRuleDimensionField(label: "Hole solder mask expansion", value: mmBinding("hole_solder_mask_expansion", defaultNanometers: 100_000))
                        }
                        .padding(6)
                    }
                case .shortedPads:
                    HorizontalRuleMatchComponentEditor(match: dictionaryBinding("match_component", default: HorizontalBoardRuleContext.defaultComponentMatch()))
                    HorizontalRuleMatchEditor(title: "Net Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                case .netTies:
                    TextRuleExplanation("Net tie checks are represented by GTK as a board check rule without additional serialized settings.")
                case .layerPair:
                    HorizontalRuleMatchEditor(title: "Match", match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    HorizontalRuleLayerPairEditor(layers: arrayBinding("layers"), context: context)
                case .preflightChecks:
                    TextRuleExplanation("Preflight checks cover project-level board readiness conditions. GTK stores only the enabled state.")
                case .boardConnectivity:
                    TextRuleExplanation("Connectivity checks compare board copper connectivity against the schematic netlist. GTK stores only the enabled state.")
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .disabled(isReadOnly)
    }

    private var handledKeys: Set<String> {
        var keys: Set<String> = ["enabled", "order"]
        switch kind {
        case .clearanceCopper:
            keys.formUnion(["match_1", "match_2", "layer", "routing_offset", "clearances"])
        case .clearanceCopperOther:
            keys.formUnion(["match", "layer", "routing_offset", "clearances"])
        case .clearanceCopperKeepout:
            keys.formUnion(["match", "match_keepout", "routing_offset", "clearances"])
        case .clearanceSameNet:
            keys.formUnion(["match", "layer", "clearances"])
        case .clearanceSilkscreenExposedCopper:
            keys.formUnion(["pads_only", "clearance_top", "clearance_bottom"])
        case .heightRestrictions:
            break
        case .trackWidth:
            keys.formUnion(["match", "widths"])
        case .holeSize:
            keys.formUnion(["match", "diameter_min", "diameter_max"])
        case .via:
            keys.formUnion(["match", "padstack", "parameter_set"])
        case .viaDefinitions:
            keys.insert("via_definitions")
        case .plane:
            keys.formUnion(["match", "layer", "settings"])
        case .thermals:
            keys.formUnion(["match", "match_component", "layer", "pad_mode", "pads"])
            keys.formUnion(HorizontalRulePlaneSettingsEditor.settingKeys)
        case .diffpair:
            keys.formUnion(["net_class", "layer", "track_width", "track_gap", "via_gap"])
        case .parameters:
            keys.formUnion(["solder_mask_expansion", "paste_mask_contraction", "courtyard_expansion", "via_solder_mask_expansion", "hole_solder_mask_expansion"])
        case .shortedPads:
            keys.formUnion(["match", "match_component"])
        case .netTies, .preflightChecks, .boardConnectivity:
            break
        case .layerPair:
            keys.formUnion(["match", "layers"])
        }
        return keys
    }

    private var layerSection: some View {
        GroupBox("Layer") {
            HorizontalRuleLayerPicker(label: "Layer", value: intBinding("layer", default: horizonRuleAnyLayer), context: context)
                .padding(6)
        }
    }

    private var layerAndRoutingSection: some View {
        GroupBox("Layer and Routing") {
            VStack(alignment: .leading, spacing: 10) {
                HorizontalRuleLayerPicker(label: "Layer", value: intBinding("layer", default: horizonRuleAnyLayer), context: context)
                HorizontalRuleDimensionField(label: "Routing offset", value: mmBinding("routing_offset", defaultNanometers: 50_000))
            }
            .padding(6)
        }
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding {
            rule.bool(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            rule.string(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding {
            rule.int(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func mmBinding(_ key: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            Double(rule.int(key) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            rule[key] = Int((value * 1_000_000.0).rounded())
        }
    }

    private func dictionaryBinding(_ key: String, default defaultValue: JSONDictionary) -> Binding<JSONDictionary> {
        Binding {
            rule.dictionary(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func arrayBinding(_ key: String) -> Binding<[Any]> {
        Binding {
            rule[key] as? [Any] ?? []
        } set: { value in
            rule[key] = value
        }
    }

    private func arrayStringBinding(_ key: String) -> Binding<[String]> {
        Binding {
            (rule[key] as? [Any])?.compactMap { $0 as? String } ?? []
        } set: { value in
            rule[key] = value
        }
    }
}

private struct HorizontalRuleTextField: View {
    var label: String
    @Binding var value: String

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
        }
    }
}

private struct HorizontalRuleIntField: View {
    var label: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
    }
}

private struct HorizontalRuleDimensionField: View {
    var label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Text("mm")
                .foregroundStyle(.secondary)
        }
    }
}

private struct HorizontalRuleLayerPicker: View {
    var label: String
    @Binding var value: Int
    var context: HorizontalBoardRuleContext

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .trailing)
                .foregroundStyle(.secondary)
            Picker(label, selection: $value) {
                ForEach(context.layerOptions, id: \.self) { layer in
                    Text(context.layerName(layer)).tag(layer)
                }
            }
            .frame(maxWidth: 260)
        }
    }
}

private struct HorizontalRuleNetClassPicker: View {
    var label: String
    @Binding var value: String
    var context: HorizontalBoardRuleContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .frame(width: 150, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Picker(label, selection: $value) {
                    ForEach(context.netClasses) { netClass in
                        Text(netClass.name).tag(netClass.id)
                    }
                    if context.netClasses.isEmpty {
                        Text("Default").tag(horizonRuleNullUUID)
                    }
                }
                .frame(maxWidth: 260)
            }
        }
    }
}

private struct HorizontalRuleMatchEditor: View {
    var title: String
    @Binding var match: JSONDictionary
    var context: HorizontalBoardRuleContext

    private let modes = [
        ("all", "All"),
        ("net", "Single net"),
        ("nets", "Multiple nets"),
        ("net_class", "Net class"),
        ("net_name_regex", "Net name regex"),
        ("net_class_regex", "Net class regex")
    ]

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mode")
                        .frame(width: 150, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("Mode", selection: stringBinding("mode", default: "all")) {
                        ForEach(modes, id: \.0) { mode in
                            Text(mode.1).tag(mode.0)
                        }
                    }
                    .frame(maxWidth: 260)
                }
                switch match.string("mode") ?? "all" {
                case "net":
                    HStack {
                        Text("Net")
                            .frame(width: 150, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Picker("Net", selection: stringBinding("net", default: horizonRuleNullUUID)) {
                            Text("None").tag(horizonRuleNullUUID)
                            ForEach(context.netOptions, id: \.id) { net in
                                Text(net.name).tag(net.id)
                            }
                        }
                        .frame(maxWidth: 300)
                    }
                case "nets":
                    HorizontalRuleStringListEditor(title: "Nets", values: arrayStringBinding("nets"))
                case "net_class":
                    HorizontalRuleNetClassPicker(label: "Net class", value: stringBinding("net_class", default: context.defaultNetClassID), context: context)
                case "net_name_regex":
                    HorizontalRuleTextField(label: "Net name regex", value: stringBinding("net_name_regex", default: ""))
                case "net_class_regex":
                    HorizontalRuleTextField(label: "Net class regex", value: stringBinding("net_class_regex", default: ""))
                default:
                    EmptyView()
                }
            }
            .padding(6)
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            match.string(key) ?? defaultValue
        } set: { value in
            match[key] = value
        }
    }

    private func arrayStringBinding(_ key: String) -> Binding<[String]> {
        Binding {
            (match[key] as? [Any])?.compactMap { $0 as? String } ?? []
        } set: { value in
            match[key] = value
        }
    }
}

private struct HorizontalRuleMatchComponentEditor: View {
    @Binding var match: JSONDictionary

    var body: some View {
        GroupBox("Component Match") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mode")
                        .frame(width: 150, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("Mode", selection: stringBinding("mode", default: "component")) {
                        Text("Single component").tag("component")
                        Text("Multiple components").tag("components")
                        Text("Part").tag("part")
                    }
                    .frame(maxWidth: 260)
                }
                switch match.string("mode") ?? "component" {
                case "components":
                    HorizontalRuleStringListEditor(title: "Components", values: arrayStringBinding("components"))
                case "part":
                    Text("Part-specific matches are preserved, but the part picker is not wired here yet.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 154)
                default:
                    Text("Component-specific matches are preserved, but the component picker is not wired here yet.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 154)
                }
            }
            .padding(6)
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            match.string(key) ?? defaultValue
        } set: { value in
            match[key] = value
        }
    }

    private func arrayStringBinding(_ key: String) -> Binding<[String]> {
        Binding {
            (match[key] as? [Any])?.compactMap { $0 as? String } ?? []
        } set: { value in
            match[key] = value
        }
    }
}

private struct HorizontalRuleMatchKeepoutEditor: View {
    @Binding var match: JSONDictionary

    var body: some View {
        GroupBox("Keepout Match") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mode")
                        .frame(width: 150, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("Mode", selection: stringBinding("mode", default: "all")) {
                        Text("All").tag("all")
                        Text("Component").tag("component")
                        Text("Keepout class").tag("keepout_class")
                    }
                    .frame(maxWidth: 260)
                }
                switch match.string("mode") ?? "all" {
                case "component":
                    Text("Component keepout matches are preserved, but the component picker is not wired here yet.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 154)
                case "keepout_class":
                    HorizontalRuleTextField(label: "Keepout class", value: stringBinding("keepout_class", default: ""))
                default:
                    EmptyView()
                }
            }
            .padding(6)
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            match.string(key) ?? defaultValue
        } set: { value in
            match[key] = value
        }
    }
}

private struct HorizontalRuleStringListEditor: View {
    var title: String
    @Binding var values: [String]
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .frame(width: 150, alignment: .trailing)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        HStack {
                            TextField(title, text: Binding {
                                values[index]
                            } set: { updated in
                                values[index] = updated
                            })
                            .textFieldStyle(.roundedBorder)
                            Button {
                                values.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Value", text: $newValue)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else {
                                return
                            }
                            values.append(trimmed)
                            newValue = ""
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: 420)
            }
        }
    }
}

private struct HorizontalRuleTrackWidthsEditor: View {
    @Binding var widths: JSONDictionary
    var context: HorizontalBoardRuleContext

    var body: some View {
        GroupBox("Widths") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("")
                        .frame(width: 150)
                    Text("Layer")
                        .frame(width: 130, alignment: .leading)
                    Text("Min")
                        .frame(width: 90, alignment: .leading)
                    Text("Default")
                        .frame(width: 90, alignment: .leading)
                    Text("Max")
                        .frame(width: 90, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(widthLayerKeys, id: \.self) { key in
                    HStack {
                        Text("")
                            .frame(width: 150)
                        Text(layerName(key))
                            .frame(width: 130, alignment: .leading)
                        HorizontalInlineMMField(value: widthMMBinding(layerKey: key, field: "min", defaultNanometers: 100_000))
                        HorizontalInlineMMField(value: widthMMBinding(layerKey: key, field: "def", defaultNanometers: 200_000))
                        HorizontalInlineMMField(value: widthMMBinding(layerKey: key, field: "max", defaultNanometers: 10_000_000))
                    }
                }

                HStack {
                    Spacer()
                        .frame(width: 150)
                    Button("Add current copper layers") {
                        for layer in context.copperLayers {
                            let key = String(layer)
                            if widths[key] == nil {
                                widths[key] = ["min": 100_000, "def": 200_000, "max": 10_000_000] as JSONDictionary
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var widthLayerKeys: [String] {
        let preferred = context.copperLayers.map(String.init)
        let existing = Array(widths.keys)
        return Array(Set(preferred + existing)).sorted { lhs, rhs in
            (Int(lhs) ?? 0) > (Int(rhs) ?? 0)
        }
    }

    private func layerName(_ key: String) -> String {
        guard let layer = Int(key) else {
            return key
        }
        return context.layerName(layer)
    }

    private func widthMMBinding(layerKey: String, field: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            let layer = widths[layerKey] as? JSONDictionary
            return Double(layer?.int(field) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            var layer = widths[layerKey] as? JSONDictionary ?? [:]
            layer[field] = Int((value * 1_000_000.0).rounded())
            widths[layerKey] = layer
        }
    }
}

private struct HorizontalInlineMMField: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
            Text("mm")
                .foregroundStyle(.secondary)
        }
        .frame(width: 90, alignment: .leading)
    }
}

private struct HorizontalSteppedMMField: View {
    @Binding var value: Double
    var step: Double = 0.025
    var width: CGFloat = 132

    var body: some View {
        HStack(spacing: 0) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .frame(width: width - 52)
            Text("mm")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.trailing, 6)
            Stepper("", value: $value, in: 0...100, step: step)
                .labelsHidden()
                .frame(width: 46)
        }
        .frame(width: width, height: 28)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct HorizontalRuleClearanceCopperEditor: View {
    @Binding var rule: JSONDictionary
    var context: HorizontalBoardRuleContext
    @State private var setValue = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Scope") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("1st Match")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalRuleMatchInlineEditor(match: dictionaryBinding("match_1", default: context.defaultMatch()), context: context)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("2nd Match")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalRuleMatchInlineEditor(match: dictionaryBinding("match_2", default: context.defaultMatch()), context: context)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text("Layer")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalInlineLayerPicker(value: intBinding("layer", default: horizonRuleAnyLayer), context: context)
                        Text("Routing offset")
                            .foregroundStyle(.secondary)
                        HorizontalSteppedMMField(value: mmBinding("routing_offset", defaultNanometers: 50_000))
                    }
                }
                .padding(8)
            }

            HorizontalRuleClearanceMatrixEditor(clearances: arrayBinding("clearances"), setValue: $setValue)
        }
    }

    private func dictionaryBinding(_ key: String, default defaultValue: JSONDictionary) -> Binding<JSONDictionary> {
        Binding {
            rule.dictionary(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding {
            rule.int(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func mmBinding(_ key: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            Double(rule.int(key) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            rule[key] = Int((value * 1_000_000.0).rounded())
        }
    }

    private func arrayBinding(_ key: String) -> Binding<[Any]> {
        Binding {
            rule[key] as? [Any] ?? []
        } set: { value in
            rule[key] = value
        }
    }
}

private struct HorizontalRuleClearanceCopperOtherEditor: View {
    @Binding var rule: JSONDictionary
    var context: HorizontalBoardRuleContext
    @State private var setValue = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Scope") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Mode")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalRuleMatchInlineEditor(match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text("Layer")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalInlineLayerPicker(value: intBinding("layer", default: horizonRuleAnyLayer), context: context)
                    }
                }
                .padding(8)
            }

            GroupBox("Routing") {
                HStack(alignment: .center, spacing: 12) {
                    Text("Routing offset")
                        .frame(width: 112, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    HorizontalSteppedMMField(value: mmBinding("routing_offset", defaultNanometers: 50_000))
                }
                .padding(8)
            }

            HorizontalRuleClearanceCopperOtherMatrixEditor(clearances: arrayBinding("clearances"), setValue: $setValue)
        }
    }

    private func dictionaryBinding(_ key: String, default defaultValue: JSONDictionary) -> Binding<JSONDictionary> {
        Binding {
            rule.dictionary(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding {
            rule.int(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func mmBinding(_ key: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            Double(rule.int(key) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            rule[key] = Int((value * 1_000_000.0).rounded())
        }
    }

    private func arrayBinding(_ key: String) -> Binding<[Any]> {
        Binding {
            rule[key] as? [Any] ?? []
        } set: { value in
            rule[key] = value
        }
    }
}

private struct HorizontalRuleClearanceCopperKeepoutEditor: View {
    @Binding var rule: JSONDictionary
    var context: HorizontalBoardRuleContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Scope") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Match")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalRuleMatchInlineEditor(match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("Keepout")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalRuleMatchKeepoutInlineEditor(match: dictionaryBinding("match_keepout", default: HorizontalBoardRuleContext.defaultKeepoutMatch()))
                    }
                }
                .padding(8)
            }

            GroupBox("Routing") {
                HStack(alignment: .center, spacing: 12) {
                    Text("Routing offset")
                        .frame(width: 112, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    HorizontalSteppedMMField(value: mmBinding("routing_offset", defaultNanometers: 50_000))
                }
                .padding(8)
            }

            HorizontalRuleCopperKeepoutClearancesEditor(clearances: dictionaryBinding("clearances", default: JSONDictionary()))
        }
    }

    private func dictionaryBinding(_ key: String, default defaultValue: JSONDictionary) -> Binding<JSONDictionary> {
        Binding {
            rule.dictionary(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func mmBinding(_ key: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            Double(rule.int(key) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            rule[key] = Int((value * 1_000_000.0).rounded())
        }
    }
}

private struct HorizontalRuleClearanceSameNetEditor: View {
    @Binding var rule: JSONDictionary
    var context: HorizontalBoardRuleContext
    @State private var setValue = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Scope") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Mode")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalRuleMatchInlineEditor(match: dictionaryBinding("match", default: context.defaultMatch()), context: context)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text("Layer")
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalInlineLayerPicker(value: intBinding("layer", default: horizonRuleAnyLayer), context: context)
                    }
                }
                .padding(8)
            }

            HorizontalRuleSameNetClearanceMatrixEditor(clearances: arrayBinding("clearances"), setValue: $setValue)
        }
    }

    private func dictionaryBinding(_ key: String, default defaultValue: JSONDictionary) -> Binding<JSONDictionary> {
        Binding {
            rule.dictionary(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding {
            rule.int(key) ?? defaultValue
        } set: { value in
            rule[key] = value
        }
    }

    private func arrayBinding(_ key: String) -> Binding<[Any]> {
        Binding {
            rule[key] as? [Any] ?? []
        } set: { value in
            rule[key] = value
        }
    }
}

private struct HorizontalRuleMatchInlineEditor: View {
    @Binding var match: JSONDictionary
    var context: HorizontalBoardRuleContext

    private let modes = [
        ("all", "All"),
        ("net", "Single net"),
        ("nets", "Multiple nets"),
        ("net_class", "Net class"),
        ("net_name_regex", "Net name regex"),
        ("net_class_regex", "Net class regex")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: stringBinding("mode", default: "all")) {
                ForEach(modes, id: \.0) { mode in
                    Text(mode.1).tag(mode.0)
                }
            }
            .labelsHidden()
            .frame(width: 220)

            switch match.string("mode") ?? "all" {
            case "net":
                Picker("Net", selection: stringBinding("net", default: horizonRuleNullUUID)) {
                    Text("None").tag(horizonRuleNullUUID)
                    ForEach(context.netOptions, id: \.id) { net in
                        Text(net.name).tag(net.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            case "nets":
                EmptyView()
            case "net_class":
                Picker("Net class", selection: stringBinding("net_class", default: context.defaultNetClassID)) {
                    ForEach(context.netClasses) { netClass in
                        Text(netClass.name).tag(netClass.id)
                    }
                    if context.netClasses.isEmpty {
                        Text("Default").tag(horizonRuleNullUUID)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            case "net_name_regex":
                TextField("Net name regex", text: stringBinding("net_name_regex", default: ""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            case "net_class_regex":
                TextField("Net class regex", text: stringBinding("net_class_regex", default: ""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            default:
                EmptyView()
            }
        }
        .frame(width: 230, alignment: .leading)
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            match.string(key) ?? defaultValue
        } set: { value in
            match[key] = value
        }
    }
}

private struct HorizontalRuleMatchKeepoutInlineEditor: View {
    @Binding var match: JSONDictionary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: stringBinding("mode", default: "all")) {
                Text("All").tag("all")
                Text("Component").tag("component")
                Text("Keepout class").tag("keepout_class")
            }
            .labelsHidden()
            .frame(width: 220)

            switch match.string("mode") ?? "all" {
            case "component":
                Text("Component keepout")
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
            case "keepout_class":
                TextField("Keepout class", text: stringBinding("keepout_class", default: ""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            default:
                EmptyView()
            }
        }
        .frame(width: 230, alignment: .leading)
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            match.string(key) ?? defaultValue
        } set: { value in
            match[key] = value
        }
    }
}

private struct HorizontalInlineLayerPicker: View {
    @Binding var value: Int
    var context: HorizontalBoardRuleContext

    var body: some View {
        Picker("Layer", selection: $value) {
            ForEach(context.layerOptions, id: \.self) { layer in
                Text(context.layerName(layer)).tag(layer)
            }
        }
        .labelsHidden()
        .frame(width: 230)
    }
}

private struct HorizontalRuleCopperKeepoutClearancesEditor: View {
    @Binding var clearances: JSONDictionary

    private let patchTypes = HorizontalRulePatchType.copperKeepoutTypes

    var body: some View {
        GroupBox("Clearances") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(patchTypes, id: \.self) { type in
                    HStack(spacing: 12) {
                        Text(type.matrixTitle)
                            .frame(width: 112, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HorizontalSteppedMMField(value: clearanceBinding(type), width: 150)
                    }
                }
            }
            .padding(8)
        }
    }

    private func clearanceBinding(_ type: HorizontalRulePatchType) -> Binding<Double> {
        Binding {
            Double(clearances.int(type.rawValue) ?? 0) / 1_000_000.0
        } set: { value in
            clearances[type.rawValue] = Int((value * 1_000_000.0).rounded())
        }
    }
}

private struct HorizontalRuleSameNetClearanceMatrixEditor: View {
    @Binding var clearances: [Any]
    @Binding var setValue: Double

    private let columnTypes = HorizontalRulePatchType.sameNetColumnTypes
    private let rowTypes = HorizontalRulePatchType.sameNetRowTypes

    var body: some View {
        GroupBox("Clearances") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("set all") {
                        setAllClearances(setValue)
                    }
                    .frame(width: 92)
                    HorizontalSteppedMMField(value: $setValue, width: 128)
                }

                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Color.clear
                                .frame(width: 116, height: 1)
                            ForEach(Array(columnTypes.enumerated()), id: \.element) { column, type in
                                HStack(spacing: 6) {
                                    Button {
                                        setColumn(column, to: setValue)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Set column")
                                    Text(type.matrixTitle)
                                        .lineLimit(1)
                                }
                                .frame(width: 190, alignment: .leading)
                            }
                        }
                        .font(.callout)

                        ForEach(Array(rowTypes.enumerated()), id: \.element) { row, rowType in
                            GridRow {
                                HStack(spacing: 6) {
                                    Text(rowType.matrixTitle)
                                        .frame(width: 84, alignment: .trailing)
                                    Button {
                                        setRow(row, to: setValue)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Set row")
                                }
                                .frame(width: 116, alignment: .trailing)

                                ForEach(Array(columnTypes.enumerated()), id: \.element) { _, columnType in
                                    if isValidPair(columnType, rowType) {
                                        HStack(spacing: 8) {
                                            Toggle("", isOn: enabledBinding(columnType, rowType))
                                                .labelsHidden()
                                                .frame(width: 18)
                                            HorizontalSteppedMMField(
                                                value: clearanceBinding(columnType, rowType),
                                                width: 162
                                            )
                                            .disabled(!isClearanceEnabled(columnType, rowType))
                                        }
                                        .frame(width: 190, alignment: .leading)
                                    } else {
                                        Color.clear
                                            .frame(width: 190, height: 28)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
        }
    }

    private func setAllClearances(_ value: Double) {
        for rowType in rowTypes {
            for columnType in columnTypes where isValidPair(columnType, rowType) && isClearanceEnabled(columnType, rowType) {
                setClearance(columnType, rowType, value)
            }
        }
    }

    private func setColumn(_ column: Int, to value: Double) {
        let columnType = columnTypes[column]
        for rowType in rowTypes where isValidPair(columnType, rowType) && isClearanceEnabled(columnType, rowType) {
            setClearance(columnType, rowType, value)
        }
    }

    private func setRow(_ row: Int, to value: Double) {
        let rowType = rowTypes[row]
        for columnType in columnTypes where isValidPair(columnType, rowType) && isClearanceEnabled(columnType, rowType) {
            setClearance(columnType, rowType, value)
        }
    }

    private func enabledBinding(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Binding<Bool> {
        Binding {
            isClearanceEnabled(first, second)
        } set: { enabled in
            if enabled {
                setClearance(first, second, 0)
            } else {
                removeClearance(first, second)
            }
        }
    }

    private func clearanceBinding(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Binding<Double> {
        Binding {
            Double(clearanceNanometers(first, second)) / 1_000_000.0
        } set: { value in
            setClearance(first, second, value)
        }
    }

    private func isValidPair(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Bool {
        guard let firstIndex = HorizontalRulePatchType.sameNetTypes.firstIndex(of: first),
              let secondIndex = HorizontalRulePatchType.sameNetTypes.firstIndex(of: second) else {
            return false
        }
        return firstIndex < secondIndex
    }

    private func isClearanceEnabled(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Bool {
        guard let index = clearanceIndex(first, second),
              let item = clearances[index] as? JSONDictionary else {
            return false
        }
        return (item.int("clearance") ?? -1) >= 0
    }

    private func clearanceNanometers(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Int {
        guard let index = clearanceIndex(first, second),
              let item = clearances[index] as? JSONDictionary else {
            return 0
        }
        return max(item.int("clearance") ?? 0, 0)
    }

    private func setClearance(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType, _ value: Double) {
        let pair = HorizontalRulePatchType.serializedPair(first, second)
        let clearance = Int((value * 1_000_000.0).rounded())
        if let index = clearanceIndex(first, second) {
            var item = clearances[index] as? JSONDictionary ?? [:]
            item["types"] = pair.map(\.rawValue)
            item["clearance"] = clearance
            clearances[index] = item
        } else {
            clearances.append([
                "types": pair.map(\.rawValue),
                "clearance": clearance
            ] as JSONDictionary)
        }
    }

    private func removeClearance(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) {
        guard let index = clearanceIndex(first, second) else {
            return
        }
        clearances.remove(at: index)
    }

    private func clearanceIndex(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Int? {
        let wanted = Set([first.rawValue, second.rawValue])
        return clearances.indices.first { index in
            guard let item = clearances[index] as? JSONDictionary,
                  let types = item["types"] as? [Any] else {
                return false
            }
            return Set(types.compactMap { $0 as? String }) == wanted
        }
    }
}

private struct HorizontalRuleClearanceMatrixEditor: View {
    @Binding var clearances: [Any]
    @Binding var setValue: Double

    private let patchTypes = HorizontalRulePatchType.copperMatrixTypes

    var body: some View {
        GroupBox("Clearances") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("set all") {
                        setAllClearances(setValue)
                    }
                    .frame(width: 92)
                    HorizontalSteppedMMField(value: $setValue, width: 128)
                    Text("Use row and column buttons to copy this value into part of the matrix.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Color.clear
                                .frame(width: 104, height: 1)
                            ForEach(Array(patchTypes.enumerated()), id: \.element) { column, type in
                                HStack(spacing: 6) {
                                    Button {
                                        setColumn(column, to: setValue)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Set column")
                                    Text(type.matrixTitle)
                                        .lineLimit(1)
                                }
                                .frame(width: 132, alignment: .leading)
                            }
                        }
                        .font(.callout)

                        ForEach(Array(patchTypes.enumerated()), id: \.element) { row, rowType in
                            GridRow {
                                HStack(spacing: 6) {
                                    Text(rowType.matrixTitle)
                                        .frame(width: 72, alignment: .trailing)
                                    Button {
                                        setRow(row, to: setValue)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Set row")
                                }
                                .frame(width: 104, alignment: .trailing)

                                ForEach(Array(patchTypes.enumerated()), id: \.element) { column, columnType in
                                    if column <= row {
                                        HorizontalSteppedMMField(
                                            value: clearanceBinding(columnType, rowType),
                                            width: 132
                                        )
                                    } else {
                                        Color.clear
                                            .frame(width: 132, height: 28)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
        }
    }

    private func setAllClearances(_ value: Double) {
        for row in patchTypes.indices {
            setRow(row, to: value)
        }
    }

    private func setColumn(_ column: Int, to value: Double) {
        for row in column..<patchTypes.count {
            setClearance(patchTypes[column], patchTypes[row], value)
        }
    }

    private func setRow(_ row: Int, to value: Double) {
        for column in 0...row {
            setClearance(patchTypes[column], patchTypes[row], value)
        }
    }

    private func clearanceBinding(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Binding<Double> {
        Binding {
            Double(clearanceNanometers(first, second)) / 1_000_000.0
        } set: { value in
            setClearance(first, second, value)
        }
    }

    private func clearanceNanometers(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Int {
        guard let index = clearanceIndex(first, second),
              let item = clearances[index] as? JSONDictionary else {
            return 100_000
        }
        return item.int("clearance") ?? 100_000
    }

    private func setClearance(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType, _ value: Double) {
        let pair = HorizontalRulePatchType.serializedPair(first, second)
        let clearance = Int((value * 1_000_000.0).rounded())
        if let index = clearanceIndex(first, second) {
            var item = clearances[index] as? JSONDictionary ?? [:]
            item["types"] = pair.map(\.rawValue)
            item["clearance"] = clearance
            clearances[index] = item
        } else {
            clearances.append([
                "types": pair.map(\.rawValue),
                "clearance": clearance
            ] as JSONDictionary)
        }
    }

    private func clearanceIndex(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> Int? {
        let wanted = Set([first.rawValue, second.rawValue])
        return clearances.indices.first { index in
            guard let item = clearances[index] as? JSONDictionary,
                  let types = item["types"] as? [Any] else {
                return false
            }
            return Set(types.compactMap { $0 as? String }) == wanted
        }
    }
}

private struct HorizontalRuleClearanceCopperOtherMatrixEditor: View {
    @Binding var clearances: [Any]
    @Binding var setValue: Double

    private let copperTypes = HorizontalRulePatchType.copperOtherCopperTypes
    private let nonCopperTypes = HorizontalRulePatchType.copperOtherNonCopperTypes

    var body: some View {
        GroupBox("Clearances") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("set all") {
                        setAllClearances(setValue)
                    }
                    .frame(width: 92)
                    HorizontalSteppedMMField(value: $setValue, width: 128)
                }

                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Color.clear
                                .frame(width: 116, height: 1)
                            ForEach(Array(copperTypes.enumerated()), id: \.element) { column, type in
                                HStack(spacing: 6) {
                                    Button {
                                        setColumn(column, to: setValue)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Set column")
                                    Text(type.matrixTitle)
                                        .lineLimit(1)
                                }
                                .frame(width: 132, alignment: .leading)
                            }
                        }
                        .font(.callout)

                        ForEach(Array(nonCopperTypes.enumerated()), id: \.element) { row, rowType in
                            GridRow {
                                HStack(spacing: 6) {
                                    Text(rowType.matrixTitle)
                                        .frame(width: 84, alignment: .trailing)
                                    Button {
                                        setRow(row, to: setValue)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Set row")
                                }
                                .frame(width: 116, alignment: .trailing)

                                ForEach(Array(copperTypes.enumerated()), id: \.element) { _, columnType in
                                    HorizontalSteppedMMField(
                                        value: clearanceBinding(columnType, rowType),
                                        width: 132
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
        }
    }

    private func setAllClearances(_ value: Double) {
        for row in nonCopperTypes.indices {
            setRow(row, to: value)
        }
    }

    private func setColumn(_ column: Int, to value: Double) {
        for rowType in nonCopperTypes {
            setClearance(copperTypes[column], rowType, value)
        }
    }

    private func setRow(_ row: Int, to value: Double) {
        for columnType in copperTypes {
            setClearance(columnType, nonCopperTypes[row], value)
        }
    }

    private func clearanceBinding(_ copperType: HorizontalRulePatchType, _ nonCopperType: HorizontalRulePatchType) -> Binding<Double> {
        Binding {
            Double(clearanceNanometers(copperType, nonCopperType)) / 1_000_000.0
        } set: { value in
            setClearance(copperType, nonCopperType, value)
        }
    }

    private func clearanceNanometers(_ copperType: HorizontalRulePatchType, _ nonCopperType: HorizontalRulePatchType) -> Int {
        guard let index = clearanceIndex(copperType, nonCopperType),
              let item = clearances[index] as? JSONDictionary else {
            return 100_000
        }
        return item.int("clearance") ?? 100_000
    }

    private func setClearance(_ copperType: HorizontalRulePatchType, _ nonCopperType: HorizontalRulePatchType, _ value: Double) {
        let types = [copperType.rawValue, nonCopperType.rawValue]
        let clearance = Int((value * 1_000_000.0).rounded())
        if let index = clearanceIndex(copperType, nonCopperType) {
            var item = clearances[index] as? JSONDictionary ?? [:]
            item["types"] = types
            item["clearance"] = clearance
            clearances[index] = item
        } else {
            clearances.append([
                "types": types,
                "clearance": clearance
            ] as JSONDictionary)
        }
    }

    private func clearanceIndex(_ copperType: HorizontalRulePatchType, _ nonCopperType: HorizontalRulePatchType) -> Int? {
        let wanted = Set([copperType.rawValue, nonCopperType.rawValue])
        return clearances.indices.first { index in
            guard let item = clearances[index] as? JSONDictionary,
                  let types = item["types"] as? [Any] else {
                return false
            }
            return Set(types.compactMap { $0 as? String }) == wanted
        }
    }
}

private struct HorizontalRuleClearanceListEditor: View {
    @Binding var clearances: [Any]
    var title: String

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("")
                        .frame(width: 150)
                    Text("Type A")
                        .frame(width: 120, alignment: .leading)
                    Text("Type B")
                        .frame(width: 120, alignment: .leading)
                    Text("Clearance")
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(clearances.indices, id: \.self) { index in
                    HStack {
                        Text("")
                            .frame(width: 150)
                        Picker("", selection: typeBinding(index: index, slot: 0)) {
                            ForEach(HorizontalRulePatchType.allCases, id: \.self) { type in
                                Text(type.title).tag(type.rawValue)
                            }
                        }
                        .frame(width: 120)
                        Picker("", selection: typeBinding(index: index, slot: 1)) {
                            ForEach(HorizontalRulePatchType.allCases, id: \.self) { type in
                                Text(type.title).tag(type.rawValue)
                            }
                        }
                        .frame(width: 120)
                        HorizontalInlineMMField(value: clearanceBinding(index: index))
                        Button {
                            clearances.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    Spacer()
                        .frame(width: 150)
                    Button {
                        clearances.append(["types": ["track", "track"], "clearance": 100_000] as JSONDictionary)
                    } label: {
                        Label("Add clearance", systemImage: "plus")
                    }
                }
            }
            .padding(6)
        }
    }

    private func entry(at index: Int) -> JSONDictionary {
        clearances[index] as? JSONDictionary ?? [:]
    }

    private func typeBinding(index: Int, slot: Int) -> Binding<String> {
        Binding {
            let types = entry(at: index)["types"] as? [Any] ?? []
            return types.indices.contains(slot) ? (types[slot] as? String ?? "track") : "track"
        } set: { value in
            var item = entry(at: index)
            var types = (item["types"] as? [Any])?.compactMap { $0 as? String } ?? ["track", "track"]
            while types.count <= slot {
                types.append("track")
            }
            types[slot] = value
            item["types"] = types
            clearances[index] = item
        }
    }

    private func clearanceBinding(index: Int) -> Binding<Double> {
        Binding {
            Double(entry(at: index).int("clearance") ?? 100_000) / 1_000_000.0
        } set: { value in
            var item = entry(at: index)
            item["clearance"] = Int((value * 1_000_000.0).rounded())
            clearances[index] = item
        }
    }
}

private enum HorizontalRulePatchType: String, CaseIterable {
    case other
    case track
    case pad
    case padTH = "pad_th"
    case via
    case plane
    case holePTH = "hole_pth"
    case holeNPTH = "hole_npth"
    case boardEdge = "board_edge"
    case text
    case netTie = "net_tie"

    static let copperMatrixTypes: [HorizontalRulePatchType] = [
        .track,
        .pad,
        .padTH,
        .plane,
        .via,
        .holePTH
    ]

    static let copperOtherCopperTypes: [HorizontalRulePatchType] = [
        .track,
        .pad,
        .padTH,
        .plane,
        .via
    ]

    static let copperOtherNonCopperTypes: [HorizontalRulePatchType] = [
        .holeNPTH,
        .boardEdge,
        .other
    ]

    static let copperKeepoutTypes: [HorizontalRulePatchType] = [
        .track,
        .pad,
        .padTH,
        .plane,
        .via,
        .holePTH
    ]

    static let sameNetTypes: [HorizontalRulePatchType] = [
        .pad,
        .padTH,
        .via,
        .holeNPTH
    ]

    static let sameNetColumnTypes: [HorizontalRulePatchType] = [
        .pad,
        .padTH,
        .via
    ]

    static let sameNetRowTypes: [HorizontalRulePatchType] = [
        .padTH,
        .via,
        .holeNPTH
    ]

    static func serializedPair(_ first: HorizontalRulePatchType, _ second: HorizontalRulePatchType) -> [HorizontalRulePatchType] {
        first.serializationOrder <= second.serializationOrder ? [first, second] : [second, first]
    }

    private var serializationOrder: Int {
        switch self {
        case .other:
            return 0
        case .track:
            return 1
        case .pad:
            return 2
        case .padTH:
            return 3
        case .via:
            return 4
        case .plane:
            return 5
        case .holePTH:
            return 6
        case .holeNPTH:
            return 7
        case .boardEdge:
            return 8
        case .text:
            return 9
        case .netTie:
            return 10
        }
    }

    var matrixTitle: String {
        switch self {
        case .padTH:
            return "TH pad"
        case .holePTH:
            return "PTH hole"
        case .holeNPTH:
            return "NPTH hole"
        default:
            return title
        }
    }

    var title: String {
        switch self {
        case .other:
            return "Other"
        case .track:
            return "Track"
        case .pad:
            return "Pad"
        case .padTH:
            return "TH pad"
        case .via:
            return "Via"
        case .plane:
            return "Plane"
        case .holePTH:
            return "PTH hole"
        case .holeNPTH:
            return "Hole NPTH"
        case .boardEdge:
            return "Board edge"
        case .text:
            return "Text"
        case .netTie:
            return "Net tie"
        }
    }
}

private struct HorizontalRuleParameterSetEditor: View {
    @Binding var parameters: JSONDictionary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HorizontalRuleDimensionField(label: "Via diameter", value: mmBinding("via_diameter", defaultNanometers: 500_000))
            HorizontalRuleDimensionField(label: "Hole diameter", value: mmBinding("hole_diameter", defaultNanometers: 200_000))
        }
    }

    private func mmBinding(_ key: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            Double(parameters.int(key) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            parameters[key] = Int((value * 1_000_000.0).rounded())
        }
    }
}

private struct HorizontalRulePlaneSettingsEditor: View {
    static let settingKeys: Set<String> = [
        "connect_style", "thermal_gap_width", "thermal_spoke_width", "n_spokes", "angle",
        "min_width", "keep_orphans", "style", "text_style", "fill_style",
        "hatch_border_width", "hatch_line_spacing", "hatch_line_width"
    ]

    @Binding var settings: JSONDictionary

    var body: some View {
        GroupBox("Plane Settings") {
            HorizontalRulePlaneSettingsFields(settings: $settings)
                .padding(6)
        }
    }
}

private struct HorizontalRulePlaneSettingsFields: View {
    @Binding var settings: JSONDictionary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pickerRow("Connect style", key: "connect_style", values: ["solid", "thermal", "none"])
            pickerRow("Plane style", key: "style", values: ["round", "square"])
            pickerRow("Text style", key: "text_style", values: ["expand", "clip"])
            pickerRow("Fill style", key: "fill_style", values: ["solid", "hatch"])
            Toggle("Keep orphans", isOn: boolBinding("keep_orphans", default: false))
                .padding(.leading, 154)
            HorizontalRuleDimensionField(label: "Minimum width", value: mmBinding("min_width", defaultNanometers: 200_000))
            HorizontalRuleDimensionField(label: "Thermal gap", value: mmBinding("thermal_gap_width", defaultNanometers: 200_000))
            HorizontalRuleDimensionField(label: "Thermal spoke", value: mmBinding("thermal_spoke_width", defaultNanometers: 200_000))
            HorizontalRuleIntField(label: "Spokes", value: intBinding("n_spokes", default: 4))
            HorizontalRuleIntField(label: "Spoke angle", value: intBinding("angle", default: 0))
            HorizontalRuleDimensionField(label: "Hatch border", value: mmBinding("hatch_border_width", defaultNanometers: 500_000))
            HorizontalRuleDimensionField(label: "Hatch spacing", value: mmBinding("hatch_line_spacing", defaultNanometers: 500_000))
            HorizontalRuleDimensionField(label: "Hatch width", value: mmBinding("hatch_line_width", defaultNanometers: 200_000))
        }
    }

    private func pickerRow(_ label: String, key: String, values: [String]) -> some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .trailing)
                .foregroundStyle(.secondary)
            Picker(label, selection: stringBinding(key, default: values.first ?? "")) {
                ForEach(values, id: \.self) { value in
                    Text(value.capitalized).tag(value)
                }
            }
            .frame(maxWidth: 220)
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            settings.string(key) ?? defaultValue
        } set: { value in
            settings[key] = value
        }
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding {
            settings.bool(key) ?? defaultValue
        } set: { value in
            settings[key] = value
        }
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding {
            settings.int(key) ?? defaultValue
        } set: { value in
            settings[key] = value
        }
    }

    private func mmBinding(_ key: String, defaultNanometers: Int) -> Binding<Double> {
        Binding {
            Double(settings.int(key) ?? defaultNanometers) / 1_000_000.0
        } set: { value in
            settings[key] = Int((value * 1_000_000.0).rounded())
        }
    }
}

private struct HorizontalRuleViaDefinitionsEditor: View {
    @Binding var viaDefinitions: JSONDictionary
    var context: HorizontalBoardRuleContext
    @State private var selectedID: String?

    var body: some View {
        GroupBox("Via Definitions") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HorizontalSelectionList(
                        selection: $selectedID,
                        items: definitionIDs,
                        id: { $0 }
                    ) { id in
                        Text(definitionName(id))
                    }
                    HStack {
                        Button {
                            addDefinition()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            removeDefinition()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .disabled(selectedID == nil)
                    }
                }
                .frame(width: 220)

                Divider()

                if let selectedID {
                    VStack(alignment: .leading, spacing: 10) {
                        HorizontalRuleTextField(label: "Name", value: definitionStringBinding(id: selectedID, key: "name", default: "Via"))
                        HorizontalRuleTextField(label: "Padstack", value: definitionStringBinding(id: selectedID, key: "padstack", default: ""))
                        HorizontalRuleLayerRangeEditor(title: "Span", span: definitionDictionaryBinding(id: selectedID, key: "span", default: ["start": HorizontalBoardLayers.topCopper, "end": HorizontalBoardLayers.bottomCopper]), context: context)
                        HorizontalRuleParameterSetEditor(parameters: definitionDictionaryBinding(id: selectedID, key: "parameters", default: ["via_diameter": 500_000, "hole_diameter": 200_000]))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a via definition.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(6)
            .frame(minHeight: 260)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = definitionIDs.first
            }
        }
    }

    private var definitionIDs: [String] {
        viaDefinitions.keys.sorted {
            definitionName($0).localizedStandardCompare(definitionName($1)) == .orderedAscending
        }
    }

    private func definitionName(_ id: String) -> String {
        (viaDefinitions[id] as? JSONDictionary)?.string("name") ?? "Via definition"
    }

    private func addDefinition() {
        let id = UUID().uuidString.lowercased()
        viaDefinitions[id] = [
            "name": "Via",
            "padstack": "",
            "parameters": ["via_diameter": 500_000, "hole_diameter": 200_000] as JSONDictionary,
            "span": ["start": HorizontalBoardLayers.topCopper, "end": HorizontalBoardLayers.bottomCopper] as JSONDictionary
        ] as JSONDictionary
        selectedID = id
    }

    private func removeDefinition() {
        guard let selectedID else {
            return
        }
        viaDefinitions.removeValue(forKey: selectedID)
        self.selectedID = definitionIDs.first
    }

    private func definitionStringBinding(id: String, key: String, default defaultValue: String) -> Binding<String> {
        Binding {
            (viaDefinitions[id] as? JSONDictionary)?.string(key) ?? defaultValue
        } set: { value in
            var definition = viaDefinitions[id] as? JSONDictionary ?? [:]
            definition[key] = value
            viaDefinitions[id] = definition
        }
    }

    private func definitionDictionaryBinding(id: String, key: String, default defaultValue: JSONDictionary) -> Binding<JSONDictionary> {
        Binding {
            (viaDefinitions[id] as? JSONDictionary)?.dictionary(key) ?? defaultValue
        } set: { value in
            var definition = viaDefinitions[id] as? JSONDictionary ?? [:]
            definition[key] = value
            viaDefinitions[id] = definition
        }
    }
}

private struct HorizontalRuleLayerRangeEditor: View {
    var title: String
    @Binding var span: JSONDictionary
    var context: HorizontalBoardRuleContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HorizontalRuleLayerPicker(label: "\(title) start", value: intBinding("start", default: HorizontalBoardLayers.topCopper), context: context)
            HorizontalRuleLayerPicker(label: "\(title) end", value: intBinding("end", default: HorizontalBoardLayers.bottomCopper), context: context)
        }
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding {
            span.int(key) ?? defaultValue
        } set: { value in
            span[key] = value
        }
    }
}

private struct HorizontalRuleLayerPairEditor: View {
    @Binding var layers: [Any]
    var context: HorizontalBoardRuleContext

    var body: some View {
        GroupBox("Layer Pair") {
            VStack(alignment: .leading, spacing: 10) {
                HorizontalRuleLayerPicker(label: "Start layer", value: layerBinding(index: 0, defaultValue: HorizontalBoardLayers.topCopper), context: context)
                HorizontalRuleLayerPicker(label: "End layer", value: layerBinding(index: 1, defaultValue: HorizontalBoardLayers.bottomCopper), context: context)
            }
            .padding(6)
        }
    }

    private func layerBinding(index: Int, defaultValue: Int) -> Binding<Int> {
        Binding {
            guard layers.indices.contains(index) else {
                return defaultValue
            }
            if let value = layers[index] as? Int {
                return value
            }
            if let value = layers[index] as? Double {
                return Int(value)
            }
            return defaultValue
        } set: { value in
            while layers.count <= index {
                layers.append(defaultValue)
            }
            layers[index] = value
        }
    }
}

private struct TextRuleExplanation: View {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        GroupBox("GTK Rule") {
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

private struct HorizontalBoardRuleChecksView: View {
    var messages: [HorizontalBoardRuleCheckMessage]
    var kind: HorizontalBoardRuleKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Checks")
                    .font(.headline)
                Spacer()
                Text(kind.title)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if messages.isEmpty {
                ContentUnavailableView(
                    "No Structural Issues",
                    systemImage: "checkmark.seal",
                    description: Text("The native rules editor validated the serialized rule structure.")
                )
            } else {
                List(messages) { message in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.title)
                            Text(message.detail)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    } icon: {
                        Image(systemName: message.level.iconName)
                            .foregroundStyle(message.level.color)
                    }
                }
            }

            Text("Full geometric DRC/apply execution still belongs to the board engine. This panel mirrors GTK's check affordance and validates the rule objects that will be written back to board.json.")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(16)
        }
    }
}

struct HorizontalBoardRulesResultState {
    var ruleTitle: String
    var messages: [HorizontalBoardRuleCheckMessage]
    var checkedAt: Date
}

struct HorizontalBoardRuleCheckMessage: Identifiable {
    enum Level {
        case warning
        case error

        var iconName: String {
            switch self {
            case .warning:
                return "exclamationmark.triangle"
            case .error:
                return "xmark.octagon"
            }
        }

        var color: Color {
            switch self {
            case .warning:
                return .orange
            case .error:
                return .red
            }
        }
    }

    var id = UUID()
    var level: Level
    var title: String
    var detail: String
}

private enum HorizontalBoardRulesValidator {
    static func validate(
        rules: JSONDictionary,
        selectedKind: HorizontalBoardRuleKind,
        context: HorizontalBoardRuleContext
    ) -> [HorizontalBoardRuleCheckMessage] {
        var messages = [HorizontalBoardRuleCheckMessage]()

        for kind in HorizontalBoardRuleKind.visibleCases {
            if kind.isMulti, rules[kind.rawValue] != nil, !(rules[kind.rawValue] is JSONDictionary) {
                messages.append(.init(level: .error, title: "\(kind.title) is not an object", detail: "GTK expects a keyed object for multi-rule families."))
            }
            if kind.needsMatchAll && kind.isMulti {
                let count = kind.instances(in: rules, context: context).count
                if count == 0 {
                    messages.append(.init(level: .warning, title: "\(kind.title) has no catch-all rule", detail: "GTK warns that the last \(kind.title) rule should match all targets."))
                } else if !kind.lastRuleIsCatchAll(in: rules) {
                    messages.append(.init(level: .warning, title: "\(kind.title) catch-all is missing", detail: "The last rule should match all nets and any layer where applicable."))
                }
            }
        }

        if let bucket = rules[selectedKind.rawValue] as? JSONDictionary, selectedKind.isMulti {
            for (_, value) in bucket {
                guard let rule = value as? JSONDictionary else {
                    messages.append(.init(level: .error, title: "Invalid rule instance", detail: "Rule instance is not a JSON object."))
                    continue
                }
                if rule.bool("enabled") == nil {
                    messages.append(.init(level: .warning, title: "Rule instance has no enabled flag", detail: "GTK serializes every rule instance with enabled=true or enabled=false."))
                }
            }
        }

        return messages
    }
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String, fallback: Int) -> Int {
        int(key) ?? fallback
    }
}

/// Cross-platform single-selection list.
///
/// `List(selection:)` with a single optional selection binding plus a
/// `@ViewBuilder` content closure is only available on macOS. On macOS this
/// helper forwards directly to that initializer so the editor behaves
/// byte-identically. On iOS the same initializer is unavailable, so the rows
/// are rendered in a plain `List` and selection is driven by a tap gesture with
/// an accent-tinted highlight, preserving tap-to-select behavior.
///
/// Selection is modeled as an optional binding. Call sites that use a
/// non-optional selection can bridge via `Binding` (an empty/`nil` write is
/// simply ignored, matching the non-optional semantics).
private struct HorizontalSelectionList<SelectionValue: Hashable, Item, RowContent: View>: View {
    @Binding var selection: SelectionValue?
    var items: [Item]
    var id: (Item) -> SelectionValue
    var rowContent: (Item) -> RowContent

    init(
        selection: Binding<SelectionValue?>,
        items: [Item],
        id: @escaping (Item) -> SelectionValue,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        _selection = selection
        self.items = items
        self.id = id
        self.rowContent = rowContent
    }

    private struct IdentifiedItem: Identifiable {
        var id: SelectionValue
        var value: Item
    }

    private var identifiedItems: [IdentifiedItem] {
        items.map { IdentifiedItem(id: id($0), value: $0) }
    }

    var body: some View {
        #if os(macOS)
        List(selection: $selection) {
            ForEach(identifiedItems) { entry in
                rowContent(entry.value)
                    .tag(entry.id)
            }
        }
        #else
        List {
            ForEach(identifiedItems) { entry in
                rowContent(entry.value)
                    .listRowBackground(
                        selection == entry.id ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = entry.id
                    }
            }
        }
        #endif
    }
}
