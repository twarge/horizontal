import Foundation

/// The inspector's Position, Angle, Flipped and Scale of a board decal, as
/// Horizon's property panel has them for one (`ObjectType::BOARD_DECAL`:
/// FLIPPED, POSITION_X, POSITION_Y, ANGLE and SCALE).
///
/// A move shifts the decal's geometry. The rest change how its pool item is
/// drawn, so the decal is drawn again from that item as the loader will draw
/// it from the file (`HorizontalBoardDecal.redrawn`). Flipped is Horizon's
/// `set_flip`: the decal goes to the other side of the board with the angle
/// the file has, which there turns it the other way, so it is the decal as
/// it lay mirrored across the vertical line through its origin.
enum BoardDecalPlacementEdit {
    /// What the inspector shows of `decal`. A panel's copy of another
    /// board's decal is that board's to place, so it has its name alone.
    static func properties(of decal: HorizontalBoardDecal) -> [HorizontalSelectionProperty] {
        var properties = [HorizontalSelectionProperty]()
        if !decal.name.isEmpty {
            properties.append(HorizontalSelectionProperty(id: "name", label: "Name", editor: .readOnly, value: .readOnly(decal.name)))
        }
        guard decal.isPlacedByBoard, let position = decal.position else {
            return properties
        }
        return properties + [
            HorizontalSelectionProperty(id: "positionX", label: "Position X", editor: .length, value: .length(position.x)),
            HorizontalSelectionProperty(id: "positionY", label: "Position Y", editor: .length, value: .length(position.y)),
            HorizontalSelectionProperty(id: "angle", label: "Angle", editor: .angle, value: .angle(decal.angle)),
            HorizontalSelectionProperty(id: "flipped", label: "Flipped", editor: .bool, value: .bool(decal.flip)),
            HorizontalSelectionProperty(id: "scale", label: "Scale", editor: .scale, value: .scale(decal.scale)),
        ]
    }

    /// Sets `propertyID` of the decal `ref` names to `value`, where it is
    /// one of the five and the decal is the board's to place. False only
    /// when the decal had to be drawn again and its pool item, read from
    /// `poolURL` (the project pool) or where it is to be cached from,
    /// couldn't be: the decal is left as it was.
    static func apply(
        _ value: HorizontalSelectionPropertyValue,
        propertyID: String,
        to ref: HorizontalSelectableRef,
        board: inout HorizontalBoard,
        poolURL: URL?
    ) -> Bool {
        let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
        guard let index = board.decals.firstIndex(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }),
              board.decals[index].isPlacedByBoard, let position = board.decals[index].position else {
            return true
        }
        let decal = board.decals[index]
        var angle = decal.angle
        var flip = decal.flip
        var scale = decal.scale
        switch (propertyID, value) {
        case ("positionX", .length(let x)):
            board.decals[index] = shifted(decal, by: HorizontalPoint(x: x - position.x, y: 0))
            return true
        case ("positionY", .length(let y)):
            board.decals[index] = shifted(decal, by: HorizontalPoint(x: 0, y: y - position.y))
            return true
        case ("angle", .angle(let value)):
            angle = HorizontalCanvasModeSupport.wrappedAngle(value)
        case ("flipped", .bool(let value)):
            flip = value
        case ("scale", .scale(let value)) where value.isFinite && value > 0:
            scale = value
        default:
            return true
        }
        guard angle != decal.angle || flip != decal.flip || scale != decal.scale else {
            return true
        }
        guard let redrawn = decal.redrawn(
            angle: angle, flip: flip, scale: scale,
            nInnerLayers: max(board.copperLayerCount - 2, 0), projectPoolURL: poolURL
        ) else {
            return false
        }
        board.decals[index] = redrawn
        return true
    }

    /// `decal` moved by `delta`, its place in the file with it.
    static func shifted(_ decal: HorizontalBoardDecal, by delta: HorizontalPoint) -> HorizontalBoardDecal {
        var decal = decal
        decal.polygons = decal.polygons.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        decal.lines = decal.lines.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        decal.arcs = decal.arcs.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        decal.texts = decal.texts.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        decal.position = decal.position.map { $0 + delta }
        return decal
    }
}
