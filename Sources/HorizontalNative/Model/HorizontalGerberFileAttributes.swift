import Foundation

/// The Gerber X2 file attributes a layer file's header carries, so a fab's CAM
/// reads what each file is (which copper layer, counted from the top, which
/// side's mask) from the file rather than from its name. Horizon's Gerber
/// writer writes none, only a G04 comment naming the layer; KiCad's writes
/// this same set. Values as the Gerber Layer Format Specification, revision
/// 2026.05, §5.6 gives them.
enum HorizontalGerberFileAttributes {
    /// The `%TF` lines for `layer`'s file, in the order KiCad writes them.
    /// `.GenerationSoftware` needs a version, so it is left out without one.
    static func header(
        for layer: Int,
        innerLayerCount: Int,
        userLayer: HorizontalBoardUserLayer?,
        softwareVersion: String?
    ) -> [String] {
        var lines = [String]()
        if let softwareVersion {
            lines.append("%TF.GenerationSoftware,Horizontal,Horizontal,\(field(softwareVersion))*%")
        }
        // Every file of the set is drawn in the board's own coordinates, and
        // the export moves no origin, so no ident tells sets apart (§5.6.5).
        lines.append("%TF.SameCoordinates*%")
        lines.append("%TF.FileFunction,\(fileFunction(for: layer, innerLayerCount: innerLayerCount, userLayer: userLayer))*%")
        if let polarity = filePolarity(for: layer) {
            lines.append("%TF.FilePolarity,\(polarity)*%")
        }
        return lines
    }

    /// The layer's `.FileFunction` value. Copper is numbered from the top,
    /// L1, through the inner layers to the bottom, L(inner + 2): Horizon's
    /// Inner 1 is L2.
    static func fileFunction(for layer: Int, innerLayerCount: Int, userLayer: HorizontalBoardUserLayer?) -> String {
        let side = HorizontalBoardLayers.isBottomSide(layer) ? "Bot" : "Top"
        switch layer {
        case HorizontalBoardLayers.topCopper:
            return "Copper,L1,Top"
        case HorizontalBoardLayers.in8Copper...HorizontalBoardLayers.in1Copper:
            return "Copper,L\(-layer + 1),Inr"
        case HorizontalBoardLayers.bottomCopper:
            return "Copper,L\(innerLayerCount + 2),Bot"
        case HorizontalBoardLayers.topMask, HorizontalBoardLayers.bottomMask:
            return "Soldermask,\(side)"
        case HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen:
            return "Legend,\(side)"
        case HorizontalBoardLayers.topPaste, HorizontalBoardLayers.bottomPaste:
            return "Paste,\(side)"
        case HorizontalBoardLayers.outline:
            // Horizon has no plated board edge.
            return "Profile,NP"
        case HorizontalBoardLayers.topAssembly, HorizontalBoardLayers.bottomAssembly:
            return "AssemblyDrawing,\(side)"
        case HorizontalBoardLayers.firstUserLayer...HorizontalBoardLayers.lastUserLayer:
            // A documentation layer is a drawing; a stiffener, coverlay or
            // the like is material the spec has no function for.
            let named = userLayer.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
            let name = field(named ?? HorizontalBoardLayers.name(for: layer))
            let isDrawing = userLayer.map { $0.type == "documentation" } ?? true
            return isDrawing ? "OtherDrawing,\(name)" : "Other,\(name)"
        default:
            // The notes, dimensions and the like are drawings for the fab.
            return "OtherDrawing,\(field(HorizontalBoardLayers.name(for: layer)))"
        }
    }

    /// Whether the image is the material or its absence, for the layers that
    /// are a material: a solder mask file draws the openings, so it is
    /// negative (§5.6.4).
    static func filePolarity(for layer: Int) -> String? {
        switch layer {
        case HorizontalBoardLayers.topMask, HorizontalBoardLayers.bottomMask:
            return "Negative"
        case HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen,
             HorizontalBoardLayers.topPaste, HorizontalBoardLayers.bottomPaste:
            return "Positive"
        default:
            return HorizontalBoardLayers.isCopper(layer) ? "Positive" : nil
        }
    }

    /// How many inner layers the copper numbering runs through: the board's,
    /// or as deep as an exported layer goes, so the numbers stay consecutive.
    static func innerLayerCount(of board: HorizontalBoard, exporting layers: [Int]) -> Int {
        (board.stackupLayers.map(\.layer) + layers)
            .filter { $0 < HorizontalBoardLayers.topCopper && $0 > HorizontalBoardLayers.bottomCopper }
            .map { -$0 }
            .max() ?? 0
    }

    /// The app's version for `.GenerationSoftware`. Nil where the exporter runs
    /// outside the app, in the MCP worker or a test, whose main bundle isn't
    /// Horizontal's.
    static var applicationVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return nil
        }
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              !build.isEmpty, build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    /// `text` as an attribute field (§3.4.4): the delimiters `%` and `*`, the
    /// escape `\` and the field separator `,` escaped as `\uXXXX`, and so is
    /// anything past printable ASCII, which keeps the file ASCII for older CAM.
    static func field(_ text: String) -> String {
        escaped(text, reserved: ["%", "*", "\\", ","])
    }

    /// `text` as a Gerber string (§3.4.3), as a G04 comment holds one: a field
    /// that may hold commas.
    static func string(_ text: String) -> String {
        escaped(text, reserved: ["%", "*", "\\"])
    }

    private static func escaped(_ text: String, reserved: Set<Unicode.Scalar>) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if (0x20..<0x7F).contains(scalar.value), !reserved.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if scalar.value <= 0xFFFF {
                result += String(format: "\\u%04X", scalar.value)
            } else {
                result += String(format: "\\U%08X", scalar.value)
            }
        }
        return result
    }
}
