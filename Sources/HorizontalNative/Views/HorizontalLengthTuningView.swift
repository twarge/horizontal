import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The document's Length Tuning list and the board it measures. The host
/// hands it the board whenever the board changes, as Horizon's board editor
/// updates its tuning window on every canvas update, so the lengths follow
/// the copper while the window is open.
@MainActor
final class HorizontalLengthTuningModel: ObservableObject {
    @Published var tuning = HorizontalLengthTuning()
    @Published private(set) var tracks: [HorizontalSegment] = []
    @Published private(set) var netDetails: [String: HorizontalNetDetails] = [:]

    func update(board: HorizontalBoard?) {
        update(tracks: board?.tracks ?? [], netDetails: board?.netDetails ?? [:])
    }

    func update(tracks: [HorizontalSegment], netDetails: [String: HorizontalNetDetails]) {
        if tracks != self.tracks {
            self.tracks = tracks
        }
        if netDetails != self.netDetails {
            self.netDetails = netDetails
        }
    }

    /// Measure Track (`allTracks` false) and Measure All Tracks: the tracks
    /// named, as the board has them.
    func add(trackIDs: Set<String>, allTracks: Bool) {
        let ids = Set(trackIDs.map { $0.lowercased() })
        tuning.add(tracks: tracks.filter { ids.contains($0.id.lowercased()) }, allTracks: allTracks)
    }

    var measurements: [HorizontalLengthTuning.Measurement] {
        tuning.measurements(tracks: tracks, netDetails: netDetails)
    }

    /// The reference length, the target a length tuning tool takes.
    var referenceLength: Double? {
        tuning.referenceLength(on: tracks)
    }
}

/// Horizon's Length Tuning window: the velocity factor (or εr) along the
/// top, then a row for each net added, with its All tracks switch, the Ref
/// that makes it the reference, and its length as a bar, a length and a
/// delay, with its difference from the reference.
struct HorizontalLengthTuningView: View {
    @ObservedObject var model: HorizontalLengthTuningModel
    /// The iPad's Done, which dismisses the sheet it is shown in.
    var onDone: (() -> Void)?

    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            settingsBar
            Divider()
            rowsList
        }
        .frame(minWidth: 420, minHeight: 280)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 8) {
            Text("Velocity factor:")
            TextField("Velocity factor", value: velocityPercent, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .labelsHidden()
            Stepper("Velocity factor", value: velocityPercent, in: 22...100, step: 1)
                .labelsHidden()
            Text("%")
            Text("εr:")
                .padding(.leading, 8)
                .help("Dielectric constant")
            TextField("εr", value: permittivity, format: .number.precision(.fractionLength(2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .labelsHidden()
            Stepper("εr", value: permittivity, in: HorizontalLengthTuning.relativePermittivityRange, step: 0.1)
                .labelsHidden()
            Spacer(minLength: 0)
            // Horizon's header bar Clear: empties the list.
            Button("Clear") {
                model.tuning.clear()
                selection.removeAll()
            }
            .disabled(model.tuning.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
        .padding(8)
    }

    private var velocityPercent: Binding<Double> {
        Binding {
            (model.tuning.velocityFactor * 100 * 10).rounded() / 10
        } set: { percent in
            model.tuning.velocityFactor = (percent / 100).clamped(to: HorizontalLengthTuning.velocityFactorRange)
        }
    }

    private var permittivity: Binding<Double> {
        Binding {
            (model.tuning.relativePermittivity * 100).rounded() / 100
        } set: { value in
            model.tuning.relativePermittivity = value.clamped(to: HorizontalLengthTuning.relativePermittivityRange)
        }
    }

    @ViewBuilder
    private var rowsList: some View {
        let measurements = model.measurements
        if measurements.isEmpty {
            VStack {
                Spacer()
                Text("No tracks to measure.\nUse Measure or Measure All on selected tracks to add them to this list.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            Table(measurements, selection: $selection) {
                TableColumn("Net") { row in
                    Text(row.netName)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                TableColumn("All Tracks") { row in
                    allTracksToggle(row.id)
                }
                .width(70)
                TableColumn("Ref") { row in
                    Button {
                        model.tuning.referenceRowID = row.id
                    } label: {
                        Image(systemName: row.isReference ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(row.isReference ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.isReference ? "Reference" : "Make reference")
                }
                .width(32)
                TableColumn("Length") { row in
                    lengthCell(row)
                }
                .width(min: 220, ideal: 300)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Remove", role: .destructive) { remove(ids) }
                    .disabled(ids.isEmpty)
            }
            #if os(macOS)
            // Horizon's Delete takes the selected rows out.
            .onDeleteCommand { remove(selection) }
            #endif
        }
    }

    @ViewBuilder
    private func allTracksToggle(_ id: UUID) -> some View {
        #if os(macOS)
        Toggle("All tracks", isOn: allTracksBinding(id))
            .labelsHidden()
            .toggleStyle(.checkbox)
        #else
        Toggle("All tracks", isOn: allTracksBinding(id))
            .labelsHidden()
        #endif
    }

    private func lengthCell(_ row: HorizontalLengthTuning.Measurement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lengthText(row))
                .font(.callout.monospacedDigit())
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(row.isReference ? Color.accentColor : Color.secondary.opacity(0.6))
                        .frame(width: max(2, proxy.size.width * row.fraction))
                }
            }
            .frame(height: 4)
        }
    }

    /// Horizon's text: the length and delay, then Δ against the reference
    /// in delay, here with the length difference beside it, which is what a
    /// meander has to make up.
    private func lengthText(_ row: HorizontalLengthTuning.Measurement) -> String {
        var text = "\(HorizontalLengthText.millimetres(row.length))  \(HorizontalLengthText.picoseconds(row.delayPicoseconds))"
        if let delay = row.delayDeltaPicoseconds, let length = row.lengthDelta, !row.isReference {
            text += "  Δ\(HorizontalLengthText.picoseconds(delay, signed: true)) (\(HorizontalLengthText.millimetres(length, signed: true)))"
        }
        return text
    }

    private func allTracksBinding(_ id: UUID) -> Binding<Bool> {
        Binding {
            model.tuning.rows.first { $0.id == id }?.allTracks ?? false
        } set: { value in
            if let index = model.tuning.rows.firstIndex(where: { $0.id == id }) {
                model.tuning.rows[index].allTracks = value
            }
        }
    }

    private func remove(_ ids: Set<UUID>) {
        model.tuning.remove(ids)
        selection.subtract(ids)
    }
}

#if os(macOS)
/// The Length Tuning window, one per document, as Horizon's board editor
/// keeps one: shown by Length Tuning… and by Measure, kept when closed so its
/// list is there when it comes back.
@MainActor
final class HorizontalLengthTuningWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(projectName: String, model: HorizontalLengthTuningModel) {
        if window == nil {
            let hostingController = NSHostingController(rootView: HorizontalLengthTuningView(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 420))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("Horizontal Length Tuning")
            self.window = window
        }
        window?.title = "\(projectName) Length Tuning"
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func close() {
        window?.close()
    }
}
#endif
