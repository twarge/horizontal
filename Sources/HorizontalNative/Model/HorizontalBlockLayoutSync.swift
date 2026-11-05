import Foundation

/// Keeps a block's instances laid out alike on the board: an edit to one
/// instance's parts or copper, made the same in every instance laid out like
/// it (`HorizontalBlockLayoutMatch`), through the motion that takes the one
/// onto the other.
///
/// It reads what an edit did from the board before it (`baseline`) and
/// after (`edited`), and says what the edit does to the other instances as a
/// change set, which `apply(_:to:poolURL:)` makes on a board and the MCP
/// writes into the board file. Nothing about it is stored: which instances
/// are laid out alike is found from the board each time.
///
/// What it carries over:
/// - A part an edit moves, turns, flips or sets a flag on, where the other
///   instance's part is laid out alike; a part newly placed, where the other
///   instance's is unplaced; a part taken off the board.
/// - The instance's own copper (`owned`) an edit adds, moves, reshapes or
///   deletes; copper it merely takes out of the instance stays where it is
///   in the others.
///
/// What it leaves: an instance moved as a whole, its laid out parts all by
/// one motion (nothing in it changed in its own frame); a fixed part, a
/// locked track or via, and one the edit changed in the other instance too
/// in another way, which it reports.
enum HorizontalBlockLayoutSync {
    /// What made the edit, which the report names.
    struct Intent: Equatable {
        enum Kind: String, Equatable {
            case move, transform, drawTrack, delete, paste, duplicate, properties, placePackage, flags, tune, other
        }
        var kind: Kind

        init(_ kind: Kind) {
            self.kind = kind
        }
    }

    /// A track end in the instance an edit is copied to: on a pad, by its
    /// path (`<package>/<pad>`), on a junction, or at a point.
    enum End: Equatable {
        case pad(String)
        case junction(String)
        case point(HorizontalPoint)
    }

    struct Track: Equatable {
        var segment: HorizontalSegment
        var from: End
        var to: End
    }

    /// A part placed in an instance, as the edit placed it in another.
    struct Placement: Equatable {
        var componentID: String
        var placement: HorizontalPlacementTransform
        /// The package placed in the instance the edit was made in.
        var sourcePackageID: String
        /// The id the new package takes: the same every time, for a dry run
        /// and its commit to agree.
        var packageID: String
    }

    /// A package's flags as the edit set them.
    struct Flags: Equatable {
        var fixed: Bool
        var omitSilkscreen: Bool
        var omitOutline: Bool
    }

    struct Report: Equatable {
        /// The instances the edit changed besides the one it was made in.
        var changed = [String]()
        /// What it left, and why.
        var skipped = [String]()
        /// Elements the edit changed in two instances in ways that disagree.
        var conflicts = [String]()

        var isEmpty: Bool { changed.isEmpty && skipped.isEmpty && conflicts.isEmpty }
    }

    struct ChangeSet: Equatable {
        /// Packages that move, by id, and where to.
        var placements = [String: HorizontalPlacementTransform]()
        var flags = [String: Flags]()
        var placed = [Placement]()
        var unplaced = Set<String>()
        /// Junctions that move or are added, by id.
        var junctions = [String: HorizontalPoint]()
        /// Tracks that change or are added, by id.
        var tracks = [String: Track]()
        var removedTracks = Set<String>()
        /// Vias that change or are added, by id.
        var vias = [String: HorizontalMarker]()
        var removedVias = Set<String>()
        /// Texts smashed out of packages that move, by id (`<package>/text/<uuid>`):
        /// where they are drawn, the text itself the package's own.
        var texts = [String: HorizontalText]()
        var report = Report()

        var isEmpty: Bool {
            placements.isEmpty && flags.isEmpty && placed.isEmpty && unplaced.isEmpty && junctions.isEmpty
                && tracks.isEmpty && removedTracks.isEmpty && vias.isEmpty && removedVias.isEmpty && texts.isEmpty
        }
    }

    /// The texts smashed out of `package` on `board`, by id, lowercased.
    static func smashedTexts(of package: HorizontalPlacement, on board: HorizontalBoard) -> [HorizontalText] {
        let prefix = package.id.lowercased() + "/text/"
        return board.packageTexts.filter { $0.fromSmash && $0.id.lowercased().hasPrefix(prefix) }.sorted { $0.id < $1.id }
    }

    /// The text of `targets` that is `text`'s in another instance: the same
    /// stored text (`$RD`), on the layer the motion takes it to, the nearest
    /// to where the motion takes it.
    static func counterpart(of text: HorizontalText, among targets: [HorizontalText], motion: HorizontalBoardMotion) -> HorizontalText? {
        let stored = text.placeholder?.stored ?? text.text
        let landing = motion.point(text.position)
        return targets
            .filter { ($0.placeholder?.stored ?? $0.text) == stored && $0.layer == text.layer.map(motion.layer) }
            .min { HorizontalBlockLayoutMatch.distance($0.position, landing) < HorizontalBlockLayoutMatch.distance($1.position, landing) }
    }

    /// `text` where the motion puts it, as `target` draws it: its place, angle,
    /// side and layer, the words its own.
    static func moved(_ text: HorizontalText, onto target: HorizontalText, motion: HorizontalBoardMotion) -> HorizontalText {
        let placed = motion.text(text)
        var result = target
        result.position = placed.position.rounded
        result.angle = placed.angle
        result.mirrored = placed.mirrored
        result.layer = placed.layer
        return result
    }

    /// The namespace copies' ids are made in.
    static let namespace = UUID(uuidString: "6b1f3c52-0a4e-4d8e-9a57-3c2f1e8b7d40")!

    /// The id the copy of `sourceID` takes in the instance at `path`: the
    /// same for the same two every time.
    static func copyID(of sourceID: String, in path: String) -> String {
        UUID.horizonUUID5(namespace: namespace, name: Array((sourceID.lowercased() + "@" + path).utf8)).uuidString.lowercased()
    }

    // MARK: - Reading the edit

    /// What `edited` makes of `baseline` in the instances laid out like the
    /// ones it changed; nil when nothing reaches another instance.
    static func propagate(
        baseline: HorizontalBoard,
        edited: HorizontalBoard,
        instances: HorizontalBoardBlockInstances,
        intent: Intent
    ) -> ChangeSet? {
        guard !instances.isEmpty else {
            return nil
        }
        let before = HorizontalBlockLayoutMatch(board: baseline, instances: instances)
        guard !before.classes.isEmpty else {
            return nil
        }
        var planner = Planner(before: before, after: HorizontalBlockLayoutMatch(board: edited, instances: instances),
                              baseline: baseline, edited: edited, instances: instances)
        planner.plan()
        return planner.changes.isEmpty && planner.changes.report.isEmpty ? nil : planner.changes
    }

    private struct Planner {
        let before: HorizontalBlockLayoutMatch
        let after: HorizontalBlockLayoutMatch
        let baseline: HorizontalBoard
        let edited: HorizontalBoard
        let instances: HorizontalBoardBlockInstances
        var changes = ChangeSet()

        private let basePackages: [String: HorizontalPlacement]
        private let editPackages: [String: HorizontalPlacement]
        private let editByComponent: [String: HorizontalPlacement]
        private let baseTracks: [String: HorizontalSegment]
        private let editTracks: [String: HorizontalSegment]
        private let baseVias: [String: HorizontalMarker]
        private let editVias: [String: HorizontalMarker]
        private let baseJunctions: [String: HorizontalPoint]
        private let editJunctions: [String: HorizontalPoint]
        private let editPadPaths: [String: String]
        private let innerLayers: Int
        /// What the edit itself changed, which a copy doesn't overwrite.
        private var touched = Set<String>()
        /// Who planned each target's value, for telling two sources that
        /// disagree.
        private var plannedBy = [String: String]()
        private var plannedValues = [String: String]()
        private var changedNames = Set<String>()

        init(before: HorizontalBlockLayoutMatch, after: HorizontalBlockLayoutMatch,
             baseline: HorizontalBoard, edited: HorizontalBoard, instances: HorizontalBoardBlockInstances) {
            self.before = before
            self.after = after
            self.baseline = baseline
            self.edited = edited
            self.instances = instances
            func byID<T>(_ items: [T], _ id: (T) -> String) -> [String: T] {
                items.reduce(into: [String: T]()) { $0[id($1).lowercased()] = $1 }
            }
            basePackages = byID(baseline.packages, \.id)
            editPackages = byID(edited.packages, \.id)
            editByComponent = edited.packages.reduce(into: [String: HorizontalPlacement]()) {
                if let component = $1.componentID?.lowercased() { $0[component] = $1 }
            }
            baseTracks = byID(baseline.tracks.filter { !$0.id.contains("/") }, \.id)
            editTracks = byID(edited.tracks.filter { !$0.id.contains("/") }, \.id)
            baseVias = byID(baseline.vias.filter { !$0.id.contains("/") }, \.id)
            editVias = byID(edited.vias.filter { !$0.id.contains("/") }, \.id)
            baseJunctions = baseline.junctions.reduce(into: [String: HorizontalPoint]()) { $0[$1.key.lowercased()] = $1.value }
            editJunctions = edited.junctions.reduce(into: [String: HorizontalPoint]()) { $0[$1.key.lowercased()] = $1.value }
            var padPaths = [String: String]()
            for (path, point) in edited.packagePadPositions {
                let key = HorizontalBoard.junctionPointKey(point), lowered = path.lowercased()
                if let existing = padPaths[key], existing <= lowered { continue }
                padPaths[key] = lowered
            }
            editPadPaths = padPaths
            innerLayers = max(edited.copperLayerCount - 2, 0)

            for (id, package) in editPackages where basePackages[id].map({ Self.packageDiffers($0, package) }) ?? true {
                touched.insert("package:" + id)
            }
            for id in Set(basePackages.keys).subtracting(editPackages.keys) { touched.insert("package:" + id) }
            for (id, track) in editTracks where baseTracks[id].map({ Self.trackDiffers($0, track) }) ?? true {
                touched.insert("track:" + id)
            }
            for id in Set(baseTracks.keys).subtracting(editTracks.keys) { touched.insert("track:" + id) }
            for (id, via) in editVias where baseVias[id].map({ Self.viaDiffers($0, via) }) ?? true {
                touched.insert("via:" + id)
            }
            for id in Set(baseVias.keys).subtracting(editVias.keys) { touched.insert("via:" + id) }
            for (id, point) in editJunctions where baseJunctions[id] != point {
                touched.insert("junction:" + id)
            }
        }

        static func packageDiffers(_ a: HorizontalPlacement, _ b: HorizontalPlacement) -> Bool {
            a.position != b.position || a.angle != b.angle || a.mirrored != b.mirrored
                || a.fixed != b.fixed || a.omitSilkscreen != b.omitSilkscreen || a.omitOutline != b.omitOutline
        }

        static func trackDiffers(_ a: HorizontalSegment, _ b: HorizontalSegment) -> Bool {
            a.from != b.from || a.to != b.to || a.layer != b.layer || a.width != b.width || a.center != b.center
                || a.widthFromRules != b.widthFromRules || a.locked != b.locked
                || a.fromJunctionID?.lowercased() != b.fromJunctionID?.lowercased()
                || a.toJunctionID?.lowercased() != b.toJunctionID?.lowercased()
        }

        static func viaDiffers(_ a: HorizontalMarker, _ b: HorizontalMarker) -> Bool {
            a.position != b.position || a.size != b.size || a.holeSize != b.holeSize
                || a.padstackID?.lowercased() != b.padstackID?.lowercased()
                || a.definitionID?.lowercased() != b.definitionID?.lowercased()
                || a.fromRules != b.fromRules || a.parameterSet != b.parameterSet
                || a.copperLayers != b.copperLayers || a.netSetID != b.netSetID || a.locked != b.locked
        }

        mutating func plan() {
            // Innermost instances first, then by name.
            let sources = before.layouts.values.map(\.instance).sorted { lhs, rhs in
                let l = lhs.path.split(separator: "/").count, r = rhs.path.split(separator: "/").count
                return l != r ? l > r : HorizontalBoardBlockInstances.inOrder(lhs, rhs)
            }
            for source in sources {
                plan(from: source)
            }
            changes.report.changed = changedNames.compactMap { path in instances.instances[path] }
                .sorted(by: HorizontalBoardBlockInstances.inOrder).map(\.name)
        }

        private mutating func plan(from source: HorizontalBoardBlockInstances.Instance) {
            let path = source.path
            let classmates = before.classmates(of: path)
            guard !classmates.isEmpty, let layout = before.layouts[path] else {
                return
            }

            // The parts the edit changed, placed, or took off the board.
            var moved = [String: (old: HorizontalPlacement, new: HorizontalPlacement)]()
            var placed = [String: HorizontalPlacement]()
            var unplaced = Set<String>()
            for (local, flatID) in source.members {
                let old = layout.packages[local], new = editByComponent[flatID]
                switch (old, new) {
                case let (old?, new?) where Self.packageDiffers(old, new):
                    moved[local] = (old, new)
                case (nil, let new?):
                    placed[local] = new
                case (_?, nil):
                    unplaced.insert(local)
                default:
                    break
                }
            }
            let ownedBefore = before.owned(path), ownedAfter = after.owned(path)
            let changedTracks = ownedBefore.tracks.filter { id in editTracks[id].map { Self.trackDiffers(baseTracks[id]!, $0) } ?? false }
            let removedTracks = ownedBefore.tracks.filter { editTracks[$0] == nil }
            let addedTracks = ownedAfter.tracks.filter { baseTracks[$0] == nil }
            let changedJunctions = ownedBefore.junctions.filter { id in editJunctions[id].map { $0 != baseJunctions[id] } ?? false }
            let addedJunctions = ownedAfter.junctions.filter { baseJunctions[$0] == nil }
            let changedVias = ownedBefore.vias.filter { id in editVias[id].map { Self.viaDiffers(baseVias[id]!, $0) } ?? false }
            let removedVias = ownedBefore.vias.filter { editVias[$0] == nil }
            let addedVias = ownedAfter.vias.filter { baseVias[$0] == nil }
            let copperChanged = !(changedTracks.isEmpty && removedTracks.isEmpty && addedTracks.isEmpty
                && changedJunctions.isEmpty && addedJunctions.isEmpty && changedVias.isEmpty && removedVias.isEmpty && addedVias.isEmpty)
            let textsChanged = layout.packages.values.contains { package in
                guard let editedPackage = editPackages[package.id.lowercased()] else { return false }
                return HorizontalBlockLayoutSync.smashedTexts(of: package, on: baseline) != HorizontalBlockLayoutSync.smashedTexts(of: editedPackage, on: edited)
            }
            guard !moved.isEmpty || !placed.isEmpty || !unplaced.isEmpty || copperChanged || textsChanged else {
                return
            }
            if movedAsAWhole(layout: layout, moved: moved, classmates: classmates) {
                return
            }

            for target in classmates {
                guard let pair = before.pair(from: path, to: target), pair.related,
                      let targetInstance = instances.instances[target],
                      let targetLayout = before.layouts[target] else { continue }
                let motion = HorizontalBoardMotion(pair.transform, innerLayerCount: innerLayers)
                var packageMap = [String: String]()  // source package → target package
                for (local, package) in layout.packages {
                    if let other = targetLayout.packages[local] { packageMap[package.id.lowercased()] = other.id.lowercased() }
                }

                // Parts.
                for (local, change) in moved.sorted(by: { $0.key < $1.key }) where pair.synced.contains(local) {
                    guard let targetPackage = targetLayout.packages[local] else { continue }
                    let id = targetPackage.id.lowercased()
                    let label = "\(refdes(targetPackage)) in \(targetInstance.name)"
                    if targetPackage.fixed {
                        changes.report.skipped.append("\(label) is fixed")
                        continue
                    }
                    let placementChanged = change.old.position != change.new.position || change.old.angle != change.new.angle
                        || change.old.mirrored != change.new.mirrored
                    if placementChanged {
                        let placement = pair.transform.accumulated(with: HorizontalBoard.placementTransform(of: change.new)).rounded
                        if claim("package:" + id, by: path, label: label, value: Self.signature(placement), agrees: editPackages[id].map { Self.samePlacement(HorizontalBoard.placementTransform(of: $0), placement) } ?? false) {
                            changes.placements[id] = placement
                            changedNames.insert(target)
                        }
                    }
                    if change.old.fixed != change.new.fixed || change.old.omitSilkscreen != change.new.omitSilkscreen
                        || change.old.omitOutline != change.new.omitOutline {
                        changes.flags[id] = Flags(fixed: change.new.fixed, omitSilkscreen: change.new.omitSilkscreen, omitOutline: change.new.omitOutline)
                        changedNames.insert(target)
                    }
                }
                for (local, package) in placed.sorted(by: { $0.key < $1.key }) {
                    guard let componentID = targetInstance.members[local], editByComponent[componentID] == nil else { continue }
                    let placement = pair.transform.accumulated(with: HorizontalBoard.placementTransform(of: package)).rounded
                    let packageID = HorizontalBlockLayoutSync.copyID(of: package.id, in: target)
                    if claim("place:" + componentID, by: path, label: "\(refdes(package)) in \(targetInstance.name)", value: Self.signature(placement), agrees: false) {
                        changes.placed.append(Placement(componentID: componentID, placement: placement,
                                                        sourcePackageID: package.id.lowercased(), packageID: packageID))
                        packageMap[package.id.lowercased()] = packageID
                        changedNames.insert(target)
                    }
                }
                // The texts smashed out of its parts, moved on their own.
                for (local, package) in layout.packages.sorted(by: { $0.key < $1.key }) where pair.synced.contains(local) {
                    guard let targetPackage = targetLayout.packages[local],
                          let editedPackage = editPackages[package.id.lowercased()] else { continue }
                    let baseTexts = HorizontalBlockLayoutSync.smashedTexts(of: package, on: baseline)
                    let editTexts = HorizontalBlockLayoutSync.smashedTexts(of: editedPackage, on: edited)
                    let targets = HorizontalBlockLayoutSync.smashedTexts(of: targetPackage, on: baseline)
                    for text in editTexts {
                        guard let old = baseTexts.first(where: { $0.id == text.id }),
                              old.position != text.position || old.angle != text.angle || old.mirrored != text.mirrored || old.layer != text.layer,
                              let theirs = HorizontalBlockLayoutSync.counterpart(of: old, among: targets, motion: motion) else { continue }
                        let copy = HorizontalBlockLayoutSync.moved(text, onto: theirs, motion: motion)
                        let id = theirs.id.lowercased()
                        if claim("text:" + id, by: path, label: "a text in \(targetInstance.name)",
                                 value: Self.signature(copy.position) + ",\(copy.angle),\(copy.mirrored),\(copy.layer ?? 0)",
                                 agrees: false) {
                            changes.texts[id] = copy
                            changedNames.insert(target)
                        }
                    }
                }
                for local in unplaced.sorted() where pair.synced.contains(local) {
                    guard let targetPackage = targetLayout.packages[local], editPackages[targetPackage.id.lowercased()] != nil else { continue }
                    if targetPackage.fixed {
                        changes.report.skipped.append("\(refdes(targetPackage)) in \(targetInstance.name) is fixed")
                        continue
                    }
                    changes.unplaced.insert(targetPackage.id.lowercased())
                    changedNames.insert(target)
                }

                // Copper.
                guard copperChanged else { continue }
                let map = before.copper(from: path, to: target)
                // What the edit added there itself, or the instance has, where
                // a copy would go: drawn in both, it is copied in neither.
                let targetOwned = after.owned(target)
                func isTargets(_ id: String, base: [String: some Any]) -> Bool {
                    targetOwned.junctions.contains(id) || targetOwned.vias.contains(id) || targetOwned.tracks.contains(id) || base[id] == nil
                }
                var junctionIDs = map.junctions
                var reused = Set<String>()
                for id in addedJunctions.sorted() {
                    guard let point = editJunctions[id] else { continue }
                    let landing = motion.point(point)
                    if let existing = editJunctions.keys.sorted().first(where: { key in
                        key != id && !ownedAfter.junctions.contains(key) && isTargets(key, base: baseJunctions)
                            && HorizontalBlockLayoutMatch.distance(editJunctions[key]!, landing) <= 2
                    }) {
                        junctionIDs[id] = existing
                        reused.insert(id)
                    } else {
                        junctionIDs[id] = HorizontalBlockLayoutSync.copyID(of: id, in: target)
                    }
                }
                var viaIDs = map.vias
                for id in addedVias.sorted() {
                    guard let via = editVias[id] else { continue }
                    let landing = motion.point(via.position)
                    if let existing = editVias.keys.sorted().first(where: { key in
                        key != id && !ownedAfter.vias.contains(key) && isTargets(key, base: baseVias)
                            && HorizontalBlockLayoutMatch.distance(editVias[key]!.position, landing) <= 2
                    }) {
                        viaIDs[id] = existing
                        reused.insert(id)
                    } else {
                        viaIDs[id] = HorizontalBlockLayoutSync.copyID(of: id, in: target)
                    }
                }

                for id in (changedJunctions.union(addedJunctions)).sorted() where !reused.contains(id) {
                    guard let targetID = junctionIDs[id], let point = editJunctions[id] else { continue }
                    let landing = motion.point(point).rounded
                    if claim("junction:" + targetID, by: path, label: "a junction in \(targetInstance.name)", value: Self.signature(landing), agrees: editJunctions[targetID].map { HorizontalBlockLayoutMatch.distance($0, landing) <= 2 } ?? false) {
                        changes.junctions[targetID] = landing
                        changedNames.insert(target)
                    }
                }

                for id in (changedTracks.union(addedTracks)).sorted() {
                    guard let track = editTracks[id] else { continue }
                    let counterpart = map.tracks[id]
                    if counterpart == nil, !addedTracks.contains(id) {
                        continue
                    }
                    if let counterpart, baseTracks[counterpart.id]?.locked == true {
                        changes.report.skipped.append("a locked track in \(targetInstance.name)")
                        continue
                    }
                    guard let from = end(of: track, at: \.from, junction: track.fromJunctionID, junctionIDs: junctionIDs, packageMap: packageMap, motion: motion),
                          let to = end(of: track, at: \.to, junction: track.toJunctionID, junctionIDs: junctionIDs, packageMap: packageMap, motion: motion) else {
                        continue
                    }
                    let reversed = counterpart?.reversed ?? motion.mirrors
                    var segment = motion.segment(track)
                    segment.reverse = false
                    if reversed {
                        swap(&segment.from, &segment.to)
                    }
                    let ends = reversed ? (to, from) : (from, to)
                    var targetID = counterpart?.id ?? HorizontalBlockLayoutSync.copyID(of: id, in: target)
                    // A track whose ends changed what they are on is made
                    // again: the file names a track's pad ends once.
                    if let counterpart, let existing = baseTracks[counterpart.id], !sameKind(existing, ends: ends) {
                        changes.removedTracks.insert(counterpart.id)
                        targetID = HorizontalBlockLayoutSync.copyID(of: id + "+", in: target)
                    }
                    if counterpart == nil, existingTrack(matching: segment, among: editTracks.filter { key, _ in
                        key != id && !ownedAfter.tracks.contains(key) && isTargets(key, base: baseTracks)
                    }.values) != nil {
                        continue
                    }
                    segment.id = targetID
                    segment.fromJunctionID = ends.0.junctionID
                    segment.toJunctionID = ends.1.junctionID
                    if claim("track:" + targetID, by: path, label: "a track in \(targetInstance.name)", value: Self.signature(segment, ends: ends), agrees: editTracks[targetID].map { !Self.trackDiffers($0, segment) } ?? false) {
                        changes.tracks[targetID] = Track(segment: segment, from: ends.0, to: ends.1)
                        changedNames.insert(target)
                    }
                }
                for id in removedTracks.sorted() {
                    guard let counterpart = map.tracks[id] else { continue }
                    if baseTracks[counterpart.id]?.locked == true {
                        changes.report.skipped.append("a locked track in \(targetInstance.name)")
                        continue
                    }
                    if claim("track:" + counterpart.id, by: path, label: "a track in \(targetInstance.name)", value: "removed", agrees: editTracks[counterpart.id] == nil) {
                        changes.removedTracks.insert(counterpart.id)
                        changedNames.insert(target)
                    }
                }

                for id in (changedVias.union(addedVias)).sorted() where !reused.contains(id) {
                    guard let via = editVias[id], let targetID = viaIDs[id] else { continue }
                    if !addedVias.contains(id), map.vias[id] == nil {
                        continue
                    }
                    if baseVias[targetID]?.locked == true {
                        changes.report.skipped.append("a locked via in \(targetInstance.name)")
                        continue
                    }
                    var copy = via
                    copy.id = targetID
                    copy.position = motion.point(via.position).rounded
                    let layers = via.copperLayers.map(motion.layer).sorted()
                    copy.connectedLayers = via.connectedLayers.isEmpty ? [] : layers
                    if let top = layers.max(), let bottom = layers.min() {
                        let span = HorizontalViaSpan(start: top, end: bottom)
                        copy.span = span.isThrough && via.span == nil ? nil : span
                    }
                    copy.netSetID = via.netSetID.flatMap { mappedNet($0, from: source, to: targetInstance) }
                    copy.netID = copy.netSetID
                    if claim("via:" + targetID, by: path, label: "a via in \(targetInstance.name)", value: Self.signature(copy.position) + "\(copy.copperLayers)", agrees: editVias[targetID].map { !Self.viaDiffers($0, copy) } ?? false) {
                        changes.vias[targetID] = copy
                        changedNames.insert(target)
                    }
                }
                for id in removedVias.sorted() {
                    guard let targetID = map.vias[id] else { continue }
                    if baseVias[targetID]?.locked == true {
                        changes.report.skipped.append("a locked via in \(targetInstance.name)")
                        continue
                    }
                    if claim("via:" + targetID, by: path, label: "a via in \(targetInstance.name)", value: "removed", agrees: editVias[targetID] == nil) {
                        changes.removedVias.insert(targetID)
                        changedNames.insert(target)
                    }
                }
            }
        }

        /// Whether every part of the instance laid out like another moved, by
        /// one motion: the instance moved as a whole, nothing in it changed.
        private func movedAsAWhole(
            layout: HorizontalBlockLayoutMatch.Layout,
            moved: [String: (old: HorizontalPlacement, new: HorizontalPlacement)],
            classmates: [String]
        ) -> Bool {
            let synced = classmates.reduce(into: Set<String>()) { result, target in
                result.formUnion(before.pair(from: layout.instance.path, to: target)?.synced ?? [])
            }
            guard synced.count >= 2, synced.allSatisfy({ moved[$0] != nil }) else {
                return false
            }
            let motions = synced.sorted().compactMap { local -> HorizontalPlacementTransform? in
                guard let change = moved[local] else { return nil }
                return HorizontalBoard.placementTransform(of: change.new)
                    .accumulated(with: HorizontalBoard.placementTransform(of: change.old).inverse)
            }
            guard let first = motions.first, !Self.samePlacement(first, .identity) else { return false }
            return motions.allSatisfy { Self.samePlacement($0, first, tolerance: 50) }
        }

        /// Takes the right to set `target` to `value` for `source`. The edit's
        /// own change to it stands: a copy that agrees is left out, one that
        /// doesn't is reported. A target already set the same way (by
        /// another instance, or through a block around this one) is left
        /// out too, a different way reported.
        private mutating func claim(_ target: String, by source: String, label: String, value: String, agrees: Bool) -> Bool {
            if touched.contains(target) {
                if !agrees {
                    changes.report.conflicts.append("\(label): changed here and in \(name(source)) in different ways")
                }
                return false
            }
            if let owner = plannedBy[target] {
                if plannedValues[target] != value {
                    changes.report.conflicts.append("\(label): \(name(owner)) and \(name(source)) change it in different ways")
                }
                return false
            }
            plannedBy[target] = source
            plannedValues[target] = value
            return true
        }

        static func signature(_ point: HorizontalPoint) -> String {
            "\(Int64(point.x.rounded())),\(Int64(point.y.rounded()))"
        }

        static func signature(_ placement: HorizontalPlacementTransform) -> String {
            signature(placement.shift) + ",\(placement.angle),\(placement.mirrored)"
        }

        static func signature(_ segment: HorizontalSegment, ends: (End, End)) -> String {
            "\(ends.0)|\(ends.1)|\(segment.layer ?? 0)|\(Int64(segment.width.rounded()))|" + (segment.center.map(signature) ?? "")
        }

        private func name(_ path: String) -> String {
            instances.instances[path]?.name ?? path
        }

        private func refdes(_ package: HorizontalPlacement) -> String {
            package.componentDetails?.refdes ?? package.label
        }

        static func samePlacement(_ a: HorizontalPlacementTransform, _ b: HorizontalPlacementTransform, tolerance: Double = 2) -> Bool {
            a.mirrored == b.mirrored && min((a.angle - b.angle + 65_536) % 65_536, (b.angle - a.angle + 65_536) % 65_536) <= 1
                && HorizontalBlockLayoutMatch.distance(a.shift, b.shift) <= tolerance
        }

        /// Where a copied track's end goes: the other instance's counterpart
        /// of the pad or junction it is on, or the point the motion takes it
        /// to. Nil where it is on something the other instance has no
        /// counterpart of.
        private func end(
            of track: HorizontalSegment,
            at keyPath: KeyPath<HorizontalSegment, HorizontalPoint>,
            junction: String?,
            junctionIDs: [String: String],
            packageMap: [String: String],
            motion: HorizontalBoardMotion
        ) -> End? {
            if let junction = junction?.lowercased(), editJunctions[junction] != nil {
                return junctionIDs[junction].map(End.junction)
            }
            let point = track[keyPath: keyPath]
            if let pad = editPadPaths[HorizontalBoard.junctionPointKey(point)] {
                guard let slash = pad.firstIndex(of: "/"), let package = packageMap[String(pad[..<slash])] else { return nil }
                return .pad(package + pad[slash...])
            }
            return .point(motion.point(point).rounded)
        }

        /// Whether `existing`'s ends are on the same kind of thing as `ends`,
        /// the same pads where they are on pads.
        private func sameKind(_ existing: HorizontalSegment, ends: (End, End)) -> Bool {
            func kind(_ point: HorizontalPoint, junction: String?) -> End {
                if let junction { return .junction(junction.lowercased()) }
                if let pad = baseline.packagePadPositions.first(where: { HorizontalBoard.junctionPointKey($0.value) == HorizontalBoard.junctionPointKey(point) })?.key {
                    return .pad(pad.lowercased())
                }
                return .point(point)
            }
            func same(_ a: End, _ b: End) -> Bool {
                switch (a, b) {
                case let (.pad(x), .pad(y)): x == y
                case (.junction, .junction): true
                case (.point, .point): true
                default: false
                }
            }
            return same(kind(existing.from, junction: existing.fromJunctionID), ends.0)
                && same(kind(existing.to, junction: existing.toJunctionID), ends.1)
        }

        /// A track the other instance has already, the same layer and ends
        /// either way round: what pasting next to two instances makes.
        private func existingTrack(matching segment: HorizontalSegment, among tracks: Dictionary<String, HorizontalSegment>.Values) -> HorizontalSegment? {
            tracks.first { other in
                other.layer == segment.layer && (
                    (HorizontalBlockLayoutMatch.distance(other.from, segment.from) <= 2 && HorizontalBlockLayoutMatch.distance(other.to, segment.to) <= 2)
                        || (HorizontalBlockLayoutMatch.distance(other.from, segment.to) <= 2 && HorizontalBlockLayoutMatch.distance(other.to, segment.from) <= 2))
            }
        }

        /// The net `netID` of `source` is in `target`: the same local net's,
        /// a power net itself, nil for one `target` has no counterpart of.
        private func mappedNet(_ netID: String, from source: HorizontalBoardBlockInstances.Instance,
                               to target: HorizontalBoardBlockInstances.Instance) -> String? {
            if let local = instances.localNet(netID, in: source) {
                return instances.flatNet(local, in: target)
            }
            let paths = instances.netPaths[netID.lowercased()] ?? []
            return paths.contains { $0.count == 1 } ? netID : nil
        }
    }

    // MARK: - Copying a layout

    /// Copy Layout to Other Instances: each target laid out as `source` is,
    /// where it is. Its parts go where the motion from the source puts the
    /// source's: the motion between them where they are laid out alike,
    /// else the one that keeps the first part both have placed where it is,
    /// else beside the source. Its own copper gives way to the source's,
    /// copied; copper that isn't its own stays. A fixed part stays, and is
    /// reported. What it makes is a change set as an edit's is.
    static func copyLayout(
        from source: String,
        to targets: [String],
        board: HorizontalBoard,
        instances: HorizontalBoardBlockInstances
    ) -> ChangeSet {
        var changes = ChangeSet()
        let match = HorizontalBlockLayoutMatch(board: board, instances: instances)
        guard let layout = match.layouts[source] else {
            return changes
        }
        let owned = match.owned(source)
        let innerLayers = max(board.copperLayerCount - 2, 0)
        var padPaths = [String: String]()
        for (path, point) in board.packagePadPositions {
            let key = HorizontalBoard.junctionPointKey(point), lowered = path.lowercased()
            if let existing = padPaths[key], existing <= lowered { continue }
            padPaths[key] = lowered
        }
        let junctions = board.junctions.reduce(into: [String: HorizontalPoint]()) { $0[$1.key.lowercased()] = $1.value }
        let extent = layout.extents.values.reduce(nil) { (box: HorizontalBlockLayoutMatch.Box?, next) in box.map { $0.union(next) } ?? next }
        let width = extent.map { $0.maxX - $0.minX } ?? 10_000_000
        var beside = 0
        var changed = [String]()

        for target in targets where target != source {
            guard let targetLayout = match.layouts[target], let targetInstance = instances.instances[target],
                  targetInstance.blockID == layout.instance.blockID else { continue }
            let transform: HorizontalPlacementTransform
            if let pair = match.pair(from: source, to: target) {
                // Laid out alike, or the motion most of its parts agree with:
                // where nothing does, its first part by name stays.
                transform = pair.transform
            } else if let anchor = layout.packages.keys.sorted().first(where: { local in
                guard let theirs = targetLayout.pads[local], let mine = layout.pads[local] else { return false }
                return Set(theirs.keys) == Set(mine.keys)
            }), let from = layout.packages[anchor], let to = targetLayout.packages[anchor] {
                transform = HorizontalBoard.placementTransform(of: to)
                    .accumulated(with: HorizontalBoard.placementTransform(of: from).inverse).rounded
            } else {
                beside += 1
                transform = HorizontalPlacementTransform(
                    shift: HorizontalPoint(x: (width + 5_000_000) * Double(beside), y: 0), angle: 0, mirrored: false)
            }
            let motion = HorizontalBoardMotion(transform, innerLayerCount: innerLayers)

            // Parts.
            var packageMap = [String: String]()
            for (local, package) in layout.packages.sorted(by: { $0.key < $1.key }) {
                let placement = transform.accumulated(with: HorizontalBoard.placementTransform(of: package)).rounded
                if let existing = targetLayout.packages[local] {
                    packageMap[package.id.lowercased()] = existing.id.lowercased()
                    if existing.fixed {
                        changes.report.skipped.append("\(existing.componentDetails?.refdes ?? existing.label) in \(targetInstance.name) is fixed")
                        continue
                    }
                    changes.placements[existing.id.lowercased()] = placement
                    if existing.omitSilkscreen != package.omitSilkscreen || existing.omitOutline != package.omitOutline {
                        changes.flags[existing.id.lowercased()] = Flags(fixed: false, omitSilkscreen: package.omitSilkscreen, omitOutline: package.omitOutline)
                    }
                } else if let componentID = targetInstance.members[local] {
                    let id = copyID(of: package.id, in: target)
                    changes.placed.append(Placement(componentID: componentID, placement: placement,
                                                    sourcePackageID: package.id.lowercased(), packageID: id))
                    packageMap[package.id.lowercased()] = id
                }
            }

            // Copper: the source's, copied, where the target's own was.
            var junctionIDs = [String: String]()
            for id in owned.junctions.sorted() {
                guard let point = junctions[id] else { continue }
                let copy = copyID(of: id, in: target)
                junctionIDs[id] = copy
                changes.junctions[copy] = motion.point(point).rounded
            }
            var planned = Set<String>()
            for track in board.tracks.sorted(by: { $0.id < $1.id }) where owned.tracks.contains(track.id.lowercased()) {
                func end(_ point: HorizontalPoint, junction: String?) -> End? {
                    if let junction = junction?.lowercased(), junctions[junction] != nil {
                        return junctionIDs[junction].map(End.junction)
                    }
                    if let pad = padPaths[HorizontalBoard.junctionPointKey(point)] {
                        guard let slash = pad.firstIndex(of: "/"), let package = packageMap[String(pad[..<slash])] else { return nil }
                        return .pad(package + pad[slash...])
                    }
                    return .point(motion.point(point).rounded)
                }
                guard var from = end(track.from, junction: track.fromJunctionID),
                      var to = end(track.to, junction: track.toJunctionID) else { continue }
                var segment = motion.segment(track)
                segment.reverse = false
                if motion.mirrors {
                    swap(&segment.from, &segment.to)
                    swap(&from, &to)
                }
                let id = copyID(of: track.id, in: target)
                segment.id = id
                segment.fromJunctionID = from.junctionID
                segment.toJunctionID = to.junctionID
                segment.locked = false
                changes.tracks[id] = Track(segment: segment, from: from, to: to)
                planned.insert(id)
            }
            for via in board.vias.sorted(by: { $0.id < $1.id }) where owned.vias.contains(via.id.lowercased()) {
                var copy = via
                copy.id = copyID(of: via.id, in: target)
                copy.position = motion.point(via.position).rounded
                let layers = via.copperLayers.map(motion.layer).sorted()
                copy.connectedLayers = via.connectedLayers.isEmpty ? [] : layers
                if let top = layers.max(), let bottom = layers.min() {
                    let span = HorizontalViaSpan(start: top, end: bottom)
                    copy.span = span.isThrough && via.span == nil ? nil : span
                }
                copy.netSetID = via.netSetID.flatMap { net in
                    if let local = instances.localNet(net, in: layout.instance) {
                        return instances.flatNet(local, in: targetInstance)
                    }
                    return (instances.netPaths[net.lowercased()] ?? []).contains { $0.count == 1 } ? net : nil
                }
                copy.netID = copy.netSetID
                copy.locked = false
                changes.vias[copy.id] = copy
                planned.insert(copy.id)
            }
            let theirs = match.owned(target)
            changes.removedTracks.formUnion(theirs.tracks.subtracting(planned))
            changes.removedVias.formUnion(theirs.vias.subtracting(planned))
            changed.append(targetInstance.name)
        }
        changes.report.changed = changed
        return changes
    }

    // MARK: - Making it

    /// The change set made on `board`: parts moved, placed (from the pool at
    /// `poolURL`) and taken off, then copper, the ends of tracks the parts'
    /// pads move dragged with them. Nothing is merged or re-derived: the
    /// caller's connectivity pass gives the copper its nets.
    static func apply(_ changes: ChangeSet, to board: inout HorizontalBoard, poolURL: URL?) -> Report {
        var report = changes.report

        // Parts taken off.
        if !changes.unplaced.isEmpty {
            board.removePackages(changes.unplaced)
        }
        // Parts placed: from the pool, then turned where the edit put them.
        var placements = changes.placements
        for placement in changes.placed {
            guard let poolURL,
                  let object = (board.placeableObjects + board.unplacedObjects).first(where: { $0.componentID?.lowercased() == placement.componentID }),
                  let draft = HorizontalBoard.placingPackage(for: object, in: board, at: placement.placement.shift, poolURL: poolURL) else {
                report.skipped.append("a part it couldn't place from the pool")
                continue
            }
            board = draft.board
            if let index = board.packages.firstIndex(where: { $0.id == draft.placementID }) {
                // The id the change set gave it, so a dry run's is the commit's.
                let newID = placement.packageID
                board.renamePackage(draft.placementID, to: newID)
                if board.packages.indices.contains(index) {
                    placements[newID] = placement.placement
                }
            }
        }
        // Parts moved, and what is on their pads following.
        let padMoves = board.replacePackages(placements)
        for (id, text) in changes.texts {
            guard let index = board.packageTexts.firstIndex(where: { $0.id.lowercased() == id }) else { continue }
            board.packageTexts[index].position = text.position
            board.packageTexts[index].angle = text.angle
            board.packageTexts[index].mirrored = text.mirrored
            board.packageTexts[index].layer = text.layer
        }
        for (id, flags) in changes.flags {
            guard let index = board.packages.firstIndex(where: { $0.id.lowercased() == id }) else { continue }
            board.packages[index].fixed = flags.fixed
            board.packages[index].omitSilkscreen = flags.omitSilkscreen
            board.packages[index].omitOutline = flags.omitOutline
        }
        if !padMoves.isEmpty {
            let moves = padMoves.values.reduce(into: [String: HorizontalPoint]()) {
                $0[HorizontalBoard.junctionPointKey($1.from)] = $1.to
            }
            for index in board.tracks.indices where changes.tracks[board.tracks[index].id.lowercased()] == nil {
                if board.tracks[index].fromJunctionID == nil, let to = moves[HorizontalBoard.junctionPointKey(board.tracks[index].from)] {
                    board.tracks[index].from = to
                }
                if board.tracks[index].toJunctionID == nil, let to = moves[HorizontalBoard.junctionPointKey(board.tracks[index].to)] {
                    board.tracks[index].to = to
                }
            }
        }

        // Copper.
        var junctionKeys = board.junctions.keys.reduce(into: [String: String]()) { $0[$1.lowercased()] = $1 }
        for (id, point) in changes.junctions {
            let key = junctionKeys[id] ?? id
            junctionKeys[id] = key
            board.junctions[key] = point
        }
        if !changes.junctions.isEmpty {
            // What ends on a junction that moved goes with it.
            for index in board.tracks.indices {
                if let id = board.tracks[index].fromJunctionID?.lowercased(), let point = changes.junctions[id] { board.tracks[index].from = point }
                if let id = board.tracks[index].toJunctionID?.lowercased(), let point = changes.junctions[id] { board.tracks[index].to = point }
            }
        }
        if !changes.removedTracks.isEmpty {
            board.tracks.removeAll { changes.removedTracks.contains($0.id.lowercased()) && changes.tracks[$0.id.lowercased()] == nil }
        }
        func position(_ end: End) -> HorizontalPoint? {
            switch end {
            case .pad(let path):
                board.packagePadPositions.first { $0.key.lowercased() == path }?.value
            case .junction(let id):
                junctionKeys[id].flatMap { board.junctions[$0] }
            case .point(let point):
                point
            }
        }
        let trackIndex = board.tracks.indices.reduce(into: [String: Int]()) { $0[board.tracks[$1].id.lowercased()] = $1 }
        for (id, track) in changes.tracks.sorted(by: { $0.key < $1.key }) {
            guard let from = position(track.from), let to = position(track.to) else {
                report.skipped.append("a track whose end it couldn't find")
                continue
            }
            var segment = track.segment
            segment.from = from
            segment.to = to
            segment.fromJunctionID = track.from.junctionID.flatMap { junctionKeys[$0] }
            segment.toJunctionID = track.to.junctionID.flatMap { junctionKeys[$0] }
            if let index = trackIndex[id] {
                segment.id = board.tracks[index].id
                board.tracks[index] = segment
            } else {
                board.tracks.append(segment)
            }
        }
        if !changes.removedVias.isEmpty {
            board.vias.removeAll { changes.removedVias.contains($0.id.lowercased()) }
            board.viaHoles.removeAll { hole in changes.removedVias.contains { hole.id.lowercased().hasPrefix($0 + "/") } }
            board.removedViaIDs.formUnion(changes.removedVias)
        }
        for (id, via) in changes.vias.sorted(by: { $0.key < $1.key }) {
            if let index = board.vias.firstIndex(where: { $0.id.lowercased() == id }) {
                var updated = via
                updated.id = board.vias[index].id
                let moved = board.vias[index].position != updated.position
                board.vias[index] = updated
                if moved {
                    for hole in board.viaHoles.indices where board.viaHoles[hole].id.lowercased() == id + "/hole" {
                        board.viaHoles[hole].position = updated.position
                    }
                }
            } else {
                board.vias.append(via)
                if let size = via.holeSize {
                    board.viaHoles.append(HorizontalHole(id: via.id + "/hole", position: via.position, diameter: size, plated: true))
                }
            }
        }
        return report
    }
}

extension HorizontalBlockLayoutSync.End {
    var junctionID: String? {
        if case .junction(let id) = self { return id }
        return nil
    }
}

extension HorizontalBoard {
    /// Packages taken off the board with everything they draw: their
    /// components go back among the unplaced.
    mutating func removePackages(_ ids: Set<String>) {
        let wanted = Set(ids.map { $0.lowercased() })
        guard !wanted.isEmpty else { return }
        func belongs(_ geometryID: String) -> Bool {
            BoardMovePlanner.packageID(forGeometryID: geometryID).map(wanted.contains) ?? false
        }
        packages.removeAll { wanted.contains($0.id.lowercased()) }
        packagePads.removeAll { belongs($0.id) }
        packageHoles.removeAll { belongs($0.id) }
        packagePolygons.removeAll { belongs($0.id) }
        packageLines.removeAll { belongs($0.id) }
        packageArcs.removeAll { belongs($0.id) }
        packageTexts.removeAll { belongs($0.id) }
        keepouts.removeAll { belongs($0.id) }
        packagePadPositions = packagePadPositions.filter { path, _ in
            guard let slash = path.firstIndex(of: "/") else { return true }
            return !wanted.contains(path[..<slash].lowercased())
        }
        if !placeableObjects.isEmpty {
            replacePlaceableObjects(placeableObjects)
        }
    }

    /// A package and everything it draws under another id.
    mutating func renamePackage(_ id: String, to newID: String) {
        let old = id.lowercased()
        func renamed(_ geometryID: String) -> String {
            guard BoardMovePlanner.packageID(forGeometryID: geometryID) == old,
                  let slash = geometryID.firstIndex(of: "/") else { return geometryID }
            return newID + geometryID[slash...]
        }
        for index in packages.indices where packages[index].id.lowercased() == old {
            packages[index].id = newID
        }
        for index in packagePads.indices { packagePads[index].id = renamed(packagePads[index].id) }
        for index in packageHoles.indices { packageHoles[index].id = renamed(packageHoles[index].id) }
        for index in packagePolygons.indices { packagePolygons[index].id = renamed(packagePolygons[index].id) }
        for index in packageLines.indices { packageLines[index].id = renamed(packageLines[index].id) }
        for index in packageArcs.indices { packageArcs[index].id = renamed(packageArcs[index].id) }
        for index in packageTexts.indices { packageTexts[index].id = renamed(packageTexts[index].id) }
        for index in keepouts.indices { keepouts[index].id = renamed(keepouts[index].id) }
        var positions = [String: HorizontalPoint]()
        for (path, point) in packagePadPositions {
            if let slash = path.firstIndex(of: "/"), path[..<slash].lowercased() == old {
                positions[newID + path[slash...]] = point
            } else {
                positions[path] = point
            }
        }
        packagePadPositions = positions
    }
}
