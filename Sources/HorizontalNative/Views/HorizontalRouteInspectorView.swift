import Foundation
import SwiftUI

/// What the route inspector shows while a track is being routed: the layer
/// and net, the width and where it comes from, the clearance kept from each
/// kind of thing and the rule it comes from, and how close the route is to
/// what it passes.
struct HorizontalRouteInspectorState: Equatable {
    struct LayerOption: Identifiable, Equatable {
        var id: Int
        var title: String
    }

    /// The track width rule that takes the route's net, on its layer.
    struct WidthRule: Equatable {
        var id: String
        var brief: String
        var layer: Int
        var widths: HorizontalRuleTrackWidth.Widths
    }

    /// The via V drops on the route, and the via rule that would shape it.
    struct Via: Equatable {
        /// Its size, nil where V drops none: no via rule takes the net, or
        /// the one that does names no padstack.
        var diameter: Double?
        var holeDiameter: Double?
        /// The tool settings give it a size of its own.
        var isCustom: Bool
        var isArmed: Bool
        /// The first enabled via rule that takes the route's net.
        var rule: HorizontalRuleVia?
        var ruleBrief: String?
        /// The size the rule gives, where it gives one.
        var ruleDiameter: Double?
        var ruleHoleDiameter: Double?
        /// The padstack a new via rule takes: the board's default via.
        var defaultPadstackID: String

        var canDrop: Bool { diameter != nil }
    }

    var hasStarted: Bool
    var isRouterMode: Bool
    var layer: Int
    var layerOptions: [LayerOption]
    var netName: String?
    var netClassName: String?
    var width: Double
    var widthSource: HorizontalRouteWidthSource
    var widthRule: WidthRule?
    /// What the rules would give, where the width isn't theirs.
    var ruleWidth: Double
    var spacing: HorizontalRouteSpacing
    var nearest: [HorizontalRouteClearanceProbe.Measurement]
    var nearestRadius: Double
    var via: Via
    /// The route's net's diff pair, where it is in one.
    var diffpair: Diffpair? = nil

    /// A pair's partner and the diffpair rule taking the pair on the
    /// route's layer (`HorizontalBoardRules.diffpair`).
    struct Diffpair: Equatable {
        var partnerName: String
        var isPrimary: Bool
        var rule: HorizontalRuleDiffpair?
        /// "Net class HS on any layer".
        var ruleBrief: String?
        /// The copper clearance the rules ask between the two nets' tracks
        /// on the layer, which the pair's own gap has to keep too.
        var clearance: Double

        /// The gap the pair routes at: the rule's, or the clearance where
        /// that is wider, since the rules check holds the two nets to it.
        var gap: Double? {
            rule.map { max($0.trackGap, clearance) }
        }

        var gapWarning: String? {
            guard let rule, rule.trackGap < clearance else { return nil }
            return "The rule's \(HorizontalRouteInspectorState.millimetres(rule.trackGap)) gap is less than the "
                + "\(HorizontalRouteInspectorState.millimetres(clearance)) clearance between the two nets, which the pair keeps."
        }
    }

    var layerName: String {
        layerOptions.first { $0.id == layer }?.title ?? HorizontalBoardLayers.name(for: layer)
    }

    /// Where the width comes from, in a sentence.
    var widthSourceText: String {
        switch widthSource {
        case .custom:
            return "A custom width, set with W or here. A route that starts on a pad or a track takes the rules' or the track's again."
        case .track:
            return "The width of the track the route started on, which it continues."
        case .rule:
            if let widthRule {
                return "Track width rule \(widthRule.brief), on \(layerName)."
            }
            return "A track width rule, on \(layerName)."
        case .existingTracks:
            return "No track width rule takes this net: the width most of its tracks have."
        case .fallback:
            return "No track width rule takes this net: RuleTrackWidth's 0.2 mm."
        }
    }

    /// A width outside the range the rule allows.
    var widthWarning: String? {
        guard let widthRule else {
            return nil
        }
        if width < widthRule.widths.min {
            return "Narrower than the rule's \(Self.millimetres(widthRule.widths.min)) minimum."
        }
        if width > widthRule.widths.max {
            return "Wider than the rule's \(Self.millimetres(widthRule.widths.max)) maximum."
        }
        return nil
    }

    static func millimetres(_ nanometres: Double) -> String {
        (nanometres / 1_000_000).formatted(.number.precision(.fractionLength(3))) + " mm"
    }
}

/// What the inspector shows while the tune tool is in use: the track being
/// tuned, its net's length now, the target and where it comes from, and what
/// the meander under the cursor makes of it.
struct HorizontalTuneInspectorState: Equatable {
    enum TargetSource: Equatable {
        /// The Length Tuning window's reference row.
        case reference
        /// Typed, with Return or here.
        case typed
        /// Neither: the window has no reference.
        case none
    }

    var netName: String?
    var layerName: String?
    var netLength: Double?
    var target: Double?
    var targetSource: TargetSource
    var tunedLength: Double?
    var cells = 0
    var blocked = 0
    /// What the tune does or why it doesn't, in a sentence.
    var status: String
    var isShort = false

    static func waiting(target: Double?, source: TargetSource) -> HorizontalTuneInspectorState {
        HorizontalTuneInspectorState(target: target, targetSource: source,
                                     status: "Click a straight track where the meander should start.")
    }
}

/// Everything the inspector's state is made from, gathered by the canvas.
struct HorizontalRouteInspectorInput {
    var board: HorizontalBoard
    var netClasses: [HorizontalNetClass]
    var layer: Int
    var netID: String?
    var width: Double
    var widthSource: HorizontalRouteWidthSource
    var hasStarted: Bool
    var isRouterMode: Bool
    /// The route as previewed, as polylines; a single point before it starts.
    var route: [[HorizontalPoint]]
    /// Where the route meets copper it is meant to: its start, and while it
    /// has no net the copper its next click would join.
    var connecting: [HorizontalPoint]
    /// The via V drops, as the canvas shapes it (`routeVia`), nil for none.
    var via: HorizontalBoardViaTemplate?
    var viaArmed: Bool
    /// The tool settings give the via a size of its own.
    var customVia: Bool
    /// Counts changes to the board's rules, so what is worked out from them
    /// is worked out again.
    var rulesRevision: Int
}

/// A change the inspector asks of whoever shows it.
enum HorizontalRouteInspectorCommand: Equatable {
    /// The layer a route that hasn't started yet goes on.
    case selectLayer(Int)
    /// The width from the rules again, rather than a custom one or the
    /// width of the track the route started on.
    case useRuleWidth
    /// A custom width, for this route and the next.
    case useCustomWidth(Double)
    /// The via the via rules give again, rather than one of the tool's size.
    case useRuleVia
    /// A via of this size, for this route and the next.
    case useCustomVia(diameter: Double, holeDiameter: Double)
    case editRule(HorizontalRouteRuleEdit)
    /// Open the board's rules at a rule.
    case showRules(HorizontalBoardRuleKind, ruleID: String?)
}

/// The canvas's part of `HorizontalRouteInspectorCommand.useRuleWidth`: give
/// the route in progress the rules' width.
struct HorizontalRouteWidthCommand: Equatable {
    var id = UUID()
}

/// Shared by the board canvas, which feeds it, and the sidebar, which shows
/// it. The canvas holds it without observing it and the host holds it in
/// plain state, so a cursor move redraws the inspector alone.
@MainActor
final class HorizontalRouteInspectorModel: ObservableObject {
    @Published private(set) var state: HorizontalRouteInspectorState?
    /// The track tool is in use; the host shows the inspector while it is.
    @Published private(set) var isRouting = false
    /// The tune tool's state while it is in use, when the inspector shows it
    /// in the route's place; the host shows the inspector as for a route.
    @Published private(set) var tune: HorizontalTuneInspectorState?

    private var probe: HorizontalRouteClearanceProbe?
    private var spacingCache: (key: String, spacing: HorizontalRouteSpacing)?
    private var pending: HorizontalRouteInspectorInput?
    private var flushTask: Task<Void, Never>?
    private var lastFlush = Date.distantPast
    /// At most this often: the cursor moves far faster than anyone reads.
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0 / 30.0) {
        self.interval = interval
    }

    /// The track tool started on `board`: what a route is measured against is
    /// the board as it is now.
    func beginRoute(on board: HorizontalBoard) {
        probe = HorizontalRouteClearanceProbe(board: board)
        spacingCache = nil
        if !isRouting {
            isRouting = true
        }
    }

    /// The tune tool started, or its state changed.
    func updateTune(_ tune: HorizontalTuneInspectorState) {
        if self.tune != tune {
            self.tune = tune
        }
        if !isRouting {
            isRouting = true
        }
    }

    /// The track tool ended, or the tune tool.
    func endRoute() {
        if tune != nil {
            tune = nil
        }
        flushTask?.cancel()
        flushTask = nil
        pending = nil
        probe = nil
        spacingCache = nil
        if state != nil {
            state = nil
        }
        if isRouting {
            isRouting = false
        }
    }

    func update(_ input: HorizontalRouteInspectorInput) {
        guard isRouting else {
            return
        }
        pending = input
        guard flushTask == nil else {
            return
        }
        let wait = max(0, interval - Date().timeIntervalSince(lastFlush))
        flushTask = Task { @MainActor [weak self] in
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Works the pending input out now, rather than at the next tick.
    func flush() {
        flushTask = nil
        guard let input = pending, isRouting else {
            return
        }
        pending = nil
        lastFlush = Date()
        let next = makeState(input)
        if next != state {
            state = next
        }
    }

    func makeState(_ input: HorizontalRouteInspectorInput) -> HorizontalRouteInspectorState {
        let board = input.board
        let rules = board.rules
        let names = HorizontalRouteRuleNames(netDetails: board.netDetails, netClasses: input.netClasses)
        let net = input.netID?.lowercased()
        let details = net.flatMap { board.netDetails[$0] }

        let layers = board.stackupLayers.map(\.layer).filter(HorizontalBoardLayers.isCopper).sorted(by: >)
        let layerOptions = (layers.isEmpty ? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper] : layers)
            .map { HorizontalRouteInspectorState.LayerOption(id: $0, title: HorizontalBoardLayers.name(for: $0)) }

        let widthRule = rules.trackWidth(net: net, layer: input.layer).map {
            HorizontalRouteInspectorState.WidthRule(
                id: $0.rule.id, brief: names.match($0.rule.match), layer: input.layer, widths: $0.widths)
        }
        let ruleWidth = HorizontalRouteWidth.fromRules(net: net, layer: input.layer, rules: rules, tracks: board.tracks).width

        let keepoutClasses = Array(Set(board.keepouts
            .filter { $0.copperPatchTypes.isEmpty || $0.copperPatchTypes.contains("track") }
            .map(\.keepoutClass))).sorted()
        let spacingKey = "\(net ?? "-")|\(input.layer)|\(input.rulesRevision)|\(keepoutClasses)"
        let spacing: HorizontalRouteSpacing
        if let cached = spacingCache, cached.key == spacingKey {
            spacing = cached.spacing
        } else {
            let otherNets: [String?] = board.netDetails.keys.map { $0.lowercased() }.filter { $0 != net }.sorted() + [nil]
            spacing = HorizontalRouteSpacing.make(
                net: net, layer: input.layer, rules: rules, otherNets: otherNets,
                keepoutClasses: keepoutClasses, names: names)
            spacingCache = (spacingKey, spacing)
        }

        let widest = spacing.rows.map(\.clearance).max() ?? 0
        let radius = max(1_000_000, 4 * widest)
        var nearest = [HorizontalRouteClearanceProbe.Measurement]()
        if let probe, !input.route.isEmpty {
            var copperRules = [String: HorizontalRuleClearanceCopper]()
            nearest = probe.nearest(
                route: input.route, width: input.width, layer: input.layer, net: net,
                connecting: input.connecting, radius: radius
            ) { item in
                switch item.kind {
                case .track, .pad, .padThroughHole, .via:
                    let key = item.netID ?? ""
                    let rule = copperRules[key] ?? rules.clearanceCopper(net1: net, net2: item.netID, layer: input.layer)
                    copperRules[key] = rule
                    let brief = rule.id.isEmpty
                        ? "no rule"
                        : "\(names.match(rule.match1)) / \(names.match(rule.match2))"
                    return (Double(rule.clearance(.track, item.kind.patchType)), Double(rule.routingOffset),
                            "copper clearance \(brief)")
                case .hole, .boardEdge:
                    let rule = rules.clearanceCopperOther(net: net, layer: input.layer)
                    let brief = rule.id.isEmpty ? "no rule" : names.match(rule.match)
                    return (Double(rule.clearance(copper: .track, nonCopper: item.kind.patchType)),
                            Double(rule.routingOffset), "copper–other clearance \(brief)")
                case .keepout(let keepoutClass):
                    let rule = rules.clearanceCopperKeepout(net: net, keepoutClass: keepoutClass)
                    return (Double(rule.clearance(.track)), Double(rule.routingOffset),
                            rule.id.isEmpty ? "no keepout rule" : "keepout clearance")
                }
            }
            nearest = nearest.map { measurement in
                var measurement = measurement
                if let netID = measurement.netID, let name = board.netDetails[netID]?.name, !name.isEmpty {
                    measurement.label += " · \(name)"
                }
                return measurement
            }
        }

        return HorizontalRouteInspectorState(
            hasStarted: input.hasStarted,
            isRouterMode: input.isRouterMode,
            layer: input.layer,
            layerOptions: layerOptions,
            netName: details.map { $0.name.isEmpty ? String($0.id.prefix(8)) : $0.name } ?? input.netID.map { String($0.prefix(8)) },
            netClassName: details?.netClassName,
            width: input.width,
            widthSource: input.widthSource,
            widthRule: widthRule,
            ruleWidth: ruleWidth,
            spacing: spacing,
            nearest: nearest,
            nearestRadius: radius,
            via: viaState(input, names: names),
            diffpair: diffpairState(input)
        )
    }

    private func diffpairState(_ input: HorizontalRouteInspectorInput) -> HorizontalRouteInspectorState.Diffpair? {
        let board = input.board
        guard let net = input.netID?.lowercased(), let detail = board.netDetails[net], let partner = detail.diffpairID else {
            return nil
        }
        let rule = board.rules.diffpair(net: net, layer: input.layer)
        let brief = rule.map { rule -> String in
            let className = input.netClasses.first { $0.id.lowercased() == rule.netClassID }?.name ?? String(rule.netClassID.prefix(8))
            let layer = rule.layer == 10000 ? "any layer" : HorizontalBoardLayers.name(for: rule.layer)
            return "Net class \(className) on \(layer)"
        }
        let clearance = board.rules.clearanceCopper(net1: net, net2: partner, layer: input.layer).clearance(.track, .track)
        let partnerName = board.netDetails[partner].map { $0.name.isEmpty ? String($0.id.prefix(8)) : $0.name } ?? String(partner.prefix(8))
        return HorizontalRouteInspectorState.Diffpair(
            partnerName: partnerName, isPrimary: detail.isDiffpairPrimary, rule: rule, ruleBrief: brief,
            clearance: Double(clearance))
    }

    private func viaState(_ input: HorizontalRouteInspectorInput, names: HorizontalRouteRuleNames) -> HorizontalRouteInspectorState.Via {
        let board = input.board
        let net = input.netID?.lowercased()
        let rule = board.rules.via(net: net)
        let ruled = BoardTrackRouting.routeVia(netID: net, rules: board.rules, template: board.viaTemplate)
        return HorizontalRouteInspectorState.Via(
            diameter: input.via?.diameter,
            holeDiameter: input.via?.holeDiameter,
            isCustom: input.customVia && input.via != nil,
            isArmed: input.viaArmed,
            rule: rule,
            ruleBrief: rule.map { names.match($0.match) },
            ruleDiameter: ruled?.diameter,
            ruleHoleDiameter: ruled?.holeDiameter,
            defaultPadstackID: board.defaultViaPadstackID
        )
    }
}

/// The route inspector: the sidebar's content while a track is routed, with
/// the track tool's own settings at the top.
struct HorizontalRouteInspectorView: View {
    @ObservedObject var model: HorizontalRouteInspectorModel
    var toolSettings: HorizontalBoardToolSettings
    var isReadOnly: Bool
    /// Whether the host can open the board's rules at a rule.
    var canShowRules = true
    var onCommand: (HorizontalRouteInspectorCommand) -> Void

    var body: some View {
        if let tune = model.tune {
            HorizontalTuneInspectorSection(state: tune, settings: toolSettings, isReadOnly: isReadOnly)
        } else {
            routeBody
        }
    }

    private var routeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HorizontalRouteToolSettingsSection(settings: toolSettings)
            Divider()
            if let state = model.state {
                HorizontalRouteInspectorContent(
                    state: state, isReadOnly: isReadOnly, canShowRules: canShowRules, onCommand: onCommand)
            } else {
                Label("Starting the route…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The tune tool's settings and readout: the meander's amplitude, spacing,
/// corners and style, the target, and what the meander under the cursor
/// reaches. The settings hold for this tune and the next.
private struct HorizontalTuneInspectorSection: View {
    var state: HorizontalTuneInspectorState
    @ObservedObject var settings: HorizontalBoardToolSettings
    var isReadOnly: Bool

    private let labelWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Meander")
                    .font(.subheadline.weight(.semibold))
                row("Style") {
                    Picker("Style", selection: $settings.meanderStyle) {
                        ForEach(HorizontalMeander.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .focusable(false)
                }
                row("Corners") {
                    Picker("Corners", selection: $settings.meanderCorner) {
                        ForEach(HorizontalMeander.Corner.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .focusable(false)
                }
                row("Amplitude") {
                    millimetreField(settings.meanderAmplitude, help: "The tallest a cell grows, baseline to join, centre to centre") {
                        if $0 > 0 { settings.meanderAmplitude = $0 }
                    }
                }
                row("Spacing") {
                    millimetreField(settings.meanderSpacing, help: "Leg centre to leg centre; the gap between legs is this less the track's width") {
                        if $0 > 0 { settings.meanderSpacing = $0 }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Target")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Target from", selection: Binding(
                        get: { settings.tuneTarget == nil },
                        set: { fromReference in
                            if fromReference {
                                settings.tuneTarget = nil
                            } else if settings.tuneTarget == nil {
                                settings.tuneTarget = state.target ?? state.netLength ?? 0
                            }
                        }
                    )) {
                        Text("Reference").tag(true)
                        Text("Custom").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .focusable(false)
                    .help("The Length Tuning window's reference length, or a length of your own (Return)")
                }
                if settings.tuneTarget != nil {
                    row("Length") {
                        millimetreField(settings.tuneTarget ?? 0, help: "The length the tune makes its net") {
                            settings.tuneTarget = $0
                        }
                    }
                } else if let target = state.target {
                    row("Reference") { Text(HorizontalLengthText.millimetres(target)) }
                } else {
                    caption("No reference: set one in the Length Tuning window (Design ▸ Length Tuning…), or type a length.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Tune")
                    .font(.subheadline.weight(.semibold))
                if let netName = state.netName {
                    row("Net") { Text(netName).fontWeight(.medium) }
                }
                if let layerName = state.layerName {
                    row("Layer") { Text(layerName) }
                }
                if let netLength = state.netLength {
                    row("Length now") { Text(HorizontalLengthText.millimetres(netLength)) }
                }
                if let tuned = state.tunedLength, state.cells > 0 {
                    row("Tuned") { Text(HorizontalLengthText.millimetres(tuned)) }
                    row("Cells") { Text(state.blocked > 0 ? "\(state.cells), \(state.blocked) blocked" : "\(state.cells)") }
                }
                Label(state.status, systemImage: state.isShort ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(state.isShort ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func millimetreField(_ nanometres: Double, help: String, onCommit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            NumericPropertyField(
                value: nanometres / 1_000_000,
                fractionDigits: 3,
                font: .callout.monospacedDigit()
            ) { millimetres in
                guard millimetres.isFinite, millimetres >= 0 else { return }
                onCommit((millimetres * 1_000_000).rounded())
            }
            .frame(width: 76)
            .disabled(isReadOnly)
            Text("mm")
                .foregroundStyle(.secondary)
        }
        .help(help)
    }
}

/// The track tool's settings, which hold for this route and the next. They
/// were the rail's Track Settings popover; the width and via it also had are
/// the inspector's Rules / Custom below.
private struct HorizontalRouteToolSettingsSection: View {
    @ObservedObject var settings: HorizontalBoardToolSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Corner style")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Corner style", selection: $settings.cornerStyle) {
                    ForEach(BoardTrackCornerStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .focusable(false)
            }
            // A click here leaves the keys with the canvas, where the route's
            // C, V, W and Esc go.
            Toggle("Route around obstacles", isOn: $settings.routerMode)
                .focusable(false)
            Toggle("Remove loops", isOn: $settings.removeLoops)
                .focusable(false)
            Toggle("Start on copper only", isOn: $settings.startsOnCopper)
                .focusable(false)
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HorizontalRouteInspectorContent: View {
    var state: HorizontalRouteInspectorState
    var isReadOnly: Bool
    var canShowRules: Bool
    var onCommand: (HorizontalRouteInspectorCommand) -> Void

    private enum WidthMode: Hashable {
        case rules
        case track
        case custom
    }

    private let labelWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            routeSection
            if let diffpair = state.diffpair {
                Divider()
                diffpairSection(diffpair)
            }
            Divider()
            widthSection
            Divider()
            viaSection
            Divider()
            clearanceSection
            Divider()
            nearestSection
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Layer and net

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Layer") {
                if state.hasStarted || isReadOnly || state.layerOptions.count < 2 {
                    Text(state.layerName)
                } else {
                    Picker("Layer", selection: Binding(
                        get: { state.layer },
                        set: { layer in
                            if layer != state.layer {
                                onCommand(.selectLayer(layer))
                            }
                        }
                    )) {
                        ForEach(state.layerOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .focusable(false)
                }
            }
            row("Net") {
                if let netName = state.netName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(netName)
                            .fontWeight(.medium)
                        if let netClassName = state.netClassName {
                            Text("Net class \(netClassName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(state.hasStarted ? "No net" : "The net of what it starts on")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Diff pair

    /// The pair the route's net is in, and the diffpair rule a pair router
    /// will route it by: width, gap and via gap.
    private func diffpairSection(_ pair: HorizontalRouteInspectorState.Diffpair) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Differential Pair")
            row("Partner") {
                Text((pair.isPrimary ? "Pri: " : "Sec: ") + pair.partnerName)
            }
            if let rule = pair.rule {
                row("Track width") { Text(HorizontalRouteInspectorState.millimetres(rule.trackWidth)) }
                row("Gap") { Text(pair.gap.map(HorizontalRouteInspectorState.millimetres) ?? "") }
                row("Via gap") { Text(HorizontalRouteInspectorState.millimetres(rule.viaGap)) }
                caption("Differential pair rule \(pair.ruleBrief ?? ""). Tracks are routed one at a time for now.")
                if let warning = pair.gapWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                caption("No diffpair rule takes this pair's net class on \(state.layerName).")
            }
            if canShowRules {
                Button("Show Differential Pair Rules…") {
                    onCommand(.showRules(.diffpair, ruleID: pair.rule?.id))
                }
                .routeInspectorLinkStyle()
                .font(.caption)
            }
        }
    }

    // MARK: Width

    private var widthMode: WidthMode {
        switch state.widthSource {
        case .custom: .custom
        case .track: .track
        case .rule, .existingTracks, .fallback: .rules
        }
    }

    private var widthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Width")
                Spacer()
                // Each picker here sends only a change: SwiftUI can hand a
                // picker its own selection back while it updates the view, and
                // the command would publish the tool settings mid-update.
                Picker("Width from", selection: Binding(
                    get: { widthMode },
                    set: { mode in
                        guard mode != widthMode else { return }
                        switch mode {
                        case .rules: onCommand(.useRuleWidth)
                        case .custom: onCommand(.useCustomWidth(state.width))
                        case .track: break
                        }
                    }
                )) {
                    Text("Rules").tag(WidthMode.rules)
                    if widthMode == .track {
                        Text("Track").tag(WidthMode.track)
                    }
                    Text("Custom").tag(WidthMode.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(isReadOnly)
                .help("Where the route's width comes from: the track width rules, or a width of your own")
            }
            row("Width") {
                millimetreField(state.width, help: widthFieldHelp) { width in
                    commitWidth(width)
                }
            }
            caption(state.widthSourceText)
            if let rule = state.widthRule, widthMode == .rules {
                row("Minimum") {
                    millimetreField(rule.widths.min, help: "The least width the rule allows on \(state.layerName)") { min in
                        var widths = rule.widths
                        widths.min = min
                        onCommand(.editRule(.trackWidth(ruleID: rule.id, layer: rule.layer, widths: widths)))
                    }
                }
                row("Maximum") {
                    millimetreField(rule.widths.max, help: "The greatest width the rule allows on \(state.layerName)") { max in
                        var widths = rule.widths
                        widths.max = max
                        onCommand(.editRule(.trackWidth(ruleID: rule.id, layer: rule.layer, widths: widths)))
                    }
                }
            } else if widthMode != .rules {
                caption("The rules would give \(HorizontalRouteInspectorState.millimetres(state.ruleWidth)).")
            }
            if let warning = state.widthWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if state.widthRule == nil, widthMode == .rules, !isReadOnly {
                Button("Add a Track Width Rule") {
                    onCommand(.editRule(.addTrackWidthRule(layer: state.layer, width: state.width)))
                }
                .controlSize(.small)
                .help("Add a track width rule that takes every net, with this width on \(state.layerName)")
            }
            if canShowRules {
                Button("Show Track Width Rules…") {
                    onCommand(.showRules(.trackWidth, ruleID: state.widthRule?.id))
                }
                .routeInspectorLinkStyle()
                .font(.caption)
            }
        }
    }

    private var widthFieldHelp: String {
        switch widthMode {
        case .rules:
            state.widthRule == nil
                ? "Adds a track width rule with this width"
                : "Changes the default width of the track width rule on \(state.layerName)"
        case .track, .custom:
            "Sets a custom width for this route and the next"
        }
    }

    private func commitWidth(_ width: Double) {
        guard width > 0 else {
            return
        }
        switch widthMode {
        case .rules:
            if let rule = state.widthRule {
                var widths = rule.widths
                widths.def = width
                onCommand(.editRule(.trackWidth(ruleID: rule.id, layer: rule.layer, widths: widths)))
            } else {
                onCommand(.editRule(.addTrackWidthRule(layer: state.layer, width: width)))
            }
        case .track, .custom:
            onCommand(.useCustomWidth(width))
        }
    }

    // MARK: Via

    private var viaSection: some View {
        let via = state.via
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(via.isArmed ? "Via (armed)" : "Via")
                Spacer()
                if via.canDrop {
                    Picker("Via from", selection: Binding(
                        get: { via.isCustom },
                        set: { custom in
                            guard custom != via.isCustom else { return }
                            if custom, let diameter = via.diameter, let hole = via.holeDiameter {
                                onCommand(.useCustomVia(diameter: diameter, holeDiameter: hole))
                            } else if !custom {
                                onCommand(.useRuleVia)
                            }
                        }
                    )) {
                        Text("Rules").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isReadOnly)
                    .help("Where the route's via gets its size: the via rules, or a size of your own")
                }
            }
            if let diameter = via.diameter, let hole = via.holeDiameter {
                if via.isCustom {
                    if let text = ruleViaText(via) {
                        caption(text)
                    }
                } else if let brief = via.ruleBrief {
                    caption("Via rule \(brief)")
                } else {
                    caption("The board's own via: its rules state no via rule.")
                }
                row("Diameter") {
                    millimetreField(diameter, help: viaFieldHelp(via)) { value in
                        commitVia(via, diameter: value, holeDiameter: hole)
                    }
                }
                row("Hole") {
                    millimetreField(hole, help: viaFieldHelp(via)) { value in
                        commitVia(via, diameter: diameter, holeDiameter: value)
                    }
                }
                if hole >= diameter {
                    Label("The hole is as wide as the via.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                if let brief = via.ruleBrief {
                    caption("Via rule \(brief) names no padstack, so V drops no via.")
                } else {
                    caption("No via rule takes this net, so V drops no via.")
                    if !isReadOnly {
                        Button("Add a Via Rule") {
                            onCommand(.editRule(.addViaRule(
                                padstackID: via.defaultPadstackID, diameter: 500_000, holeDiameter: 200_000)))
                        }
                        .controlSize(.small)
                        .help("Add a via rule that takes every net, with the board's default via at 0.5 mm with a 0.2 mm hole")
                    }
                }
            }
            if canShowRules {
                Button("Show Via Rules…") {
                    onCommand(.showRules(.via, ruleID: via.rule?.id))
                }
                .routeInspectorLinkStyle()
                .font(.caption)
            }
        }
    }

    private func ruleViaText(_ via: HorizontalRouteInspectorState.Via) -> String? {
        guard let diameter = via.ruleDiameter, let hole = via.ruleHoleDiameter else {
            return nil
        }
        return "The rules would give \(Self.mm(diameter)) / \(Self.mm(hole)) mm."
    }

    private func viaFieldHelp(_ via: HorizontalRouteInspectorState.Via) -> String {
        if via.isCustom || via.rule == nil {
            return "Sets the size of the route's via, for this route and the next"
        }
        return "Changes the via rule \(via.ruleBrief ?? "")"
    }

    private func commitVia(_ via: HorizontalRouteInspectorState.Via, diameter: Double, holeDiameter: Double) {
        guard diameter > 0, holeDiameter > 0 else {
            return
        }
        if !via.isCustom, let rule = via.rule {
            onCommand(.editRule(.viaParameters(rule: rule, diameter: diameter, holeDiameter: holeDiameter)))
        } else {
            onCommand(.useCustomVia(diameter: diameter, holeDiameter: holeDiameter))
        }
    }

    // MARK: Clearance

    private var clearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Clearance")
            ruleCaption("Copper", state.spacing.copperRule, kind: .clearanceCopper)
            routingOffsetRow("Routing offset", state.spacing.copperRule, table: .copper, kept: "its clearances")
            ForEach(state.spacing.rows.filter { $0.table == .copper }) { clearanceRow($0) }
            ForEach(state.spacing.otherCopperRules) { other in
                caption("\(other.rule.brief) takes \(other.netCount == 1 ? "1 net" : "\(other.netCount) nets") instead, "
                    + "up to \(HorizontalRouteInspectorState.millimetres(other.widest)).")
            }
            ruleCaption("Copper – other", state.spacing.otherRule, kind: .clearanceCopperOther)
            routingOffsetRow("Routing offset", state.spacing.otherRule, table: .copperOther,
                             kept: "the board edge and hole clearances")
            ForEach(state.spacing.rows.filter { $0.table == .copperOther }) { clearanceRow($0) }
            let keepouts = state.spacing.rows.filter {
                if case .keepout = $0.table { return true }
                return false
            }
            if !keepouts.isEmpty {
                ForEach(keepouts) { clearanceRow($0) }
            }
        }
    }

    private func ruleCaption(_ title: String, _ rule: HorizontalRouteSpacing.Rule, kind: HorizontalBoardRuleKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(title): \(rule.brief)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if canShowRules {
                Button("Show…") {
                    onCommand(.showRules(kind, ruleID: rule.id))
                }
                .routeInspectorLinkStyle()
                .font(.caption)
            }
        }
    }

    /// A clearance rule's routing offset: what the router keeps beyond the
    /// clearances the rule gives (`kept`), which the rules check doesn't ask.
    private func routingOffsetRow(
        _ label: String,
        _ rule: HorizontalRouteSpacing.Rule,
        table: HorizontalRouteSpacing.Table,
        kept: String
    ) -> some View {
        row(label) {
            millimetreField(rule.routingOffset, help: rule.id == nil
                ? "Routing offset: what the router keeps beyond \(kept). Adds a clearance rule for every net with it"
                : "Routing offset of the clearance rule \(rule.brief): what the router keeps beyond \(kept)"
            ) { value in
                onCommand(.editRule(.routingOffset(table: table, ruleID: rule.id, value)))
            }
        }
    }

    private func clearanceRow(_ row: HorizontalRouteSpacing.Row) -> some View {
        self.row(row.title) {
            millimetreField(row.clearance, help: rowHelp(row)) { value in
                switch row.table {
                case .copper:
                    onCommand(.editRule(.copperClearance(ruleID: row.rule.id, .track, row.other, value)))
                case .copperOther:
                    onCommand(.editRule(.copperOtherClearance(ruleID: row.rule.id, copper: .track, nonCopper: row.other, value)))
                case .keepout(let keepoutClass):
                    onCommand(.editRule(.keepoutClearance(ruleID: row.rule.id, keepoutClass: keepoutClass, copper: .track, value)))
                }
            }
        }
    }

    private func rowHelp(_ row: HorizontalRouteSpacing.Row) -> String {
        row.rule.id == nil
            ? "Adds a clearance rule for every net, with this clearance from a track to: \(row.title)"
            : "Changes the clearance rule \(row.rule.brief), from a track to: \(row.title)"
    }

    // MARK: Nearest

    private var nearestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Nearest")
            if state.nearest.isEmpty {
                caption("Nothing within \(HorizontalRouteInspectorState.millimetres(state.nearestRadius)) on \(state.layerName).")
            } else {
                ForEach(state.nearest) { measurement in
                    nearestRow(measurement)
                }
            }
        }
    }

    private func nearestRow(_ measurement: HorizontalRouteClearanceProbe.Measurement) -> some View {
        let violates = measurement.margin < 0
        let tight = measurement.isInsideRoutingOffset
        let color: Color = violates ? .red : (tight ? .orange : .green)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: violates ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(color)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(measurement.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(nearestNote(measurement))
                    .font(.caption)
                    .foregroundStyle(violates ? .red : (tight ? .orange : .secondary))
            }
            Spacer(minLength: 4)
            Text(measurement.gap <= 0 ? "0" : HorizontalRouteInspectorState.millimetres(measurement.gap))
                .monospacedDigit()
                .foregroundStyle(violates ? .red : .primary)
        }
        .help("\(measurement.label): \(HorizontalRouteInspectorState.millimetres(max(measurement.gap, 0))) apart, "
            + "\(HorizontalRouteInspectorState.millimetres(measurement.required)) asked by the \(measurement.rule)")
    }

    private func nearestNote(_ measurement: HorizontalRouteClearanceProbe.Measurement) -> String {
        let needs = HorizontalRouteInspectorState.millimetres(measurement.required)
        if measurement.gap <= 0 {
            return "Touches; needs \(needs)"
        }
        if measurement.isInsideRoutingOffset {
            let router = HorizontalRouteInspectorState.millimetres(measurement.required + measurement.routingOffset)
            return "Needs \(needs); inside the routing offset (\(router))"
        }
        return "Needs \(needs)"
    }

    // MARK: Pieces

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    /// A note under a row. It wraps: one row holds the whole inspector, and
    /// a sidebar list measures a row before it lays it out narrower.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func millimetreField(_ nanometres: Double, help: String, onCommit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            NumericPropertyField(
                value: nanometres / 1_000_000,
                fractionDigits: 3,
                font: .callout.monospacedDigit()
            ) { millimetres in
                guard millimetres.isFinite, millimetres >= 0 else { return }
                onCommit((millimetres * 1_000_000).rounded())
            }
            .frame(width: 76)
            .disabled(isReadOnly)
            Text("mm")
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    private static func mm(_ nanometres: Double) -> String {
        (nanometres / 1_000_000).formatted(.number.precision(.fractionLength(2...3)))
    }
}

private extension View {
    /// A button that reads as a link in the sidebar.
    @ViewBuilder
    func routeInspectorLinkStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
