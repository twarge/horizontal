import Foundation

extension HorizontalClearanceFinding {
    /// How many of the pairs a finding stands for its `detail` names.
    static let alsoListed = 3

    /// The pair itself and the pairs it stands for, each as the check
    /// measured it, with no `also` of its own.
    var pairs: [HorizontalClearanceFinding] {
        guard !also.isEmpty else { return [self] }
        var own = self
        own.also = []
        return [own] + also
    }

    /// What the canvas strokes for the finding: its own `violation` and that
    /// of every pair it stands for.
    var highlights: [[HorizontalPoint]] {
        also.isEmpty ? violation : violation + also.flatMap(\.violation)
    }

    /// What `detail` says of the pairs the finding stands for, the first few
    /// by name: each by the side of it the finding's title doesn't name, or
    /// by both where neither is the title's, and how far apart.
    /// "Also too close there: Track (GND), 0.096 mm apart."
    var alsoDetail: String {
        guard !also.isEmpty else { return "" }
        var listed = also.prefix(Self.alsoListed).map { pair -> String in
            let name: String
            if pair.first.id == first.id, pair.first.type == first.type {
                name = pair.second.name
            } else if pair.second.id == second.id, pair.second.type == second.type {
                name = pair.first.name
            } else {
                name = "\(pair.first.name) and \(pair.second.name)"
            }
            let apart = pair.apart
            return "\(name), \(apart.prefix(1).lowercased())\(apart.dropFirst())"
        }
        if also.count > listed.count {
            listed.append("and \(also.count - listed.count) more")
        }
        return "Also too close there: \(listed.joined(separator: "; "))."
    }
}

extension HorizontalBoardClearanceCheck {
    /// How near each other two findings alike must run to be one problem, in
    /// nanometres: a quarter of a millimetre, or the clearance they ask where
    /// that is more. Nothing a rule would tell apart fits in so little.
    static let mergeDistance = 250_000.0

    /// `findings` with the pairs that are one problem folded into the worst
    /// of them, which lists the others in its `also`; in the order they came,
    /// less those folded away.
    ///
    /// The check finds a pair of objects at a time, so one thing too close
    /// to copper made of several — a text beside a track where it runs into
    /// its net's plane, a track passing a pad and the track that ends on it,
    /// two segments of a track turning a corner by a via — is a finding for
    /// each, a few microns apart in what they say. Two findings are one
    /// problem when they are the same check under the same rule on the same
    /// layers, each side of one is the other's (the same net's copper, or,
    /// for what has no net, a thing of the same kind and label), and the
    /// stretches of them that are too close (`violation`) run within
    /// `mergeDistance` of each other. Findings joined that way in a chain
    /// are one, as far as the chain runs.
    static func merged(_ findings: [HorizontalClearanceFinding]) -> [HorizontalClearanceFinding] {
        let pairs = findings.flatMap(\.pairs)
        guard pairs.count > 1 else { return pairs }
        let extents = pairs.map(Extent.init)

        var parent = Array(pairs.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        var alike = [Kind: [Int]]()
        for index in pairs.indices {
            alike[Kind(pairs[index]), default: []].append(index)
        }
        for group in alike.values where group.count > 1 {
            // Left to right, so each is measured against those that start
            // before it ends and no others.
            let ordered = group.sorted { extents[$0].box.minX < extents[$1].box.minX }
            let furthest = max(mergeDistance, group.map { pairs[$0].clearance }.max() ?? 0)
            for (position, i) in ordered.enumerated() {
                for j in ordered.dropFirst(position + 1) {
                    guard extents[j].box.minX - extents[i].box.maxX < furthest else { break }
                    let reach = max(mergeDistance, pairs[i].clearance, pairs[j].clearance)
                    let a = root(i), b = root(j)
                    if a != b, extents[i].runs(within: reach, of: extents[j]) {
                        parent[max(a, b)] = min(a, b)
                    }
                }
            }
        }

        var problems = [Int: [Int]]()
        for index in pairs.indices {
            problems[root(index), default: []].append(index)
        }
        // The worst of each stands for it; of two as bad, the one that came first.
        return problems.values.map { members -> (index: Int, finding: HorizontalClearanceFinding) in
            let worstFirst = members.sorted { lhs, rhs in
                pairs[lhs].shortfall != pairs[rhs].shortfall ? pairs[lhs].shortfall > pairs[rhs].shortfall : lhs < rhs
            }
            var finding = pairs[worstFirst[0]]
            finding.also = worstFirst.dropFirst().map { pairs[$0] }
            return (worstFirst[0], finding)
        }.sorted { $0.index < $1.index }.map(\.finding)
    }

    /// What two findings must share to be alike: the check, the rule, the
    /// layers, and what is on each side, whichever way round.
    private struct Kind: Hashable {
        var check: HorizontalClearanceFinding.Check
        var ruleID: String?
        var layers: [Int]
        var sides: [String]

        init(_ finding: HorizontalClearanceFinding) {
            check = finding.check
            ruleID = finding.ruleID
            layers = finding.layers
            sides = [Self.side(finding.first), Self.side(finding.second)].sorted()
        }

        /// Copper on a net is its net, whatever it is — a track, the pad it
        /// ends on and the plane round both are one piece of copper to
        /// whatever is too close to them. Anything else is its kind and its
        /// label, which names the package a line, a text or a hole belongs
        /// to: two lines of one package's outline are alike, and its text is
        /// neither.
        static func side(_ object: HorizontalClearanceFinding.Object) -> String {
            if let net = object.netID {
                return "net|\(net)"
            }
            return "\(object.type.jsonString)|\(object.label)"
        }
    }

    /// Where a finding is, for telling how near another runs: the stretches
    /// of it that are too close, and the line between its nearest points.
    private struct Extent {
        var segments: [(HorizontalPoint, HorizontalPoint)]
        var box: HorizontalRect

        init(_ finding: HorizontalClearanceFinding) {
            segments = [(finding.firstPoint, finding.secondPoint)]
            for line in finding.violation {
                if line.count == 1 {
                    segments.append((line[0], line[0]))
                } else {
                    segments.append(contentsOf: zip(line, line.dropFirst()))
                }
            }
            box = HorizontalRect(points: segments.flatMap { [$0.0, $0.1] })
        }

        /// How far the box of segment `ab` is from `box`; nothing where they
        /// overlap.
        static func gap(_ a: HorizontalPoint, _ b: HorizontalPoint, to box: HorizontalRect) -> Double {
            let dx = max(0, box.minX - max(a.x, b.x), min(a.x, b.x) - box.maxX)
            let dy = max(0, box.minY - max(a.y, b.y), min(a.y, b.y) - box.maxY)
            return dx == 0 ? dy : dy == 0 ? dx : (dx * dx + dy * dy).squareRoot()
        }

        /// Whether any of this runs closer than `reach` to any of `other`.
        func runs(within reach: Double, of other: Extent) -> Bool {
            let theirs = other.segments.filter { Self.gap($0.0, $0.1, to: box) < reach }
            guard !theirs.isEmpty else { return false }
            for (a, b) in segments where Self.gap(a, b, to: other.box) < reach {
                for (c, d) in theirs where HorizontalRouteClearanceProbe.segmentDistance(a, b, c, d) < reach {
                    return true
                }
            }
            return false
        }
    }
}
