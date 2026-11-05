import SwiftUI

/// The rules results sidebar: what the last run of every rules check found —
/// the rules' own structure, the schematic's connectivity and the board's
/// copper against the clearance rules — which the rules window's Apply &
/// Check runs and the document keeps up to date as the design changes. macOS shows it as the window's right
/// sidebar, the iPad as its right-hand panel.
struct HorizontalRulesResultsSidebarView: View {
    var result: HorizontalBoardRulesResultState?
    var safeAreaInsets: EdgeInsets
    /// Opens the board's rules window.
    var onOpenRules: () -> Void = {}
    /// Shows where a clearance finding is on the board.
    var onShowFinding: (HorizontalClearanceFinding) -> Void = { _ in }
    /// Opens the rules window at the rule a finding is against.
    var onShowRule: (HorizontalClearanceFinding) -> Void = { _ in }
    /// Shows where a schematic finding is on its sheet.
    var onShowSchematicFinding: (HorizontalSchematicRuleFinding) -> Void = { _ in }
    /// Opens the rules window at the schematic's Connectivity rule.
    var onShowSchematicRule: () -> Void = {}

    var body: some View {
        List {
            Section {
                if let result {
                    // The checks run again on every change, so there is no
                    // run to ask for and no time to give: only the spinner
                    // while one is under way.
                    HStack {
                        Text(result.ruleTitle)
                            .fontWeight(.semibold)
                        Spacer()
                        if result.isCheckingClearance || result.isCheckingSchematic {
                            ProgressView()
                                .controlSize(.small)
                                .help(result.isCheckingClearance
                                      ? "Checking the board's copper against the clearance rules"
                                      : "Checking the schematic's connectivity")
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("No checks run", systemImage: "checklist")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                Button("Open Rules…", action: onOpenRules)
                    .controlSize(.small)
                    .help("Open the board's rules")
            }

            if let result {
                if result.hasNoIssues {
                    Section {
                        Label {
                            Text("No issues")
                        } icon: {
                            Image(systemName: "checkmark.seal")
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !result.messages.isEmpty {
                    Section("Rules") {
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
                    Section("Schematic (\(findings.count))") {
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
                if let findings = result.clearanceFindings, !findings.isEmpty {
                    Section("Clearance (\(findings.count))") {
                        ForEach(findings) { finding in
                            HorizontalClearanceFindingRow(finding: finding, onShow: onShowFinding)
                                .padding(.vertical, 4)
                                .contextMenu {
                                    Button("Show on Board") {
                                        onShowFinding(finding)
                                    }
                                    Button(finding.ruleID == nil ? "Show Rules" : "Show Rule") {
                                        onShowRule(finding)
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
}

extension HorizontalBoardRulesResultState {
    /// Every check has come back and none found anything: the rules hold
    /// together, and the schematic and clearance checks have each finished
    /// at least once with no findings. Until their first runs are in, the
    /// sidebar says nothing rather than call a design clear that hasn't been
    /// checked.
    var hasNoIssues: Bool {
        messages.isEmpty && clearanceFindings?.isEmpty == true && schematicFindings?.isEmpty == true
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
