import XCTest
import SwiftUI
@testable import HorizontalNative

/// Tests the zoom-out cull for GENERATED board labels (pad names, via net
/// names, track/net-tie net names): once their glyphs shrink below legibility
/// they are dropped instead of drawn as unreadable clutter.
///
/// This mirrors Horizon's per-primitive text LOD (`Canvas::set_lod_size` +
/// the `lod_size_px` test in `triangle-glyph-geometry.glsl`), except we key on
/// the glyph height rather than the containing feature and cull hard instead of
/// fading — our labels are stroked polylines drawn opaque, so a per-label alpha
/// would compound at stroke overlaps.
final class BoardLabelZoomCullTests: XCTestCase {
    private let mm = 1_000_000.0

    private func line(_ x: Double) -> HorizontalMetalLinePrimitive {
        HorizontalMetalLinePrimitive(
            from: HorizontalPoint(x: x, y: 0),
            to: HorizontalPoint(x: x + 1, y: 1),
            color: HorizontalMetalRGBA(.white)
        )
    }

    private func ref(_ id: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .track)
    }

    // MARK: - filtered(minimumLabelSize:)

    func testFilterDropsOnlyLabelsBelowThreshold() {
        var batch = BoardMetalElementBatch()
        batch.appendLine(line(0), owner: ref("big"), labelSize: 2 * mm)
        batch.appendLine(line(1), owner: ref("small"), labelSize: 0.1 * mm)
        batch.appendLine(line(2), owner: ref("exact"), labelSize: 1 * mm)

        let filtered = batch.filtered(minimumLabelSize: 1 * mm)

        // The 0.1mm label goes; the 2mm one stays; the threshold itself is
        // inclusive, so an exactly-threshold label survives.
        XCTAssertEqual(filtered.lines.count, 2)
        XCTAssertEqual(filtered.lineOwners.compactMap { $0?.id }, ["big", "exact"])
    }

    func testFilterNeverDropsNonLabelGeometry() {
        // Copper, holes, outlines etc. are recorded with labelSize 0 and must
        // survive any threshold — the cull is for generated text only.
        var batch = BoardMetalElementBatch()
        batch.appendLine(line(0), owner: ref("copper"))
        batch.appendLine(line(1), owner: ref("label"), labelSize: 0.01 * mm)

        let filtered = batch.filtered(minimumLabelSize: 5 * mm)

        XCTAssertEqual(filtered.lines.count, 1)
        XCTAssertEqual(filtered.lineOwners.first??.id, "copper")
    }

    func testFilterKeepsOwnersAndSizesAligned() {
        // concatenateMetalBuckets run-length-encodes selection metadata from
        // lineOwners positionally, so a filter that desynced the parallel
        // arrays would mis-attribute picks to the wrong object.
        var batch = BoardMetalElementBatch()
        for index in 0..<20 {
            batch.appendLine(
                line(Double(index)),
                owner: ref("owner-\(index)"),
                labelSize: index.isMultiple(of: 2) ? 3 * mm : 0.2 * mm
            )
        }

        let filtered = batch.filtered(minimumLabelSize: 1 * mm)

        XCTAssertEqual(filtered.lines.count, 10)
        XCTAssertEqual(filtered.lineOwners.count, filtered.lines.count)
        XCTAssertEqual(filtered.lineLabelSizes.count, filtered.lines.count)
        XCTAssertEqual(filtered.lineOwners.compactMap { $0?.id }, (0..<10).map { "owner-\($0 * 2)" })
        XCTAssertTrue(filtered.lineLabelSizes.allSatisfy { $0 == 3 * mm })
    }

    func testFilterIsIdentityWhenNothingIsTooSmall() {
        var batch = BoardMetalElementBatch()
        batch.appendLine(line(0), owner: ref("a"), labelSize: 4 * mm)
        batch.appendLine(line(1), owner: ref("b"))

        XCTAssertEqual(batch.filtered(minimumLabelSize: 1 * mm).lines.count, 2)
        // A zero/absent threshold disables culling entirely.
        XCTAssertEqual(batch.filtered(minimumLabelSize: 0).lines.count, 2)
    }

    func testTrianglesAndAnchoredRectsSurviveFiltering() {
        var batch = BoardMetalElementBatch()
        batch.appendLine(line(0), owner: ref("tiny"), labelSize: 0.01 * mm)
        batch.appendAnchoredRect(
            HorizontalMetalAnchoredRectPrimitive(
                center: HorizontalPoint(x: 0, y: 0),
                color: HorizontalMetalRGBA(.white),
                width: 6,
                height: 6
            ),
            owner: ref("rect")
        )

        let filtered = batch.filtered(minimumLabelSize: 1 * mm)

        XCTAssertTrue(filtered.lines.isEmpty)
        XCTAssertEqual(filtered.anchoredRects.count, 1)
        XCTAssertEqual(filtered.anchoredRectOwners.compactMap { $0?.id }, ["rect"])
    }

    // MARK: - minimumLegibleLabelSize(for:)

    /// A transform whose scale is `points` view-points per `world` world-units.
    private func transform(zoom: CGFloat) -> HorizontalCanvasTransform {
        HorizontalCanvasTransform(
            bounds: HorizontalRect(points: [
                HorizontalPoint(x: 0, y: 0),
                HorizontalPoint(x: 100 * mm, y: 100 * mm),
            ]),
            size: CGSize(width: 1000, height: 1000),
            fitInsets: HorizontalCanvasInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            zoom: zoom
        )
    }

    func testThresholdTracksZoomInverselyAndCullsMoreWhenZoomedOut() {
        let zoomedIn = BoardCanvasView.minimumLegibleLabelSize(for: transform(zoom: 8))
        let zoomedOut = BoardCanvasView.minimumLegibleLabelSize(for: transform(zoom: 0.25))

        // Zooming out means more world units per point, so the world-space size
        // a label must exceed to stay readable grows — i.e. more labels vanish.
        XCTAssertGreaterThan(zoomedOut, zoomedIn)
        XCTAssertGreaterThan(zoomedIn, 0)
    }

    func testThresholdMatchesTheConfiguredPointSizeWithinAQuantizationStep() {
        let t = transform(zoom: 1)
        let threshold = BoardCanvasView.minimumLegibleLabelSize(for: t)

        // A label exactly at the threshold should measure ~the configured point
        // size on screen. Quantization only ever rounds the threshold DOWN (so
        // labels survive slightly longer than the exact cutoff), and one step is
        // 2^(1/4).
        let onScreenPoints = t.length(threshold)
        let step = pow(2.0, 1.0 / 4.0)
        XCTAssertLessThanOrEqual(onScreenPoints, 4.0 + 1e-6)
        XCTAssertGreaterThan(onScreenPoints, 4.0 / step - 1e-6)
    }

    func testThresholdIsStableAcrossSmallZoomChanges() {
        // The threshold is the concat cache key, so it must NOT change on every
        // frame of a pinch — otherwise live zoom re-concatenates continuously.
        let base = BoardCanvasView.minimumLegibleLabelSize(for: transform(zoom: 1))
        let nudged = BoardCanvasView.minimumLegibleLabelSize(for: transform(zoom: 1.02))
        XCTAssertEqual(base, nudged)

        // ...but a large change must move it.
        let far = BoardCanvasView.minimumLegibleLabelSize(for: transform(zoom: 16))
        XCTAssertNotEqual(base, far)
    }

    func testThresholdIsMonotonicAcrossAFullZoomSweep() {
        // Sweep the zoom range CanvasViewport actually allows (0.01x ... 128x,
        // ~14 octaves) densely, so the count below reflects quantization rather
        // than how finely we sampled.
        let octaves = 14.0
        let samplesPerOctave = 40.0
        var previous = Double.greatestFiniteMagnitude
        var distinctValues = Set<Double>()

        for step in 0...Int(octaves * samplesPerOctave) {
            let zoom = 0.01 * pow(2.0, Double(step) / samplesPerOctave)
            let value = BoardCanvasView.minimumLegibleLabelSize(for: transform(zoom: CGFloat(zoom)))
            XCTAssertLessThanOrEqual(value, previous + 1e-9, "threshold must shrink as zoom grows")
            previous = value
            distinctValues.insert(value)
        }

        // 560 samples must collapse to ~4 distinct thresholds per octave — that
        // ratio is what keeps live zoom from re-concatenating every frame.
        XCTAssertLessThanOrEqual(Double(distinctValues.count), octaves * 4 + 2)
        XCTAssertGreaterThan(Double(distinctValues.count), octaves * 4 - 2)
    }

    // MARK: - Deferral until zooming stops

    /// Collects applied values by reference so the escaping callback can record
    /// across isolation without capturing a mutable local.
    private final class AppliedValues {
        var values = [Double]()
    }

    /// Waits for the debounced apply to land rather than sleeping a fixed
    /// interval past its quiet period.
    ///
    /// A fixed sleep encodes an assumption about scheduling latency that a busy
    /// machine breaks, and the failure looks like a bug in the debouncer rather
    /// than in the test. Polling to a generous deadline keeps the test fast when
    /// things are quick and correct when they are not — it only ever waits
    /// longer, never passes something it should fail.
    @MainActor
    private func waitForApplies(
        _ applied: AppliedValues,
        toReach count: Int,
        timeout: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while applied.values.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Nothing applies while the gesture is still moving.
    ///
    /// The quiet period is set far longer than any plausible scheduling delay
    /// rather than sleeping between frames. Sleeping asserts that the MACHINE
    /// schedules promptly, which a loaded CI runner does not — this test failed
    /// there for exactly that reason while passing locally.
    @MainActor
    func testThresholdIsNotAppliedWhileTheTransformKeepsMoving() async {
        let debouncer = BoardLabelLODDebouncer(quietPeriod: .seconds(30))
        let applied = AppliedValues()

        for value in [1.0, 2.0, 3.0, 4.0] {
            debouncer.schedule(value) { applied.values.append($0) }
        }

        XCTAssertTrue(
            applied.values.isEmpty,
            "applying mid-gesture re-runs the board body and re-concatenates buckets — that was the lag"
        )
    }

    /// And once it stops, exactly one apply carrying the FINAL value — the
    /// intermediate steps of the sweep never reach @State.
    @MainActor
    func testOnlyTheFinalValueAppliesOnceTheGestureStops() async {
        let debouncer = BoardLabelLODDebouncer(quietPeriod: .milliseconds(10))
        let applied = AppliedValues()

        for value in [1.0, 2.0, 3.0, 4.0] {
            debouncer.schedule(value) { applied.values.append($0) }
        }

        await waitForApplies(applied, toReach: 1)
        XCTAssertEqual(applied.values, [4.0])
    }

    @MainActor
    func testDebouncerRearmsForLaterZoomChanges() async {
        // The waiter task is reused rather than respawned per frame, so its
        // teardown has to reset cleanly — otherwise the first zoom would be the
        // only one that ever applies and labels would freeze at that LOD.
        let debouncer = BoardLabelLODDebouncer()
        let applied = AppliedValues()

        debouncer.schedule(1.0) { applied.values.append($0) }
        await waitForApplies(applied, toReach: 1)
        XCTAssertEqual(applied.values, [1.0])

        debouncer.schedule(2.0) { applied.values.append($0) }
        await waitForApplies(applied, toReach: 2)
        XCTAssertEqual(applied.values, [1.0, 2.0])
    }

    @MainActor
    func testTransientThresholdChangeThatReturnsCollapsesToOneApply() async {
        // Zoom out past a step and back before settling: the intermediate value
        // must never reach @State.
        //
        // No sleeps between the three frames, for the same reason as above: a
        // sleep would assert that the machine schedules it within the quiet
        // period, and on a loaded runner it does not.
        let debouncer = BoardLabelLODDebouncer(quietPeriod: .milliseconds(10))
        let applied = AppliedValues()

        debouncer.schedule(5.0) { applied.values.append($0) }
        debouncer.schedule(9.0) { applied.values.append($0) }
        debouncer.schedule(5.0) { applied.values.append($0) }

        await waitForApplies(applied, toReach: 1)
        XCTAssertEqual(applied.values, [5.0], "the excursion to 9 must never land")
    }

    func testDegenerateTransformDisablesCulling() {
        // An empty/zero-size canvas must not cull everything on the way to a
        // first real layout.
        let degenerate = HorizontalCanvasTransform(bounds: .empty, size: .zero)
        let threshold = BoardCanvasView.minimumLegibleLabelSize(for: degenerate)
        XCTAssertTrue(threshold.isFinite)
        XCTAssertGreaterThanOrEqual(threshold, 0)
    }
}
