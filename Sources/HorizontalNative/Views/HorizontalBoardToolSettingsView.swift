import SwiftUI

/// The board track-tool settings form (corner style, width, autorouter, via).
/// Shared by the macOS tool-settings popover (ProjectDocumentView) and the iPad
/// track UI (HorizontalIPadProjectView), so it lives outside the macOS-only
/// document view.
struct HorizontalBoardToolSettingsView: View {
    @ObservedObject var settings: HorizontalBoardToolSettings
    var viaTemplate: HorizontalBoardViaTemplate?

    private let nmPerMM = 1_000_000.0

    var body: some View {
        Form {
            Section("Track") {
                Picker("Corner style", selection: $settings.cornerStyle) {
                    Text("90°").tag(BoardTrackCornerStyle.ninety)
                    Text("45°").tag(BoardTrackCornerStyle.fortyFive)
                    Text("Arc").tag(BoardTrackCornerStyle.arc)
                }
                .pickerStyle(.segmented)

                Toggle("Custom width", isOn: customWidthBinding)
                if settings.explicitTrackWidth != nil {
                    LabeledContent("Width (mm)") {
                        TextField("0.2", value: trackWidthMMBinding, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            // Unguarded since the router became Horizontal's own: it is pure
            // Swift and works on both platforms, where the vendored one this
            // section was written for was macOS-only and is gone.
            Section("Routing") {
                Toggle("Route around obstacles", isOn: $settings.routerMode)
                if settings.routerMode {
                    Toggle("Shove existing tracks", isOn: $settings.routerShove)
                        .disabled(true)
                    Text("Shoving is not built yet. Routes bend around existing "
                         + "copper; nothing already on the board is moved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Via") {
                LabeledContent("Diameter (mm)") {
                    TextField("0.5", value: viaDiameterMMBinding, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Hole (mm)") {
                    TextField("0.2", value: viaHoleMMBinding, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                if settings.viaDiameter != nil || settings.viaHoleDiameter != nil {
                    Button("Use board default via") {
                        settings.viaDiameter = nil
                        settings.viaHoleDiameter = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // macOS-native compact sizing for a tool popover. Booleans use the
        // checkbox style — the native macOS control for form/dialog booleans —
        // because the default switch reads oversized here and ignores
        // .controlSize. iOS keeps its native touch-sized switches.
        .toggleStyle(.checkbox)
        .controlSize(.small)
        #endif
        .frame(idealWidth: 320, idealHeight: 320)
    }

    private var customWidthBinding: Binding<Bool> {
        Binding(
            get: { settings.explicitTrackWidth != nil },
            set: { settings.explicitTrackWidth = $0 ? (settings.explicitTrackWidth ?? 200_000) : nil }
        )
    }

    private var trackWidthMMBinding: Binding<Double> {
        Binding(
            get: { (settings.explicitTrackWidth ?? 200_000) / nmPerMM },
            set: { settings.explicitTrackWidth = max($0, 0) * nmPerMM }
        )
    }

    private var viaDiameterMMBinding: Binding<Double> {
        Binding(
            get: { settings.resolvedViaDiameter(template: viaTemplate) / nmPerMM },
            set: { settings.viaDiameter = max($0, 0) * nmPerMM }
        )
    }

    private var viaHoleMMBinding: Binding<Double> {
        Binding(
            get: { settings.resolvedViaHoleDiameter(template: viaTemplate) / nmPerMM },
            set: { settings.viaHoleDiameter = max($0, 0) * nmPerMM }
        )
    }
}
