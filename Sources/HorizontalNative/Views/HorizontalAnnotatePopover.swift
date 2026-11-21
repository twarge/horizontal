import HorizontalProjectIO
import SwiftUI

/// Horizon's annotation options (`Schematic::Annotation`), as the schematic
/// keeps them.
struct HorizontalAnnotationOptions: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case sequential
        case sheet100 = "sheet_100"
        case sheet1000 = "sheet_1000"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sequential: "Sequential"
            case .sheet100: "Sheet × 100"
            case .sheet1000: "Sheet × 1000"
            }
        }
    }

    enum Order: String, CaseIterable, Identifiable {
        case rightDown = "right_down"
        case downRight = "down_right"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rightDown: "Right, then down"
            case .downRight: "Down, then right"
            }
        }
    }

    var mode = Mode.sheet100
    var order = Order.rightDown
    var fillGaps = true
    var keep = true
    var ignoreUnknown = false

    /// The schematic's `annotation` object; Horizon's defaults where it has none.
    init(json: JSONDictionary? = nil) {
        guard let json else { return }
        mode = json.string("mode").flatMap(Mode.init(rawValue:)) ?? mode
        order = json.string("order").flatMap(Order.init(rawValue:)) ?? order
        fillGaps = json.bool("fill_gaps") ?? fillGaps
        keep = json.bool("keep") ?? keep
        ignoreUnknown = json.bool("ignore_unknown") ?? ignoreUnknown
    }

    /// The `annotate` op these options run.
    var operation: JSONDictionary {
        ["op": "annotate", "mode": mode.rawValue, "order": order.rawValue,
         "fill_gaps": fillGaps, "keep": keep, "ignore_unknown": ignoreUnknown]
    }
}

extension HorizontalAnnotationOptions {
    /// The options `project`'s top schematic keeps, read from `archive`;
    /// Horizon's defaults where it keeps none.
    static func stored(in project: HorizontalProject, archive: HorizontalProjectArchive) -> HorizontalAnnotationOptions {
        let top = project.blocks.first(where: \.isTop)
        guard let filename = top?.schematicFilename ?? project.schematicFilename, !filename.isEmpty else {
            return HorizontalAnnotationOptions()
        }
        let url = project.baseURL.appendingPathComponent(filename)
        var path = archive.manifest?.relativePath(for: url)
        if path == nil {
            let base = project.baseURL.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            let target = url.standardizedFileURL.path
            if target.hasPrefix(prefix) {
                path = String(target.dropFirst(prefix.count))
            }
        }
        guard let path, let data = archive.regularFileData(relativePath: path),
              let json = try? JSONHelper.loadDictionary(from: data) else {
            return HorizontalAnnotationOptions()
        }
        return HorizontalAnnotationOptions(json: json.dictionary("annotation"))
    }

    /// What Annotate says it did, of the `annotated` count its op returns.
    static func message(annotated count: Int) -> String {
        count == 0 ? "Every part was annotated already." : "Annotated \(count) part\(count == 1 ? "" : "s")."
    }
}

/// Horizon's Annotate dialog: how the design's refdes are numbered, and the
/// button that numbers them, every instance of a block on its own.
struct HorizontalAnnotatePopover: View {
    @State var options: HorizontalAnnotationOptions
    var isReadOnly: Bool
    var onAnnotate: (HorizontalAnnotationOptions) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotate")
                .font(.headline)
            Text("Numbers every part's reference designator from its prefix, sheet by sheet, across the whole design: each block instance's parts get numbers of their own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Numbering", selection: $options.mode) {
                    ForEach(HorizontalAnnotationOptions.Mode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Order", selection: $options.order) {
                    ForEach(HorizontalAnnotationOptions.Order.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Fill gaps", isOn: $options.fillGaps)
                Toggle("Keep existing", isOn: $options.keep)
                Toggle("Ignore unknown", isOn: $options.ignoreUnknown)
                    .help("Keep a reference designator whose number can't be read, rather than numbering it again")
            }
            HStack {
                Spacer()
                Button("Annotate") {
                    onAnnotate(options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .disabled(isReadOnly)
    }
}

struct AnnotateToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Annotate") {
            Button(action: action) {
                Image(systemName: "number")
            }
            .help("Number the design's reference designators")
        }
    }
}
