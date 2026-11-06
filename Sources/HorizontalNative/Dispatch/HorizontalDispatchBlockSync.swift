import Foundation
import HorizontalProjectIO

/// Keeping a block's instances laid out alike through MCP: after a batch's
/// own edits, what they did to one instance done in the instances laid out
/// like it (`HorizontalBlockLayoutSync`), written into the board file as
/// only those changes, so every byte the sync doesn't touch stays as the
/// batch left it. `sync: false` leaves the others alone. The app's own
/// switch is the app's: MCP says for itself.
enum HorizontalDispatchBlockSync {
    /// The batch in `store` made in the instances laid out like the ones it
    /// changed; what that did, or nil where it reached none. A batch whose
    /// edits to two instances disagree is refused, naming them.
    static func run(store: HorizontalArchiveFileStore, entry: HorizontalDispatchProjectEntry, params: JSONDictionary) throws -> JSONDictionary? {
        guard params.bool("sync") != false,
              let baseline = entry.project.board,
              entry.project.flattenedBlock?.boardInstances.isEmpty == false,
              let boardURL = entry.project.boardFilename.map({ entry.project.baseURL.appendingPathComponent($0) }),
              let before = entry.snapshot,
              let path = store.relativePath(for: boardURL),
              let data = store.archive.regularFileData(relativePath: path),
              data != before.archive.regularFileData(relativePath: path) else {
            return nil
        }
        let edited = try HorizontalDispatchSnapshot(archive: store.archive, baseURL: entry.project.baseURL).materializedProject()
        guard let board = edited.board, let instances = edited.flattenedBlock?.boardInstances, !instances.isEmpty,
              let changes = HorizontalBlockLayoutSync.propagate(baseline: baseline, edited: board, instances: instances, intent: .init(.other)) else {
            return nil
        }
        guard changes.report.conflicts.isEmpty else {
            throw HorizontalDispatchError(
                code: .invalidParams,
                message: "The batch changes block instances laid out alike in ways that disagree, so it can't keep them alike: "
                    + changes.report.conflicts.joined(separator: "; ")
                    + ". Edit one of them, or pass sync: false to edit each on its own.",
                details: ["conflicts": changes.report.conflicts, "reason": "block_sync_conflict"])
        }
        try write(changes, to: store, at: boardURL, board: board)
        return summary(changes)
    }

    /// What a sync did, for a reply.
    static func summary(_ changes: HorizontalBlockLayoutSync.ChangeSet) -> JSONDictionary {
        [
            "instances": changes.report.changed,
            "packages": changes.placements.count + changes.placed.count + changes.unplaced.count,
            "tracks": changes.tracks.count,
            "removed_tracks": changes.removedTracks.count,
            "vias": changes.vias.count,
            "removed_vias": changes.removedVias.count,
            "skipped": changes.report.skipped,
        ]
    }

    /// The change set written into the board file in `store`.
    static func write(_ changes: HorizontalBlockLayoutSync.ChangeSet, to store: HorizontalArchiveFileStore, at boardURL: URL,
                      board: HorizontalBoard) throws {
        guard let data = try store.read(boardURL),
              var json = try JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
            throw HorizontalDispatchError.failed("The board file can't be read.")
        }
        write(changes, into: &json, board: board)
        try store.write(try HorizontalHorizonJSONWriter.data(HorizontalHorizonFileConformance.conformed(json)), to: boardURL)
    }

    /// The change set written into a board file's JSON, as Horizon writes
    /// what it changes: placements, new package entries, junctions, tracks
    /// with their pad and junction ends, vias on their junctions; what it
    /// removes taken out, with the junctions only it used. `board` is the
    /// board the changes were read from, for where pads are.
    static func write(_ changes: HorizontalBlockLayoutSync.ChangeSet, into json: inout JSONDictionary, board: HorizontalBoard) {
        func int(_ value: Double) -> Int64 { Int64(value.rounded()) }
        func point(_ point: HorizontalPoint) -> [Int64] { [int(point.x), int(point.y)] }
        func placement(_ placement: HorizontalPlacementTransform) -> JSONDictionary {
            ["shift": point(placement.shift), "angle": placement.angle, "mirror": placement.mirrored]
        }
        func key(_ id: String, in map: JSONDictionary) -> String {
            map.keys.first { $0.lowercased() == id } ?? id
        }

        var packages = json.dictionaryMap("packages")
        var tracks = json.dictionaryMap("tracks")
        var junctions = json.dictionaryMap("junctions")
        var vias = json.dictionaryMap("vias")
        var released = Set<String>()

        // Parts.
        for id in changes.unplaced {
            let packageKey = key(id, in: packages)
            packages.removeValue(forKey: packageKey)
            // What ends on its pads ends where they were.
            for (trackKey, var track) in tracks {
                for end in ["from", "to"] {
                    guard let pad = track.dictionary(end)?.string("pad"), pad.lowercased().hasPrefix(id + "/"),
                          let position = board.packagePadPositions.first(where: { $0.key.lowercased() == pad.lowercased() })?.value else { continue }
                    let junction = HorizontalBlockLayoutSync.copyID(of: pad, in: "unplaced")
                    junctions[junction] = ["position": point(position)]
                    track[end] = ["junc": junction, "pad": NSNull()]
                }
                tracks[trackKey] = track
            }
        }
        for (id, value) in changes.placements {
            let packageKey = key(id, in: packages)
            guard var package = packages[packageKey] else { continue }
            package["placement"] = placement(value)
            package["flip"] = value.mirrored
            packages[packageKey] = package
        }
        for (id, flags) in changes.flags {
            let packageKey = key(id, in: packages)
            guard var package = packages[packageKey] else { continue }
            package["fixed"] = flags.fixed
            package["omit_silkscreen"] = flags.omitSilkscreen
            package["omit_outline"] = flags.omitOutline
            packages[packageKey] = package
        }
        for placed in changes.placed {
            packages[placed.packageID] = [
                "component": placed.componentID,
                "placement": placement(placed.placement),
                "flip": placed.placement.mirrored,
                "fixed": false,
                "omit_silkscreen": false,
                "smashed": false,
                "texts": [String](),
            ]
        }

        // Copper.
        for (id, position) in changes.junctions {
            let junctionKey = key(id, in: junctions)
            var junction = junctions[junctionKey] ?? [:]
            junction["position"] = point(position)
            junctions[junctionKey] = junction
        }
        for id in changes.removedTracks where changes.tracks[id] == nil {
            let trackKey = key(id, in: tracks)
            if let track = tracks.removeValue(forKey: trackKey) {
                released.formUnion(["from", "to"].compactMap { track.dictionary($0)?.string("junc")?.lowercased() })
            }
        }
        for (id, track) in changes.tracks.sorted(by: { $0.key < $1.key }) {
            func end(_ end: HorizontalBlockLayoutSync.End, _ name: String) -> JSONDictionary {
                switch end {
                case .pad(let path):
                    // The file's own spelling of the package and pad.
                    let spelled = board.packagePadPositions.keys.first { $0.lowercased() == path } ?? path
                    return ["junc": NSNull(), "pad": spelled]
                case .junction(let junction):
                    return ["junc": key(junction, in: junctions), "pad": NSNull()]
                case .point(let position):
                    let junction = HorizontalBlockLayoutSync.copyID(of: id + "@" + name, in: "end")
                    junctions[junction] = ["position": point(position)]
                    return ["junc": junction, "pad": NSNull()]
                }
            }
            let trackKey = key(id, in: tracks)
            var item = tracks[trackKey] ?? [:]
            item["from"] = end(track.from, "from")
            item["to"] = end(track.to, "to")
            item["layer"] = track.segment.layer ?? HorizontalBoardLayers.topCopper
            item["width"] = int(track.segment.width)
            item["width_from_net_class"] = track.segment.widthFromRules
            item["locked"] = track.segment.locked
            if let center = track.segment.center {
                item["center"] = point(center)
            } else {
                item.removeValue(forKey: "center")
            }
            // The net a track stores is a cache of the one it was drawn on,
            // which a copy isn't.
            item.removeValue(forKey: "net")
            tracks[trackKey] = item
        }
        for id in changes.removedVias where changes.vias[id] == nil {
            let viaKey = key(id, in: vias)
            if let via = vias.removeValue(forKey: viaKey), let junction = via.string("junction") {
                released.insert(junction.lowercased())
            }
        }
        // A new via stands on the junction at its point, the first by id.
        var byPosition = [String: String]()
        for (junctionKey, junction) in junctions {
            guard let position = junction["position"] as? [Any], position.count == 2 else { continue }
            let at = "\(int(JSONHelper.doubleValue(position[0]))):\(int(JSONHelper.doubleValue(position[1])))"
            if let existing = byPosition[at], existing <= junctionKey { continue }
            byPosition[at] = junctionKey
        }
        for (id, via) in changes.vias.sorted(by: { $0.key < $1.key }) {
            let viaKey = key(id, in: vias)
            var item: JSONDictionary
            if let existing = vias[viaKey] {
                item = HorizontalProjectJSONApplicator.viaJSONEntry(via, existing: existing)
            } else {
                guard let junction = byPosition["\(int(via.position.x)):\(int(via.position.y))"] else { continue }
                var parameters = via.parameterSet.reduce(into: JSONDictionary()) { $0[$1.key] = int($1.value) }
                parameters["via_diameter"] = int(via.size)
                if let hole = via.holeSize { parameters["hole_diameter"] = int(hole) }
                item = [
                    "junction": junction,
                    "padstack": via.padstackID ?? board.defaultViaPadstackID,
                    "parameter_set": parameters,
                    "from_rules": via.fromRules,
                    "source": via.fromRules ? "rules" : (via.definitionID != nil ? "definition" : "local"),
                    "locked": via.locked,
                ]
                if let definition = via.definitionID { item["definition"] = definition }
                if let span = via.span, !span.isThrough { item["span"] = span.json }
            }
            if let net = via.netSetID {
                item["net_set"] = net
            } else {
                item.removeValue(forKey: "net_set")
            }
            vias[viaKey] = item
        }

        // The junctions only removed copper stood on.
        if !released.isEmpty {
            var used = Set<String>()
            for track in tracks.values {
                for end in ["from", "to"] { if let junction = track.dictionary(end)?.string("junc") { used.insert(junction.lowercased()) } }
            }
            for via in vias.values { if let junction = via.string("junction") { used.insert(junction.lowercased()) } }
            for id in released where !used.contains(id) {
                junctions.removeValue(forKey: key(id, in: junctions))
            }
        }

        // Texts smashed out of packages: a board's own texts in the file,
        // drawn where a moved package takes them and where an edit of one
        // put its counterpart.
        var texts = json.dictionaryMap("texts")
        func write(_ text: HorizontalText) {
            guard let range = text.id.range(of: "/text/") else { return }
            let textKey = key(String(text.id[range.upperBound...]).lowercased(), in: texts)
            guard var item = texts[textKey] else { return }
            item["placement"] = HorizontalSmash.storedPlacement(drawing: HorizontalPlacementTransform(
                shift: text.position, angle: text.angle, mirrored: text.mirrored))
            if let layer = text.layer { item["layer"] = layer }
            texts[textKey] = item
        }
        let innerLayers = max(board.copperLayerCount - 2, 0)
        for (id, value) in changes.placements {
            guard let package = board.packages.first(where: { $0.id.lowercased() == id }) else { continue }
            let motion = HorizontalBoardMotion(value.accumulated(with: HorizontalBoard.placementTransform(of: package).inverse),
                                               innerLayerCount: innerLayers)
            for text in HorizontalBlockLayoutSync.smashedTexts(of: package, on: board) where changes.texts[text.id.lowercased()] == nil {
                write(motion.text(text))
            }
        }
        for text in changes.texts.values {
            write(text)
        }

        // Only what changed goes back: a board without texts gets no texts.
        for (name, map) in [("packages", packages), ("tracks", tracks), ("junctions", junctions), ("vias", vias), ("texts", texts)] {
            let original = json.dictionaryMap(name)
            if !(original as NSDictionary).isEqual(to: map) {
                json[name] = map
            }
        }
    }
}
