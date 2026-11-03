import SwiftUI

/// The rules results sidebar: what the last run of every rules check found —
/// the rules' own structure and the board's copper against the clearance
/// rules — which the rules window's Apply & Check runs and the document keeps
/// up to date as the board changes. macOS shows it as the window's right
/// sidebar, the iPad as its right-hand panel.
struct HorizontalRulesResultsSidebarView: View {
    var result: HorizontalBoardRulesResultState?
    var safeAreaInsets: EdgeInsets
    /// Applies every rule to the board and runs every check again, as the
    /// rules window's Apply & Check does.
    var onRunChecks: () -> Void = {}
    /// Opens the board's rules window.
    var onOpenRules: () -> Void = {}
    /// Shows where a clearance finding is on the board.
    var onShowFinding: (HorizontalClearanceFinding) -> Void = { _ in }
    /// Opens the rules window at the rule a finding is against.
    var onShowRule: (HorizontalClearanceFinding) -> Void = { _ in }

    var body: some View {
        List {
            Section("Rules Results") {
                if let result {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.ruleTitle)
                                .fontWeight(.semibold)
                            Text(result.checkedAt, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if result.isCheckingClearance {
                            ProgressView()
                                .controlSize(.small)
                                .help("Checking the board's copper against the clearance rules")
                        }
                        Button(action: onRunChecks) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Apply the rules and run every check again")
                        .accessibilityLabel("Apply & Check")
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
                Section("Rules") {
                    if result.messages.isEmpty {
                        Label("No structural issues", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                            .padding(.vertical, 4)
                    } else {
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
                if let findings = result.clearanceFindings {
                    Section(findings.isEmpty ? "Clearance" : "Clearance (\(findings.count))") {
                        if findings.isEmpty {
                            Label("No copper closer than the rules allow", systemImage: "checkmark.seal")
                                .foregroundStyle(.green)
                                .padding(.vertical, 4)
                        } else {
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
