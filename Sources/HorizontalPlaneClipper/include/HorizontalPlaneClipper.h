#ifndef HORIZON_PLANE_CLIPPER_H
#define HORIZON_PLANE_CLIPPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HorizontalClipperPoint {
    double x;
    double y;
} HorizontalClipperPoint;

typedef struct HorizontalClipperPath {
    HorizontalClipperPoint *points;
    int count;
} HorizontalClipperPath;

typedef struct HorizontalClipperFragment {
    HorizontalClipperPath *paths;
    int count;
    int orphan;
} HorizontalClipperFragment;

typedef struct HorizontalClipperFragmentList {
    HorizontalClipperFragment *fragments;
    int count;
} HorizontalClipperFragmentList;

typedef struct HorizontalClipperTriangleList {
    HorizontalClipperPoint *points;
    int count;
} HorizontalClipperTriangleList;

// JoinType encoding shared across the ABI: 0 = round, 1 = square, 2 = miter.

// One obstacle to subtract from the plane. `outset` is the FULL expand delta
// already summed in Swift (clearance + min_width/2 + epsilon). `joinType` and
// `arcTolerance` let keepouts (round, 10000) differ from normal cutouts.
typedef struct HorizontalClipperCutout {
    HorizontalClipperPath path;
    double outset;
    int joinType;
    double arcTolerance;
} HorizontalClipperCutout;

// One same-net pad participating in thermal relief. The pad path is in board
// world coordinates. connectStyle: 0 = solid (skip — pour floods),
// 1 = thermal (antipad + spokes), 2 = none/isolate (antipad, no spokes).
typedef struct HorizontalClipperThermalPad {
    HorizontalClipperPath path;
    double placementX;
    double placementY;
    int placementAngle; // Horizon angle units, 65536 == full turn
    int placementMirror; // 0/1
    int connectStyle;
    double gapWidth;
    double spokeWidth;
    int nSpokes;
    int spokeAngle;
} HorizontalClipperThermalPad;

typedef struct HorizontalClipperPlaneFillParams {
    const HorizontalClipperPath *subjects; // plane outline (arc-flattened)
    int subjectCount;
    double minWidth;
    int joinType; // plane style join type

    const HorizontalClipperCutout *cutouts;
    int cutoutCount;

    const HorizontalClipperPath *boardOutline; // arc-flattened outline polygons
    int boardOutlineCount;
    int hasBoardOutline; // if 0, skip the board-outline intersect entirely
    double boardOutlineContract; // positive magnitude; plane is contracted by this

    const HorizontalClipperThermalPad *thermalPads;
    int thermalPadCount;

    int fillStyle; // 0 = solid, 1 = hatch
    double hatchBorderWidth;
    double hatchLineWidth;
    double hatchLineSpacing;
} HorizontalClipperPlaneFillParams;

// General-purpose "subtract uniformly-inflated cutouts from subjects, return
// fragments" helper. Used for pad-outline unions and 3D-scene copper clipping
// (NOT plane pours — those use BuildPlaneFillEx below).
HorizontalClipperFragmentList HorizontalClipperBuildPlaneFill(
    const HorizontalClipperPath *subjects,
    int subjectCount,
    const HorizontalClipperPath *cutouts,
    int cutoutCount,
    double subjectInset,
    double cutoutOutset,
    double finalOutset
);

// Full per-plane copper pour. The pipeline, in order: erode by half the minimum
// copper width, subtract cutouts, clip to the contracted board outline, apply
// thermal relief (antipad rings, then spokes for relieved pads), dilate back,
// and hatch if the plane is not solid. The erode/dilate pair is a morphological
// opening: it removes copper too thin to fabricate.
HorizontalClipperFragmentList HorizontalClipperBuildPlaneFillEx(const HorizontalClipperPlaneFillParams *params);

void HorizontalClipperFreeFragments(HorizontalClipperFragmentList fragments);

HorizontalClipperTriangleList HorizontalClipperTriangulatePlaneFragment(
    const HorizontalClipperPath *paths,
    int pathCount
);

void HorizontalClipperFreeTriangles(HorizontalClipperTriangleList triangles);

// Offsets a single closed polygon by `delta` (joinType: 0 round, 1 square,
// 2 miter). Returns the result only when the offset yields exactly one polygon;
// an offset that splits a polygon into several, or collapses it entirely, is
// reported as failure rather than guessed at, because the caller needs one
// contour. Otherwise returns {points:NULL, count:0}. Free the returned path with
// HorizontalClipperFreePath.
HorizontalClipperPath HorizontalClipperOffsetPolygon(
    const HorizontalClipperPoint *points,
    int count,
    double delta,
    int joinType
);

void HorizontalClipperFreePath(HorizontalClipperPath path);

#ifdef __cplusplus
}
#endif

#endif
