import Foundation

/// find_stubs: copper that goes nowhere. Dead-end runs of track with what
/// each end touches (`HorizontalBoardTrackStubs`, whose dead ends the rules
/// check lists as findings), vias joined on fewer than two layers, and tracks
/// lying wholly inside one pad.
enum HorizontalDispatchStubs {
    typealias Geometry = HorizontalDispatchBoardGeometry

    static func findStubs(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        let items = try Geometry.items(entry)
        let wanted = try params.string("net").flatMap { $0.isEmpty ? nil : $0 }.map { try Geometry.netID($0, entry: entry) }
        let region = try Geometry.region(params)
        let names = HorizontalBoardRulesCheck.padNames(board)

        func describe(_ end: HorizontalTrackStub.End) -> JSONDictionary {
            var json: JSONDictionary = HorizontalDispatchJSON.point(end.position)
            switch end.touch {
            case .pad(let path):
                json["touches"] = "pad"
                json["pad"] = names[path] ?? path
            case .via(let id):
                json["touches"] = "via"
                json["via"] = id
            case .junction(let tracks):
                json["touches"] = "junction"
                json["tracks"] = tracks
            case .nothing where end.liesIn.isEmpty:
                json["touches"] = "nothing"
            case .nothing:
                json["lies_in"] = end.liesIn
                json["touches"] = "copper it shares no junction with"
            }
            return json
        }

        var chains = [JSONDictionary]()
        for stub in HorizontalBoardTrackStubs.stubs(of: board, items: items) {
            let net = stub.netID
            if let wanted, net != wanted { continue }
            if let region, !stub.tracks.contains(where: { Geometry.reaches(.path($0.pathPoints, halfWidth: $0.width / 2), into: region) }) { continue }
            chains.append([
                "tracks": stub.tracks.map(\.id), "net": net as Any? as Any,
                "net_name": net.flatMap { board.netDetails[$0]?.name } as Any? as Any,
                "layers": Array(Set(stub.tracks.compactMap(\.layer))).sorted(by: >),
                "length_mm": HorizontalDispatchJSON.mm(stub.length),
                "ends": [describe(stub.free), describe(stub.far)],
                "dead_end": stub.isDeadEnd,
                "note": !stub.isDeadEnd
                    ? "Its free end shares no junction with anything but lies in copper of the board: it may be carrying its net there. Check before removing it."
                    : (stub.joinsNothing ? "Both ends are free: it joins nothing." : "One end is free: a stub."),
            ])
        }

        // Vias that join fewer than two layers.
        var loneVias = [JSONDictionary]()
        for via in board.vias {
            let net = via.netID?.lowercased()
            if let wanted, net != wanted { continue }
            if let region, !Geometry.reaches(.disc(via.position, radius: via.size / 2), into: region) { continue }
            let here = HorizontalBoardItem.Shape.disc(via.position, radius: via.size / 2)
            var joined = Set<Int>()
            for index in items.indices(overlapping: HorizontalRouteClearanceProbe.bounds([via.position], growth: via.size / 2)) {
                let item = items.items[index]
                guard item.kind.isCopper, item.kind != .via, item.netID == net, net != nil,
                      HorizontalShapeGap.between(here, item.shape, limit: 0) != nil else { continue }
                joined.formUnion(via.copperLayers.filter(item.isOn))
            }
            guard joined.count < 2 else { continue }
            loneVias.append(["via": via.id, "net": net as Any? as Any, "net_name": net.flatMap { board.netDetails[$0]?.name } as Any? as Any,
                             "x_mm": HorizontalDispatchJSON.mm(via.position.x), "y_mm": HorizontalDispatchJSON.mm(via.position.y),
                             "layers": via.copperLayers.sorted(by: >), "joined_on": joined.sorted(by: >)])
        }

        // Tracks with both ends in one pad.
        var inPad = [JSONDictionary]()
        for track in board.tracks {
            guard let layer = track.layer else { continue }
            let net = track.netID?.lowercased()
            if let wanted, net != wanted { continue }
            if let region, !Geometry.reaches(.path(track.pathPoints, halfWidth: track.width / 2), into: region) { continue }
            for index in items.indices(overlapping: HorizontalRouteClearanceProbe.bounds([track.from, track.to], growth: 1)) {
                let item = items.items[index]
                guard item.kind == .pad || item.kind == .padThroughHole, item.isOn(layer),
                      item.shape.encloses(track.from), item.shape.encloses(track.to) else { continue }
                inPad.append(["track": track.id, "pad": item.label, "pad_id": item.id, "layer": layer,
                              "length_mm": HorizontalDispatchJSON.mm(HorizontalRoute45.length(of: track.pathPoints))])
                break
            }
        }

        let limit = min(max(params.int("limit") ?? 200, 1), 5000)
        func capped(_ list: [JSONDictionary]) -> [JSONDictionary] { Array(list.prefix(limit)) }
        return [
            "stubs": capped(chains), "stub_count": chains.count,
            "vias_on_one_layer": capped(loneVias), "via_count": loneVias.count,
            "tracks_in_a_pad": capped(inPad), "in_pad_count": inPad.count,
            "truncated": max(chains.count, loneVias.count, inPad.count) > limit,
            "note": "A stub is a run of track with an end on nothing; ends says what each end touches, by junction and by the copper it lies in. A via is listed when copper of its net meets it on fewer than two of its layers, fills as last poured included.",
        ] as JSONDictionary
    }
}
