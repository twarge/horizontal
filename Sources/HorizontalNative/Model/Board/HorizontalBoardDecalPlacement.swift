import Foundation

/// A decal for the board canvas to take up as Place Decal…'s chooser hands
/// one over: the Pools pane's Place, Return or double-click on a decal.
struct HorizontalBoardDecalPlacementRequest: Identifiable, Equatable {
    var id = UUID()
    var item: HorizontalPoolLibraryItem
}

/// Horizon's place-decal tool (`ToolPlaceDecal`) in flight: a decal taken
/// from a pool, with the angle, flip and scale it goes on the board with. R
/// turns it a quarter turn clockwise (`inc_angle_deg(-90)`), E flips it to
/// the other side and inverts its angle (`set_flip` and `invert_angle`), and
/// S sets its scale, as the tool's ROTATE, MIRROR and ENTER_SIZE do.
struct HorizontalBoardDecalPlacement {
    static let quarterTurn = 16_384

    var item: HorizontalPoolLibraryItem
    var decalJSON: JSONDictionary
    /// The placement's angle as the board file states it.
    var angle = 0
    var flip = false
    var scale = 1.0

    init(item: HorizontalPoolLibraryItem, decalJSON: JSONDictionary) {
        self.item = item
        self.decalJSON = decalJSON
    }

    /// The decal `item` names, read from where the pool scan found it; nil
    /// when that file can't be read.
    init?(item: HorizontalPoolLibraryItem) {
        guard item.category == .decal, let json = try? JSONHelper.loadDictionary(from: item.url) else {
            return nil
        }
        self.init(item: item, decalJSON: json)
    }

    var name: String {
        decalJSON.string("name") ?? item.name
    }

    mutating func rotate() {
        angle = Self.wrapped(angle - Self.quarterTurn)
    }

    mutating func toggleFlip() {
        flip.toggle()
        angle = Self.wrapped(-angle)
    }

    /// The decal at `position`, drawn as the board file will have it read
    /// again. It names `item` to cache into the project pool unless it came
    /// from that pool.
    func decal(id: String, at position: HorizontalPoint, nInnerLayers: Int, projectPoolURL: URL?) -> HorizontalBoardDecal? {
        let entry = HorizontalBoardDecal.fileEntry(decalID: item.uuid, position: position, angle: angle, flip: flip, scale: scale)
        guard var decal = HorizontalBoard.boardDecal(id: id, entry: entry, decalJSON: decalJSON, nInnerLayers: nInnerLayers) else {
            return nil
        }
        let inProjectPool = projectPoolURL.map {
            HorizontalPoolLibrary.canonicalURL($0) == HorizontalPoolLibrary.canonicalURL(item.poolURL)
        } ?? false
        decal.cacheSource = inProjectPool ? nil : item
        return decal
    }

    /// The decals a board can take, for Horizon's decal chooser, which
    /// browses the whole pool: the project pool's own and cached ones, then
    /// those of the pools it includes and the registered and discovered base
    /// pools, a decal several hold listed from the first. This scans pools,
    /// so call it off the main thread.
    static func choices(projectPoolURL: URL) -> HorizontalPoolLibraryIndex {
        HorizontalPoolLibraryIndex(items: HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: projectPoolURL).flatMap { url in
            HorizontalPoolLibrary.items(inPool: url, poolName: HorizontalPoolRegistryStore.poolInfo(at: url).name)
                .filter { $0.category == .decal }
        })
    }

    private static func wrapped(_ angle: Int) -> Int {
        let full = 65_536
        return ((angle % full) + full) % full
    }
}

extension HorizontalBoardDecal {
    /// Its entry in the board file's `decals`, as Horizon's
    /// BoardDecal::serialize writes it: the placement's mirror is the flip.
    /// Nil for a decal with no position of its own.
    var fileEntry: JSONDictionary? {
        position.map { Self.fileEntry(decalID: decalID, position: $0, angle: angle, flip: flip, scale: scale) }
    }

    static func fileEntry(decalID: String, position: HorizontalPoint, angle: Int, flip: Bool, scale: Double) -> JSONDictionary {
        [
            "decal": decalID,
            "placement": [
                "shift": [Int64(position.x.rounded()), Int64(position.y.rounded())],
                "angle": angle,
                "mirror": flip,
            ] as JSONDictionary,
            "flip": flip,
            "scale": scale,
        ]
    }
}
