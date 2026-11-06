import SwiftUI

/// The rules results sidebar: what the last run of every rules check found —
/// the rules' own structure, the schematic's connectivity and the board
/// against every kind of board rule Horizontal checks, a section a kind —
/// which the rules window's Apply & Check runs and the document keeps up to
/// date as the design changes, or, with Automatically check rules or Display
/// warnings on canvas off, runs when Check Now asks. macOS shows it as the
/// window's right sidebar, the iPad as its right-hand panel.
struct HorizontalRulesResultsSidebarView: View {
    var result: HorizontalBoardRulesResultState?
    var safeAreaInsets: EdgeInsets
    /// Display warnings on canvas (`HorizontalAppearanceSettings`). Off,
    /// Automatically check rules hides and the checks wait for Check Now.
    var displaysCanvasWarnings: Binding<Bool> = .constant(true)
    /// Automatically check rules (`HorizontalRulesCheckDefaults`).
    var checksAutomatically: Binding<Bool> = .constant(true)
    /// Runs every check now; nil where there is nothing to check.
    var onCheckNow: (() -> Void)? = nil
    /// Opens the board's rules window.
    var onOpenRules: () -> Void = {}
    /// Shows where a board finding is on the board.
    var onShowFinding: (HorizontalBoardRuleFinding) -> Void = { _ in }
    /// Opens the rules window at the rule a finding is against.
    var onShowRule: (HorizontalBoardRuleFinding) -> Void = { _ in }
    /// Shows where a schematic finding is on its sheet.
    var onShowSchematicFinding: (HorizontalSchematicRuleFinding) -> Void = { _ in }
    /// Opens the rules window at the schematic's Connectivity rule.
    var onShowSchematicRule: () -> Void = {}
    /// The sections closed by their disclosure triangles, by
    /// `HorizontalBoardRulesResultState` section id: their rows are folded
    /// away and no canvas marks their findings.
    var collapsedSections: Binding<Set<String>> = .constant([])

    var body: some View {
        List {
            Section {
                if let result {
                    // While the checks run again on every change there is no
                    // run to ask for and no time to give: only the spinner
                    // while one is under way. While they run when asked,
                    // Check Now asks, and a change since the last run says so.
                    HStack {
                        Text(result.ruleTitle)
                            .fontWeight(.semibold)
                        Spacer()
                        if result.isCheckingClearance || result.isCheckingSchematic {
                            ProgressView()
                                .controlSize(.small)
                                .help(result.isCheckingClearance
                                      ? "Checking the board against its rules"
                                      : "Checking the schematic's connectivity")
                        }
                    }
                    .padding(.vertical, 4)
                    if result.isOutOfDate {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Out of date")
                                Text("The design has changed since the last check.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    Label("No checks run", systemImage: "checklist")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                Toggle("Display warnings on canvas", isOn: displaysCanvasWarnings)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .help(HorizontalCanvasWarningsToggle.help)
                if displaysCanvasWarnings.wrappedValue {
                    Toggle("Automatically check rules", isOn: checksAutomatically)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .help("Check the design against its rules again after every change")
                }
                HStack {
                    Button("Open Rules…", action: onOpenRules)
                        .help("Open the board's rules")
                    if !HorizontalRulesCheckDefaults.runsAutomatically(
                        checksAutomatically: checksAutomatically.wrappedValue,
                        displaysCanvasWarnings: displaysCanvasWarnings.wrappedValue
                    ) {
                        Button("Check Now") { onCheckNow?() }
                            .disabled(onCheckNow == nil)
                            .help("Check the design against its rules")
                    }
                }
                .controlSize(.small)
            }

            if let result {
                if result.hasNoIssues {
                    Section {
                        Label {
                            Text("No issues")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !result.messages.isEmpty {
                    disclosureSection("Rules", id: HorizontalBoardRulesResultState.rulesSectionID) {
                        ForEach(result.messages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: message.level.iconName)
                                    .foregroundStyle(message.level.color)
                                    .frame(width: 18)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(message.title)
                                    Text(message.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if let findings = result.schematicFindings, !findings.isEmpty {
                    disclosureSection("Schematic (\(findings.count))", id: HorizontalBoardRulesResultState.schematicSectionID) {
                        ForEach(findings) { finding in
                            HorizontalSchematicRuleFindingRow(finding: finding, onShow: onShowSchematicFinding)
                                .padding(.vertical, 4)
                                .contextMenu {
                                    if finding.place != nil {
                                        Button("Show on Schematic") {
                                            onShowSchematicFinding(finding)
                                        }
                                    }
                                    Button("Show Rule", action: onShowSchematicRule)
                                }
                        }
                    }
                }
                ForEach(result.boardFindingSections) { section in
                    disclosureSection("\(section.title) (\(section.findings.count))", id: section.id) {
                        ForEach(section.findings) { finding in
                            Group {
                                if let clearance = finding.clearance {
                                    HorizontalClearanceFindingRow(finding: clearance) { _ in onShowFinding(finding) }
                                } else {
                                    HorizontalBoardRuleFindingRow(finding: finding, onShow: finding.region == nil ? nil : onShowFinding)
                                }
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                if finding.region != nil {
                                    Button("Show on Board") {
                                        onShowFinding(finding)
                                    }
                                }
                                if finding.kind != nil {
                                    Button(finding.ruleID == nil ? "Show Rules" : "Show Rule") {
                                        onShowRule(finding)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.top, safeAreaInsets.top)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(width: 0.7)
        }
    }

    /// A section headed by its title in body text beside a disclosure
    /// triangle, which closes it: its rows go, and so do its markers on the
    /// canvases.
    private func disclosureSection<Content: View>(_ title: String, id: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        let isExpanded = !collapsedSections.wrappedValue.contains(id)
        return Section {
            if isExpanded {
                content()
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        collapsedSections.wrappedValue.insert(id)
                    } else {
                        collapsedSections.wrappedValue.remove(id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .help(isExpanded ? "Hide these here and on the canvas" : "Show these here and on the canvas")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
    }
}

extension HorizontalBoardRulesResultState {
    /// Every check has come back and none found anything: the rules hold
    /// together, and the schematic and board checks have each finished at
    /// least once with no findings. Until their first runs are in, the
    /// sidebar says nothing rather than call a design clear that hasn't been
    /// checked.
    var hasNoIssues: Bool {
        messages.isEmpty && clearanceFindings?.isEmpty == true && (boardFindings ?? []).isEmpty
            && schematicFindings?.isEmpty == true
    }

    /// The board checks' findings alike, the clearance ones among them, in
    /// the rules window's order of kinds.
    var allBoardFindings: [HorizontalBoardRuleFinding] {
        HorizontalBoardRulesCheck.sorted((clearanceFindings ?? []).map(HorizontalBoardRuleFinding.init) + (boardFindings ?? []))
    }

    /// The sidebar's sections that aren't a kind of board rule.
    static let rulesSectionID = "rules"
    static let schematicSectionID = "schematic"

    /// The board findings the canvas marks: those of every section the
    /// sidebar has open.
    func canvasBoardFindings(collapsedSections: Set<String>) -> [HorizontalBoardRuleFinding] {
        let findings = allBoardFindings
        guard !collapsedSections.isEmpty else { return findings }
        return findings.filter { !collapsedSections.contains(HorizontalBoardFindingSection.id(of: $0.kind)) }
    }

    /// The schematic findings the canvas marks: none while the sidebar has
    /// their section closed.
    func canvasSchematicFindings(collapsedSections: Set<String>) -> [HorizontalSchematicRuleFinding] {
        collapsedSections.contains(Self.schematicSectionID) ? [] : schematicFindings ?? []
    }

    /// The board findings a section a kind of rule, as the sidebar lists
    /// them; Horizontal's own copper checks first, as "Copper".
    var boardFindingSections: [HorizontalBoardFindingSection] {
        var sections = [HorizontalBoardFindingSection]()
        for finding in allBoardFindings {
            // Not `sections.last?.kind == finding.kind`: the chain flattens,
            // so with no section yet it is nil and matches a Copper finding.
            if let last = sections.last, last.kind == finding.kind {
                sections[sections.count - 1].findings.append(finding)
            } else {
                sections.append(HorizontalBoardFindingSection(kind: finding.kind, findings: [finding]))
            }
        }
        return sections
    }

    /// The findings Horizon fails, of the board's and the rules' own.
    var errorCount: Int {
        messages.filter { $0.level == .error }.count + allBoardFindings.filter { $0.level == .error }.count
    }

    var warningCount: Int {
        messages.filter { $0.level != .error }.count + allBoardFindings.filter { $0.level != .error }.count
    }
}

/// The board findings of one kind of rule, as the results sidebar lists them.
struct HorizontalBoardFindingSection: Identifiable {
    var kind: HorizontalBoardRuleKind?
    var findings: [HorizontalBoardRuleFinding]

    var id: String { Self.id(of: kind) }

    static func id(of kind: HorizontalBoardRuleKind?) -> String { kind?.rawValue ?? "copper" }

    var title: String { kind?.title ?? "Copper" }
}

/// A board finding other than a clearance one, as the rules results sidebar
/// lists it: what Horizon says and more. With `onShow`, a click shows where
/// it is.
struct HorizontalBoardRuleFindingRow: View {
    var finding: HorizontalBoardRuleFinding
    var onShow: ((HorizontalBoardRuleFinding) -> Void)?

    var body: some View {
        let level: HorizontalBoardRuleCheckMessage.Level = finding.level == .error ? .error : .warning
        let label = HStack(alignment: .top, spacing: 8) {
            Image(systemName: level.iconName)
                .foregroundStyle(level.color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.message)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if let onShow {
            Button {
                onShow(finding)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("Show it on the board")
        } else {
            label
        }
    }
}

/// One schematic finding, as the rules results sidebar lists it: what Horizon
/// says and which sheet it is on. With a place, a click shows it there.
struct HorizontalSchematicRuleFindingRow: View {
    var finding: HorizontalSchematicRuleFinding
    var onShow: ((HorizontalSchematicRuleFinding) -> Void)?

    var body: some View {
        let level: HorizontalBoardRuleCheckMessage.Level = finding.isError ? .error : .warning
        let label = HStack(alignment: .top, spacing: 8) {
            Image(systemName: level.iconName)
                .foregroundStyle(level.color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.message)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.placeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if let onShow, finding.place != nil {
            Button {
                onShow(finding)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("Show it on the schematic")
        } else {
            label
        }
    }
}
