import Foundation

/// Horizon's Smash: a schematic symbol's texts, or a board package's
/// silkscreen texts, become texts of the sheet or board that the symbol or
/// package owns (`from_smash`), placed where it drew them, so each can be
/// moved on its own. They stay "$REFDES" and "$VALUE" and go on following
/// the component. Unsmash deletes them, and the symbol or package draws its
/// own again.
enum HorizontalSmash {
    /// A text's placement as a sheet or board stores it, for one drawn with
    /// `drawn`: the loaders draw a mirrored text at 32768 less the angle it
    /// stores (`accumulatedText`).
    static func storedPlacement(drawing drawn: HorizontalPlacementTransform) -> JSONDictionary {
        let angle = drawn.mirrored ? ((32_768 - drawn.angle) % 65_536 + 65_536) % 65_536 : drawn.angle
        return [
            "shift": [Int64(drawn.shift.x.rounded()), Int64(drawn.shift.y.rounded())],
            "angle": angle,
            "mirror": drawn.mirrored,
        ]
    }

    /// A smashed text made from a pool text: what it says, how it is drawn
    /// and on which layer, at `placement`.
    static func text(from poolText: JSONDictionary, placement: JSONDictionary, layer: Int) -> JSONDictionary {
        var text: JSONDictionary = [
            "text": poolText.string("text") ?? "",
            "placement": placement,
            "layer": layer,
            "size": poolText["size"] ?? 1_500_000,
            "width": poolText["width"] ?? 0,
            "origin": poolText.string("origin") ?? "center",
            "font": poolText.string("font") ?? "simplex",
            "from_smash": true,
        ]
        if poolText.bool("allow_upside_down") == true {
            text["allow_upside_down"] = true
        }
        return text
    }

    /// Horizon's `Board::smash_package`: the package's silkscreen texts, in
    /// the pool's order, as board texts where the package draws them — on
    /// the bottom silkscreen, mirrored, for a package on the bottom.
    static func boardTexts(package: JSONDictionary, boardPackage: JSONDictionary, nInnerLayers: Int) -> [JSONDictionary] {
        guard let placement = HorizontalPlacementTransform(
            json: boardPackage.dictionary("placement"),
            mirrorOverride: boardPackage.bool("flip")
        ) else {
            return []
        }
        return package.dictionaryMap("texts").sorted { $0.key.lowercased() < $1.key.lowercased() }.compactMap { _, item in
            guard let layer = HorizontalBoardLayers.packageLayer(item.int("layer"), flipped: placement.mirrored, nInnerLayers: nInnerLayers),
                  HorizontalBoardLayers.isSilkscreen(layer),
                  let textPlacement = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                return nil
            }
            return text(from: item, placement: storedPlacement(drawing: placement.accumulatedText(with: textPlacement)), layer: layer)
        }
    }
}

extension HorizontalSchematicSheet {
    /// The sheet texts the smashed symbols in `symbolIDs` own, lowercased:
    /// what goes with them when they move or are deleted.
    func smashedTextIDs(ownedBy symbolIDs: Set<String>) -> Set<String> {
        Set(symbols
            .filter { $0.smashed && symbolIDs.contains($0.id.lowercased()) }
            .flatMap { $0.smashedTextIDs.map { $0.lowercased() } })
    }

    /// Takes a deleted text off the smashed symbol that owned it, so a save
    /// doesn't keep it for the symbol.
    mutating func forgetSmashedText(_ textID: String) {
        let id = textID.lowercased()
        for index in symbols.indices where symbols[index].smashedTextIDs.contains(where: { $0.lowercased() == id }) {
            symbols[index].smashedTextIDs.removeAll { $0.lowercased() == id }
        }
    }

    /// Redraws the texts a smashed symbol owns, keeping what they store, so
    /// "$REFDES" still says "$REFDES" and draws the new refdes.
    mutating func redrawSmashedTexts(ofSymbol symbolID: String, _ change: (String) -> String) {
        let owned = smashedTextIDs(ownedBy: [symbolID.lowercased()])
        guard !owned.isEmpty else { return }
        for index in texts.indices where owned.contains(texts[index].id.lowercased()) {
            texts[index].redraw(change)
        }
    }
}
