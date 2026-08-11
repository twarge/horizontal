#include "HorizontalPlaneClipper.h"

#include "../../Vendor/Clipper/clipper.hpp"
#include "../../Vendor/earcut/earcut.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <exception>
#include <vector>

// Adapter so mapbox::earcut can read coords directly from HorizontalClipperPoint
// (a plain struct with .x/.y) without a copy step.
namespace mapbox { namespace util {
template <>
struct nth<0, HorizontalClipperPoint> {
    inline static double get(const HorizontalClipperPoint& p) { return p.x; }
};
template <>
struct nth<1, HorizontalClipperPoint> {
    inline static double get(const HorizontalClipperPoint& p) { return p.y; }
};
}} // namespace mapbox::util

namespace {

ClipperLib::cInt to_int(double value)
{
    return static_cast<ClipperLib::cInt>(std::llround(value));
}

HorizontalClipperPoint to_point(const ClipperLib::IntPoint &point)
{
    return HorizontalClipperPoint {
        static_cast<double>(point.X),
        static_cast<double>(point.Y)
    };
}

ClipperLib::Path to_path(const HorizontalClipperPath &path)
{
    ClipperLib::Path result;
    if (!path.points || path.count < 3) {
        return result;
    }

    result.reserve(static_cast<size_t>(path.count));
    for (int index = 0; index < path.count; index++) {
        result.emplace_back(to_int(path.points[index].x), to_int(path.points[index].y));
    }
    return result;
}

ClipperLib::Paths to_paths(const HorizontalClipperPath *paths, int count)
{
    ClipperLib::Paths result;
    if (!paths || count <= 0) {
        return result;
    }

    result.reserve(static_cast<size_t>(count));
    for (int index = 0; index < count; index++) {
        auto path = to_path(paths[index]);
        if (path.size() >= 3) {
            result.push_back(std::move(path));
        }
    }
    return result;
}

ClipperLib::JoinType join_type_from_int(int value)
{
    switch (value) {
    case 1:
        return ClipperLib::jtSquare;
    case 2:
        return ClipperLib::jtMiter;
    case 0:
    default:
        return ClipperLib::jtRound;
    }
}

ClipperLib::Paths offset_paths(const ClipperLib::Paths &paths, double delta, ClipperLib::JoinType jt = ClipperLib::jtRound,
                               double arcTolerance = 2000)
{
    if (paths.empty()) {
        return {};
    }
    // Always run Execute (even for delta == 0) so Clipper normalizes winding and
    // cleans the polygons, exactly as the reference does for the min_width == 0
    // shrink/expand. The previous |delta| < 0.5 short-circuit returned raw input,
    // skipping that cleanup.
    ClipperLib::ClipperOffset offset;
    offset.ArcTolerance = arcTolerance;
    offset.AddPaths(paths, jt, ClipperLib::etClosedPolygon);
    ClipperLib::Paths result;
    offset.Execute(result, delta);
    return result;
}

// Mirrors Placement::transform: rotate FIRST
// by the Horizon integer angle (65536 == full turn, with exact cardinal
// branches), THEN negate x if mirrored, THEN translate.
struct PlanePlacement {
    double x = 0;
    double y = 0;
    int angle = 0;
    bool mirror = false;

    ClipperLib::IntPoint transform(const ClipperLib::IntPoint &p) const
    {
        const double cx = static_cast<double>(p.X);
        const double cy = static_cast<double>(p.Y);
        double rx, ry;
        const int a = ((angle % 65536) + 65536) % 65536;
        switch (a) {
        case 0:
            rx = cx;
            ry = cy;
            break;
        case 16384:
            rx = -cy;
            ry = cx;
            break;
        case 32768:
            rx = -cx;
            ry = -cy;
            break;
        case 49152:
            rx = cy;
            ry = -cx;
            break;
        default: {
            const double af = static_cast<double>(a) / 65536.0 * 2.0 * M_PI;
            rx = cx * std::cos(af) - cy * std::sin(af);
            ry = cx * std::sin(af) + cy * std::cos(af);
            break;
        }
        }
        if (mirror) {
            rx = -rx;
        }
        return ClipperLib::IntPoint(std::llround(rx + x), std::llround(ry + y));
    }
};

void transform_path(ClipperLib::Path &path, const PlanePlacement &tr)
{
    for (auto &pt : path) {
        pt = tr.transform(pt);
    }
}

std::pair<ClipperLib::IntPoint, ClipperLib::IntPoint> paths_bbox(const ClipperLib::Paths &paths)
{
    ClipperLib::IntPoint lo(0, 0), hi(0, 0);
    bool first = true;
    for (const auto &path : paths) {
        for (const auto &pt : path) {
            if (first) {
                lo = hi = pt;
                first = false;
            }
            else {
                lo.X = std::min(lo.X, pt.X);
                lo.Y = std::min(lo.Y, pt.Y);
                hi.X = std::max(hi.X, pt.X);
                hi.Y = std::max(hi.Y, pt.Y);
            }
        }
    }
    return {lo, hi};
}

HorizontalClipperPath copy_path(const ClipperLib::Path &path)
{
    HorizontalClipperPath result {};
    result.count = static_cast<int>(path.size());
    if (result.count == 0) {
        return result;
    }

    result.points = static_cast<HorizontalClipperPoint *>(std::calloc(static_cast<size_t>(result.count), sizeof(HorizontalClipperPoint)));
    if (!result.points) {
        result.count = 0;
        return result;
    }

    for (int index = 0; index < result.count; index++) {
        result.points[index] = to_point(path[static_cast<size_t>(index)]);
    }
    return result;
}

bool same_point(const HorizontalClipperPoint &lhs, const HorizontalClipperPoint &rhs)
{
    return std::abs(lhs.x - rhs.x) < 0.000001 && std::abs(lhs.y - rhs.y) < 0.000001;
}

std::vector<HorizontalClipperPoint> clean_path(const HorizontalClipperPath &path)
{
    std::vector<HorizontalClipperPoint> result;
    if (!path.points || path.count < 3) {
        return result;
    }

    result.reserve(static_cast<size_t>(path.count));
    for (int index = 0; index < path.count; index++) {
        const auto point = path.points[index];
        if (!result.empty() && same_point(result.back(), point)) {
            continue;
        }
        result.push_back(point);
    }
    if (result.size() > 1 && same_point(result.front(), result.back())) {
        result.pop_back();
    }
    if (result.size() < 3) {
        result.clear();
    }
    return result;
}

void append_fragment(const ClipperLib::PolyNode *node, std::vector<HorizontalClipperFragment> &fragments)
{
    if (!node || node->IsHole() || node->Contour.size() < 3) {
        return;
    }

    std::vector<ClipperLib::Path> paths;
    paths.push_back(node->Contour);
    for (const auto *child : node->Childs) {
        if (child && child->IsHole() && child->Contour.size() >= 3) {
            paths.push_back(child->Contour);
            for (const auto *island : child->Childs) {
                append_fragment(island, fragments);
            }
        }
    }

    HorizontalClipperFragment fragment {};
    fragment.count = static_cast<int>(paths.size());
    fragment.paths = static_cast<HorizontalClipperPath *>(std::calloc(static_cast<size_t>(fragment.count), sizeof(HorizontalClipperPath)));
    if (!fragment.paths) {
        fragment.count = 0;
        return;
    }

    for (int index = 0; index < fragment.count; index++) {
        fragment.paths[index] = copy_path(paths[static_cast<size_t>(index)]);
    }
    fragments.push_back(fragment);
}

HorizontalClipperFragmentList fragments_from_tree(const ClipperLib::PolyTree &tree)
{
    std::vector<HorizontalClipperFragment> fragments;
    for (const auto *node : tree.Childs) {
        append_fragment(node, fragments);
    }

    HorizontalClipperFragmentList result {};
    if (fragments.empty()) {
        return result;
    }

    result.count = static_cast<int>(fragments.size());
    result.fragments = static_cast<HorizontalClipperFragment *>(
            std::calloc(static_cast<size_t>(result.count), sizeof(HorizontalClipperFragment)));
    if (!result.fragments) {
        for (auto &fragment : fragments) {
            for (int pathIndex = 0; pathIndex < fragment.count; pathIndex++) {
                std::free(fragment.paths[pathIndex].points);
            }
            std::free(fragment.paths);
        }
        result.count = 0;
        return result;
    }

    for (int index = 0; index < result.count; index++) {
        result.fragments[index] = fragments[static_cast<size_t>(index)];
    }
    return result;
}

// Candidate thermal spokes for one pad.
//
// A thermally-relieved pad keeps a ring of clearance from the pour — the antipad
// cut in (4a) — so that soldering it does not sink its heat into the whole
// plane. The spokes are the narrow bridges across that ring: without them the
// pad would be isolated, with them it stays connected but thermally throttled.
//
// Requirements, and where each dimension comes from:
//
//  • A spoke must REACH the pour, or it bridges nothing. The antipad is cut at
//    `gapWidth + minWidth/2` from the pad, so a spoke has to extend at least
//    that far; it goes 0.01 mm further so it overlaps the copper rather than
//    merely touching it, which a boolean union may drop.
//  • A spoke must END UP `spokeWidth` wide. The pour is dilated by minWidth/2
//    per side in (5), which widens every edge by minWidth in total, so the spoke
//    is built that much narrower. It is floored at 0.01 mm so a spoke narrower
//    than the minimum copper width degenerates to a sliver rather than to
//    nothing.
//  • A spoke must be long enough to cross the ring from wherever it starts.
//    Its length is therefore not a meaningful dimension — it is the expanded
//    pad's longest side, and the clip to that expanded outline is what gives
//    each spoke its real extent.
//  • Spokes are spread evenly around a full turn (65536 units) from
//    `spokeAngle`, then carried into the pad's own frame, so a rotated or
//    mirrored pad keeps its spokes where its footprint expects them.
//
// The caller decides which of these candidates survive: a spoke that reaches no
// copper is dropped.
void build_thermal_spokes(const HorizontalClipperThermalPad &pad, double minWidth, ClipperLib::Paths &spokesOut)
{
    ClipperLib::Paths padPaths;
    {
        ClipperLib::Path p = to_path(pad.path);
        if (p.size() >= 3) {
            padPaths.push_back(std::move(p));
        }
    }
    if (padPaths.empty()) {
        return;
    }

    ClipperLib::Paths uni;
    ClipperLib::SimplifyPolygons(padPaths, uni, ClipperLib::pftNonZero);
    if (uni.empty()) {
        return;
    }

    // The antipad's own offset (see (4a)) plus 0.01 mm of overlap. Mitred, so a
    // rectangular pad's expansion keeps its corners and the spoke crosses the
    // ring at full width there too.
    const double expand = pad.gapWidth + 10000.0 + minWidth / 2.0;
    auto pad_exp = offset_paths(uni, expand, ClipperLib::jtMiter, 2000);
    if (pad_exp.empty()) {
        return;
    }

    // Long enough to cross the ring from the pad's centre in any direction; the
    // clip below is what sets each spoke's real length.
    auto bb = paths_bbox(pad_exp);
    const int64_t w = bb.second.X - bb.first.X;
    const int64_t h = bb.second.Y - bb.first.Y;
    const int64_t l = std::max(w, h);

    // Pre-shrunk by minWidth so the dilate in (5) brings it back to spokeWidth.
    const int64_t spoke_width =
            std::max(static_cast<int64_t>(10000), static_cast<int64_t>(pad.spokeWidth) - static_cast<int64_t>(minWidth));
    ClipperLib::Path base;
    base.emplace_back(-spoke_width / 2, -spoke_width / 2);
    base.emplace_back(-spoke_width / 2, spoke_width / 2);
    base.emplace_back(l + static_cast<int64_t>(minWidth), spoke_width / 2);
    base.emplace_back(l + static_cast<int64_t>(minWidth), -spoke_width / 2);

    const int nSpokes = std::max(0, pad.nSpokes);
    PlanePlacement padPlacement;
    padPlacement.x = pad.placementX;
    padPlacement.y = pad.placementY;
    padPlacement.angle = pad.placementAngle;
    padPlacement.mirror = pad.placementMirror != 0;

    for (int i = 0; i < nSpokes; i++) {
        ClipperLib::Path spoke = base;
        PlanePlacement spin;
        // Evenly around a full turn from spokeAngle: the i-th of n spokes.
        spin.angle = static_cast<int>((65536LL * i) / std::max(1, nSpokes)) + pad.spokeAngle;
        transform_path(spoke, spin);
        transform_path(spoke, padPlacement);

        // Trim the over-long bar to the expanded pad, which is what turns it
        // into a bridge of exactly the reach required above.
        ClipperLib::Clipper cl;
        cl.AddPaths(pad_exp, ClipperLib::ptSubject, true);
        cl.AddPath(spoke, ClipperLib::ptClip, true);
        ClipperLib::Paths clipped;
        cl.Execute(ClipperLib::ctIntersection, clipped, ClipperLib::pftNonZero);
        spokesOut.insert(spokesOut.end(), clipped.begin(), clipped.end());
    }
}

} // namespace

HorizontalClipperFragmentList HorizontalClipperBuildPlaneFill(
    const HorizontalClipperPath *subjects,
    int subjectCount,
    const HorizontalClipperPath *cutouts,
    int cutoutCount,
    double subjectInset,
    double cutoutOutset,
    double finalOutset
)
{
    HorizontalClipperFragmentList empty {};

    auto subjectPaths = offset_paths(to_paths(subjects, subjectCount), -std::max(0.0, subjectInset));
    if (subjectPaths.empty()) {
        return empty;
    }
    auto cutoutPaths = offset_paths(to_paths(cutouts, cutoutCount), std::max(0.0, cutoutOutset));

    ClipperLib::Paths filled;
    {
        ClipperLib::Clipper clipper;
        clipper.AddPaths(subjectPaths, ClipperLib::ptSubject, true);
        if (!cutoutPaths.empty()) {
            clipper.AddPaths(cutoutPaths, ClipperLib::ptClip, true);
        }
        clipper.Execute(ClipperLib::ctDifference, filled, ClipperLib::pftNonZero, ClipperLib::pftNonZero);
    }
    if (filled.empty()) {
        return empty;
    }

    ClipperLib::PolyTree tree;
    {
        auto finalPaths = offset_paths(filled, std::max(0.0, finalOutset));
        if (finalPaths.empty()) {
            return empty;
        }
        ClipperLib::Clipper clipper;
        clipper.AddPaths(finalPaths, ClipperLib::ptSubject, true);
        clipper.Execute(ClipperLib::ctUnion, tree, ClipperLib::pftNonZero);
    }

    return fragments_from_tree(tree);
}

// Why the stages run in this order.
//
// Most of it is forced, and the forcing is worth stating because it is what
// makes the pipeline reproducible rather than conventional:
//
//  • (1) erode and (5) dilate BRACKET everything else. They are a morphological
//    opening — copper too thin to fabricate vanishes and does not return — but
//    they also set the scale every intermediate step is calibrated to. A
//    cutout is outset by `clearance + minWidth/2` and a thermal spoke is built
//    `minWidth` narrow precisely so that the dilate lands them at their true
//    dimensions. Applying either outside the pair gives copper the wrong size.
//  • (4a) antipad rings before (4b) spokes: a spoke is a bridge across the ring,
//    so the ring has to exist before there is anything to bridge. 4b also tests
//    each spoke against the plane as 4a left it.
//  • (4) thermal relief before (5) dilate, for the calibration reason above.
//  • (6) hatching after (5) dilate. Hatching intersects the fill with a grid of
//    lines; dilating afterwards would fatten each line by minWidth/2 a side and
//    close the gaps that make it a hatch.
//
// One ordering is NOT forced, and is a free choice rather than a requirement:
// (2) subtracting cutouts and (3) clipping to the contracted board outline
// COMMUTE. Both are set operations whose other operand — the union of outset
// cutouts, the contracted outline — is computed independently of the plane's
// intermediate shape, so `(S \ C) n B` and `(S n B) \ C` are the same region.
// Either order is correct; this one is kept because it is the one under test.
HorizontalClipperFragmentList HorizontalClipperBuildPlaneFillEx(const HorizontalClipperPlaneFillParams *params)
{
    HorizontalClipperFragmentList empty {};
    if (!params) {
        return empty;
    }

    const ClipperLib::JoinType jt = join_type_from_int(params->joinType);
    const double mw = std::max(0.0, params->minWidth);

    auto subjectPaths = to_paths(params->subjects, params->subjectCount);
    if (subjectPaths.empty()) {
        return empty;
    }
    auto poly_bb = paths_bbox(subjectPaths);

    // (1) Erode the plane outline by half the minimum copper width.
    //
    // This and the matching dilate in (5) form a morphological OPENING: any
    // neck or sliver thinner than min_width vanishes when eroded and does not
    // come back when dilated. That is the point of the pair — a pour must not
    // emit copper too thin to fabricate.
    ClipperLib::Paths out;
    {
        ClipperLib::Clipper cl_plane;
        auto poly_shrink = offset_paths(subjectPaths, -(mw / 2.0), jt, 2000);
        if (poly_shrink.empty()) {
            return empty;
        }
        cl_plane.AddPaths(poly_shrink, ClipperLib::ptSubject, true);

        // (2) Subtract every cutout. Each arrives pre-resolved (already carries its own
        // outset/join/arc-tolerance computed in Swift from the rules engine).
        for (int i = 0; i < params->cutoutCount; i++) {
            const auto &cutout = params->cutouts[i];
            ClipperLib::Path path = to_path(cutout.path);
            if (path.size() < 3) {
                continue;
            }
            ClipperLib::Paths single { path };
            auto expanded = offset_paths(single, std::max(0.0, cutout.outset),
                                         join_type_from_int(cutout.joinType), cutout.arcTolerance);
            if (!expanded.empty()) {
                cl_plane.AddPaths(expanded, ClipperLib::ptClip, true);
            }
        }

        cl_plane.Execute(ClipperLib::ctDifference, out, ClipperLib::pftNonZero, ClipperLib::pftNonZero);
    }
    if (out.empty()) {
        return empty;
    }

    // (3) Clip to the board: contract the outline by its own clearance and
    // intersect, so copper never reaches the board edge.
    if (params->hasBoardOutline) {
        auto outlinePaths = to_paths(params->boardOutline, params->boardOutlineCount);
        if (!outlinePaths.empty()) {
            ClipperLib::Paths board_outline;
            {
                ClipperLib::Clipper cl_outline;
                cl_outline.AddPaths(outlinePaths, ClipperLib::ptSubject, true);
                cl_outline.Execute(ClipperLib::ctUnion, board_outline, ClipperLib::pftEvenOdd);
            }
            auto contracted = offset_paths(board_outline, -std::max(0.0, params->boardOutlineContract), jt, 10000);
            ClipperLib::Paths temp;
            {
                ClipperLib::Clipper isect;
                isect.AddPaths(contracted, ClipperLib::ptClip, true);
                isect.AddPaths(out, ClipperLib::ptSubject, true);
                isect.Execute(ClipperLib::ctIntersection, temp, ClipperLib::pftNonZero);
            }
            out = temp;
        }
    }
    if (out.empty()) {
        return empty;
    }

    // (4) Thermal relief. Pads that need to stay solderable get a ring of
    // clearance with narrow spokes bridging it, rather than a solid connection
    // that would sink all the heat into the pour.
    ClipperLib::Paths plane_with_thermal_cutouts = out;
    bool hasThermalGeometry = false;
    {
        // (4a) Cut the antipad ring for both thermally-relieved pads and pads
        // isolated from the pour entirely.
        ClipperLib::Clipper cl_cut;
        cl_cut.AddPaths(out, ClipperLib::ptSubject, true);
        bool anyAntipad = false;
        for (int i = 0; i < params->thermalPadCount; i++) {
            const auto &pad = params->thermalPads[i];
            if (pad.connectStyle != 1 && pad.connectStyle != 2) {
                continue;
            }
            ClipperLib::Path p = to_path(pad.path);
            if (p.size() < 3) {
                continue;
            }
            ClipperLib::Paths padPaths { p };
            ClipperLib::Paths simplified;
            ClipperLib::SimplifyPolygons(padPaths, simplified, ClipperLib::pftNonZero);
            auto antipad = offset_paths(simplified, pad.gapWidth + mw / 2.0, ClipperLib::jtMiter, 2000);
            if (!antipad.empty()) {
                cl_cut.AddPaths(antipad, ClipperLib::ptClip, true);
                anyAntipad = true;
            }
        }
        if (anyAntipad) {
            cl_cut.Execute(ClipperLib::ctDifference, plane_with_thermal_cutouts, ClipperLib::pftNonZero);
            hasThermalGeometry = true;
        }
    }

    ClipperLib::Paths before_expand = plane_with_thermal_cutouts;
    {
        // (4b) Add the spokes back, for thermally-relieved pads only — an
        // isolated pad keeps its full ring and stays unconnected.
        ClipperLib::Paths spokes;
        for (int i = 0; i < params->thermalPadCount; i++) {
            const auto &pad = params->thermalPads[i];
            if (pad.connectStyle != 1) {
                continue;
            }
            build_thermal_spokes(pad, mw, spokes);
        }
        if (!spokes.empty()) {
            // Each spoke is kept only if it actually reaches the pour, and that
            // test used to run a full boolean against the WHOLE plane — once per
            // spoke. It was the dominant cost of the entire pour: a dense ground
            // plane has hundreds of thermal pads, so thousands of spokes, each
            // re-adding every contour of a plane that may carry thousands of
            // cutouts.
            //
            // A plane contour whose bounding box misses the spoke cannot contain
            // any point of it, so under non-zero filling it cannot change
            // whether that spoke meets the pour. Testing against only the
            // overlapping contours gives the same answer from a fraction of the
            // geometry — this is a narrower input, not an approximation.
            struct Bounds { ClipperLib::cInt x0, y0, x1, y1; };
            auto boundsOf = [](const ClipperLib::Path &path) {
                Bounds b { path[0].X, path[0].Y, path[0].X, path[0].Y };
                for (const auto &pt : path) {
                    b.x0 = std::min(b.x0, pt.X);
                    b.y0 = std::min(b.y0, pt.Y);
                    b.x1 = std::max(b.x1, pt.X);
                    b.y1 = std::max(b.y1, pt.Y);
                }
                return b;
            };

            std::vector<Bounds> planeBounds;
            std::vector<bool> planeUsable;
            planeBounds.reserve(plane_with_thermal_cutouts.size());
            planeUsable.reserve(plane_with_thermal_cutouts.size());
            for (const auto &path : plane_with_thermal_cutouts) {
                if (path.empty()) {
                    planeBounds.push_back(Bounds { 0, 0, 0, 0 });
                    planeUsable.push_back(false);
                } else {
                    planeBounds.push_back(boundsOf(path));
                    planeUsable.push_back(true);
                }
            }

            ClipperLib::Clipper cl_add;
            cl_add.AddPaths(plane_with_thermal_cutouts, ClipperLib::ptSubject, true);
            bool anySpoke = false;
            ClipperLib::Paths nearby;
            for (const auto &spoke : spokes) {
                if (spoke.empty()) {
                    continue;
                }
                const Bounds sb = boundsOf(spoke);
                nearby.clear();
                for (size_t i = 0; i < plane_with_thermal_cutouts.size(); i++) {
                    if (!planeUsable[i]) {
                        continue;
                    }
                    const Bounds &pb = planeBounds[i];
                    if (pb.x1 < sb.x0 || pb.x0 > sb.x1 || pb.y1 < sb.y0 || pb.y0 > sb.y1) {
                        continue;
                    }
                    nearby.push_back(plane_with_thermal_cutouts[i]);
                }
                if (nearby.empty()) {
                    // Nothing of the plane is near it, so it meets nothing.
                    continue;
                }
                ClipperLib::Clipper cl_test;
                cl_test.AddPaths(nearby, ClipperLib::ptSubject, true);
                cl_test.AddPath(spoke, ClipperLib::ptClip, true);
                ClipperLib::Paths test_result;
                cl_test.Execute(ClipperLib::ctIntersection, test_result, ClipperLib::pftNonZero);
                if (!test_result.empty()) {
                    cl_add.AddPath(spoke, ClipperLib::ptClip, true);
                    anySpoke = true;
                }
            }
            if (anySpoke) {
                cl_add.Execute(ClipperLib::ctUnion, before_expand, ClipperLib::pftNonZero);
                hasThermalGeometry = true;
            }
        }
    }

    // Clip thermal result back to the original (only meaningful if spokes/antipads ran).
    ClipperLib::Paths clipped_to_orig = before_expand;
    if (hasThermalGeometry) {
        ClipperLib::Clipper cl_clip;
        cl_clip.AddPaths(before_expand, ClipperLib::ptSubject, true);
        cl_clip.AddPaths(out, ClipperLib::ptClip, true);
        cl_clip.Execute(ClipperLib::ctIntersection, clipped_to_orig, ClipperLib::pftNonZero);
    }
    if (clipped_to_orig.empty()) {
        return empty;
    }

    // (5) Dilate back by half the minimum copper width, completing the opening
    // begun in (1).
    const bool hatch = params->fillStyle == 1;
    ClipperLib::Paths finalPaths;
    ClipperLib::PolyTree tree;
    {
        ClipperLib::ClipperOffset ofs;
        ofs.ArcTolerance = 2000;
        ofs.AddPaths(clipped_to_orig, jt, ClipperLib::etClosedPolygon);
        if (!hatch) {
            ofs.Execute(tree, mw / 2.0);
        }
        else {
            ofs.Execute(finalPaths, mw / 2.0);
        }
    }

    // (6) Hatching, when the plane is not solid: intersect with a grid and keep
    // a solid border so the pour still has a continuous edge.
    if (hatch) {
        if (finalPaths.empty()) {
            return empty;
        }
        const double borderWidth = std::max(0.0, params->hatchBorderWidth);
        const int64_t lineWidth = std::max<int64_t>(1, static_cast<int64_t>(params->hatchLineWidth));
        const int64_t lineSpacing = std::max<int64_t>(1, static_cast<int64_t>(params->hatchLineSpacing));

        auto contracted = offset_paths(finalPaths, -borderWidth, ClipperLib::jtRound, 2000);
        ClipperLib::Paths border;
        {
            ClipperLib::Clipper cl;
            cl.AddPaths(finalPaths, ClipperLib::ptSubject, true);
            if (!contracted.empty()) {
                cl.AddPaths(contracted, ClipperLib::ptClip, true);
            }
            cl.Execute(ClipperLib::ctDifference, border, ClipperLib::pftNonZero);
        }

        ClipperLib::Paths grid;
        for (int64_t x = poly_bb.first.X; x < poly_bb.second.X; x += lineSpacing) {
            ClipperLib::Path line(4);
            line[0] = {x - lineWidth / 2, poly_bb.first.Y};
            line[1] = {x + lineWidth / 2, poly_bb.first.Y};
            line[2] = {x + lineWidth / 2, poly_bb.second.Y};
            line[3] = {x - lineWidth / 2, poly_bb.second.Y};
            grid.push_back(line);
        }
        for (int64_t y = poly_bb.first.Y; y < poly_bb.second.Y; y += lineSpacing) {
            ClipperLib::Path line(4);
            line[0] = {poly_bb.first.X, y + lineWidth / 2};
            line[1] = {poly_bb.first.X, y - lineWidth / 2};
            line[2] = {poly_bb.second.X, y - lineWidth / 2};
            line[3] = {poly_bb.second.X, y + lineWidth / 2};
            grid.push_back(line);
        }

        ClipperLib::Paths grid_isect;
        {
            ClipperLib::Clipper cl;
            cl.AddPaths(grid, ClipperLib::ptSubject, true);
            cl.AddPaths(finalPaths, ClipperLib::ptClip, true);
            cl.Execute(ClipperLib::ctIntersection, grid_isect, ClipperLib::pftNonZero);
        }
        {
            ClipperLib::Clipper cl;
            cl.AddPaths(grid_isect, ClipperLib::ptSubject, true);
            if (!border.empty()) {
                cl.AddPaths(border, ClipperLib::ptClip, true);
            }
            cl.Execute(ClipperLib::ctUnion, tree, ClipperLib::pftNonZero);
        }
    }

    return fragments_from_tree(tree);
}

void HorizontalClipperFreeFragments(HorizontalClipperFragmentList fragments)
{
    for (int fragmentIndex = 0; fragmentIndex < fragments.count; fragmentIndex++) {
        auto &fragment = fragments.fragments[fragmentIndex];
        for (int pathIndex = 0; pathIndex < fragment.count; pathIndex++) {
            std::free(fragment.paths[pathIndex].points);
        }
        std::free(fragment.paths);
    }
    std::free(fragments.fragments);
}

HorizontalClipperTriangleList HorizontalClipperTriangulatePlaneFragment(
    const HorizontalClipperPath *paths,
    int pathCount
)
{
    HorizontalClipperTriangleList empty {};
    if (!paths || pathCount <= 0) {
        return empty;
    }

    try {
        // Mapbox earcut takes the polygon as `vector<vector<Point>>` where rings[0]
        // is the outer ring and rings[1..] are holes. ~5–10× faster than poly2tri's
        // CDT on polygons with many holes (which is our common case — every plane
        // is a fill with cutouts for every pad/via on the net).
        std::vector<std::vector<HorizontalClipperPoint>> rings;
        rings.reserve(static_cast<size_t>(pathCount));
        for (int pathIndex = 0; pathIndex < pathCount; pathIndex++) {
            auto cleaned = clean_path(paths[pathIndex]);
            if (cleaned.size() >= 3) {
                rings.push_back(std::move(cleaned));
            }
        }
        if (rings.empty()) {
            return empty;
        }

        const std::vector<uint32_t> indices = mapbox::earcut<uint32_t>(rings);
        if (indices.size() < 3 || (indices.size() % 3) != 0) {
            return empty;
        }

        // Flatten vertices in the same order earcut indexed them: outer ring first,
        // then each hole. earcut's `vertices` running index walks the rings in this
        // exact order, so a flat copy in the same order matches the indices.
        std::vector<HorizontalClipperPoint> flatVertices;
        std::size_t totalVertices = 0;
        for (const auto& ring : rings) totalVertices += ring.size();
        flatVertices.reserve(totalVertices);
        for (const auto& ring : rings) {
            for (const auto& point : ring) {
                flatVertices.push_back(point);
            }
        }

        const std::size_t outCount = indices.size();
        HorizontalClipperPoint *out = static_cast<HorizontalClipperPoint *>(
            std::malloc(outCount * sizeof(HorizontalClipperPoint))
        );
        if (!out) {
            return empty;
        }
        for (std::size_t i = 0; i < outCount; i++) {
            const uint32_t idx = indices[i];
            if (idx >= flatVertices.size()) {
                std::free(out);
                return empty;
            }
            out[i] = flatVertices[idx];
        }

        HorizontalClipperTriangleList result {};
        result.points = out;
        result.count = static_cast<int>(outCount);
        return result;
    } catch (const std::exception &) {
        return empty;
    } catch (...) {
        return empty;
    }
}

void HorizontalClipperFreeTriangles(HorizontalClipperTriangleList triangles)
{
    std::free(triangles.points);
}

HorizontalClipperPath HorizontalClipperOffsetPolygon(
    const HorizontalClipperPoint *points,
    int count,
    double delta,
    int joinType
)
{
    HorizontalClipperPath empty {};
    if (!points || count < 3) {
        return empty;
    }

    ClipperLib::Path path;
    path.reserve(static_cast<size_t>(count));
    for (int index = 0; index < count; index++) {
        path.emplace_back(to_int(points[index].x), to_int(points[index].y));
    }

    ClipperLib::ClipperOffset ofs;
    ofs.AddPath(path, join_type_from_int(joinType), ClipperLib::etClosedPolygon);
    ClipperLib::Paths result;
    ofs.Execute(result, delta);

    // The reference requires exactly one resulting polygon; otherwise it reports
    // "expand error" and leaves the polygon unchanged.
    if (result.size() != 1) {
        return empty;
    }
    return copy_path(result[0]);
}

void HorizontalClipperFreePath(HorizontalClipperPath path)
{
    std::free(path.points);
}

#include "../../Vendor/Clipper/clipper.cpp"
