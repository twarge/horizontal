# A push-and-shove router for Horizontal

A design study. No code yet — this is the specification work that has to happen
before any, and the licensing constraint that shapes it.

## The licensing constraint comes first

KiCad's PNS router is **GPLv3**. Horizontal is Apache 2.0, and this repository
removed its vendored copy of that router precisely because it was the only
GPL-licensed code that ever shipped in the binary.

Reading that source to reimplement its algorithms would put this project back
where it started, in the one subsystem that currently has no coupling at all. A
port is a derivative work whether or not a line is copied; §101 lists
translation as a form of derivation, and "I rewrote it in Swift" is a
translation. (Not legal advice.)

So this study is built from **published descriptions and first principles**. The
techniques below are decades old, described in the academic literature and in
patents that have expired or were never asserted against them, and are
implemented independently by several vendors. What follows cites the ideas, not
an implementation.

A practical rule for whoever writes the code: if you cannot explain why a
constant is what it is, you have copied it rather than derived it. That test
served the plane pour well.

## What "world-class" has to mean here

Not "has a shove mode". The bar users measure against is Altium and KiCad 7+:

1. **It never produces a DRC violation.** A shove that leaves an illegal board
   is worse than a shove that refuses, because the violation is silent.
2. **It is fast enough to run per mouse-move.** Interactive routing means the
   whole solve happens between frames — single-digit milliseconds on a dense
   board, not tens.
3. **It is deterministic.** The same drag produces the same copper every time.
   This project already learned that lesson from the pour, where a fill that
   varied run to run would have been worse than useless.
4. **It degrades honestly.** When it cannot find a route it says so and shows
   the obstruction, rather than committing something plausible.
5. **It is undoable as one action**, including every track it displaced.

(1) and (3) are the ones that separate a demo from a tool.

## What Horizontal already has

- `HorizontalRouterWorld` — a flat snapshot of copper (tracks, vias, pads as
  polygons with layer spans) plus a precomputed net×net clearance matrix, with
  tests. This is the router's input and it already exists. It was built as the
  seam to the vendored router; nothing about it is specific to that engine.
- `HorizontalBoardRulesModel` — clearance resolution by net, layer and object
  class, which is where a router's clearances must come from.
- `HorizontalSelectableSpatialIndex` — a spatial index over board objects, the
  same shape a router needs for obstacle queries.
- `BoardTrackRouting` — interactive 45°-constrained drawing with posture, the
  interaction layer a router plugs into.
- Clipper (Boost licence) and earcut (ISC), already vendored and compiled in.
- A commit funnel that re-derives connectivity after every edit, and an undo
  model that already treats a multi-object change as one action.

The missing piece is the engine between them.

## The two lineages

**Shove-based, geometric.** Obstacles are inflated to hulls; a route is a
polyline; when it collides, the *obstacle* is displaced and the displacement
recurses. This is what KiCad, Altium and Pulsonix present to the user. It is
directly implementable, incremental, and matches what users expect from the
gesture.

**Rubber-band sketch (RBS), topological.** Routes are stored as topological
paths — an ordering of which side of each obstacle a net passes — and geometry
is realised from that ordering afterwards. Descended from Cadence Allegro and
the Specctra lineage; the academic basis is the rubber-band routing work of Dai,
Kong and Sato and the topological-routing literature that followed. It is
strictly more powerful: it can reroute globally, it survives component moves
(the topology holds, the geometry is re-realised), and it does not paint itself
into a corner the way greedy shoving can.

**Recommendation: build shove-based, but keep the topology explicit.** The
geometric router is the tractable target and the one users are asking for. The
mistake to avoid is throwing away the topological information the shove already
computes — which side of each obstacle the route passed. Record it. That single
discipline is what leaves the door open to RBS later instead of requiring a
rewrite, and it costs almost nothing at the time.

## Architecture

### 1. Fixed-point geometry, 8 directions

Coordinates stay integer nanometres, as everywhere else in this project.
Interactive routes are constrained to 8 directions (H, V, both diagonals), so
every segment is axis-aligned or exactly 45°. Two consequences worth stating:

- Corner arithmetic is exact. No accumulated floating-point drift, so a route
  dragged and re-dragged returns to the same coordinates.
- A "posture" (which of the two corners comes first) is part of the route's
  state, not derived. Users toggle it, and it must survive a shove.

### 2. Hulls, not polygons

The core operation is *walk around an obstacle*. For that, each obstacle is
inflated by `clearance + trackWidth/2` into a convex hull — an octagon for
45° routing. Walking around an octagon is a handful of integer comparisons.

Resist the temptation to reuse Clipper here. General polygon offsetting is
correct and far too slow for a per-frame inner loop, and it returns geometry
that then has to be re-simplified. Clipper's place is the plane pour, which runs
once per command; the router's inner loop needs hull arithmetic measured in
nanoseconds. This is the single biggest performance decision in the design.

### 3. Walkaround

Given a line and a hull it collides with, there are exactly two ways around:
clockwise and anticlockwise. Produce both, score them (length, corner count,
whether the result collides with anything else), take the better. Recurse for
the next obstacle, with a bound on total obstacles considered.

Walkaround alone is already a useful mode — "route around what is there" — and
it is a prerequisite for shoving, because shoving is walkaround applied to the
*other* track.

### 3a. Clearances — audited

Getting a clearance wrong is the same failure as missing an obstacle: copper
closer than the rules allow, reported as a legal route. The rules are richer
than a single number, and `HorizontalRouterClearances` resolves them:

- **Object class.** Eleven kinds, and a board may clear a via, a pad or a plane
  differently from a track. The router world's own table collapsed everything to
  track-to-track, which under-clears against every class with a larger number.
- **Layer.** Clearance rules can be scoped to a layer; resolving them all on top
  copper gives inner layers the wrong numbers.
- **Copper vs not.** Board edge, unplated holes and text are governed by a
  separate table. Text is folded into a generic "other" class, so a rule keyed
  on `text` never matches — a trap worth knowing about once.
- **Keepouts** have a third table, keyed by keepout class.
- **Same net is zero**, decided centrally so every path agrees, and net −1 is
  NOT same-net: two unconnected pieces of copper still have to clear each other.
- **Broad then narrow.** One query hull is inflated by the widest clearance any
  obstacle could demand, and each candidate is then tested with its own exact
  number. Inflating by the exact clearance would need a query per obstacle;
  stopping at the broad number would over-clear and refuse legal routes.

**The obstacles behind those numbers are now extracted too**, since a clearance
resolved correctly for a mounting hole is worth nothing if the hole is not in
the world. Unplated holes (board and package, obstructing every layer, never
same-net), keepouts (carrying their class so their own rule applies, and skipped
entirely when they do not bar tracks), and the board outline — the last as one
obstacle PER EDGE, because a single hull around an outline is the whole board
and would collide with every track inside it.

**Planes are deliberately not obstacles.** A pour is recomputed from the copper
around it, so a plane yields to a new track rather than obstructing it; treating
one as an obstacle would make a ground-flooded board unroutable. Horizontal
already marks the fills stale after an edit and asks for a re-pour, which is the
right division.

**Known approximation.** A concave keepout is over-approximated by its octagon,
so the router avoids more area than required. That refuses legal routes rather
than allowing illegal ones — the right way to be wrong — but it is a real
limitation on boards with L-shaped keepouts.

### 4. Shove

When the new route collides with an existing track, displace that track: compute
its new path as a walkaround of the new route's hull, then check what *that*
collides with, and recurse.

The parts that decide whether it feels world-class:

- **Rank.** Each track gets a rank; a track may only shove tracks of lower rank.
  Without it two tracks push each other forever.
- **Depth and time budget.** Bound both. Interactive means the answer must come
  back this frame; an unbounded correct answer is a wrong answer.
- **Atomic failure.** If the recursion fails or exceeds budget, discard the
  whole speculative state and fall back to walkaround or collision highlighting.
  Never commit a partial shove.
- **Locked and fixed objects are immovable** — pads, locked tracks, board
  outline — and are the recursion's base case.

### 5. The node tree

Speculative work needs to be free to discard. Model the board as a base state
plus a stack of *nodes*, each holding only its own additions and removals. A
shove attempt allocates a node, works in it, and either commits (collapse into
the parent) or drops it (free the node, board untouched).

This is what makes "try a shove every mouse-move and throw most of them away"
affordable, and it is the same idea as the plane pour's discard-if-inputs-moved
guard, applied per frame instead of per command.

### 6. Optimiser

Raw shove output has redundant corners. A post-pass should:

- merge collinear and near-collinear runs;
- replace two corners with one where clearance allows;
- pull routes taut against their hulls (the rubber-band idea, applied locally);
- clean up the pad exit, which is where most of the visible ugliness lives.

Run it on the committed result, and on the preview only if it fits the frame
budget. An optimiser that makes the preview jump around is worse than none.

### 7. Vias

A via is an obstacle on every layer it spans, and a shoved via drags its
connected tracks on both sides. Getting this right is most of the difference
between a two-layer toy and something usable on a real board. Horizontal's
connectivity model already knows a via's true span via `connectedLayers`
(blind and buried vias included), which is exactly what the router needs.

## Performance

Budget: **≤5 ms per mouse-move** on a board the size of Randi Short (~800
tracks, ~2600 pads). That is what makes the preview feel attached to the cursor.

- Query obstacles from a spatial index, never by scanning. The index must
  support "what is within this swept box on this layer".
- Keep the hot loop allocation-free. Swift will make this the hard part;
  pre-size buffers, avoid `Array` growth inside the recursion, and be
  suspicious of anything returning a new array per obstacle.
- Do not re-extract the world per frame. Extract once per edit, patch
  incrementally, and reuse — the same lesson the plane cache taught.
- Profile against a real board from the start. Synthetic cases will not show
  the pathologies.

## Correctness

The router's output is copper that gets fabricated, so it warrants the same
treatment the pour got:

- **Property tests.** After any shove: no two objects of different nets are
  closer than their clearance; every displaced track still connects the same
  two endpoints; no track crosses the board outline. These are checkable
  without a golden and they are the specification.
- **Determinism test.** The same drag, run twice, produces identical geometry —
  including under any concurrency. The pour needed this and so does this.
- **Golden routes over a real board**, with the same guard the plane golden
  now has: fingerprint the input board so an edit to it cannot masquerade as a
  regression.
- **Termination test.** Adversarial layouts — dense parallel buses, a track
  boxed in by four others — must fail cleanly within budget rather than hang.

## Suggested order

1. ~~Hull arithmetic and the eight-direction algebra, with property tests.~~
   **Done** — `HorizontalRouterGeometry.swift`. `HorizontalDirection45` and
   `HorizontalOctagon`, the latter stored as eight support values so that
   building, inflating and intersecting are all cheap and the separating-axis
   test over the eight shared normals is a decision rather than an
   approximation. The clearance property — an inflated hull contains every
   point within the clearance — is swept over the full circle, and was
   falsified before being trusted: the classic bug of inflating diagonal faces
   by `d` instead of `d√2` fails it 358 times, and merely rounding the wrong
   way still fails it 4 times.
2. ~~Spatial queries against `HorizontalRouterWorld`, benchmarked on a real
   board.~~ **Done** — `HorizontalRouterIndex.swift`. A layer-bucketed uniform
   grid whose central property is that it never MISSES an obstacle (a false
   positive costs one exact test; a false negative is a short that ships), so
   it is checked exhaustively against brute force rather than by example.
   Clearance is deliberately not baked into the stored hulls — it depends on
   the net pair, so the caller inflates its query instead, one test rather than
   one per obstacle. On Randi Short: 1862 obstacles, extract 0.8 ms, build
   0.3 ms, **0.4 µs per query**, against a 5 ms per-mouse-move budget.
3. **Partly done** — `HorizontalRouteWalkaround.swift`. The 45° elbow (both
   postures, exact integer corners), path measurement and simplification, and
   the two ways around one obstacle: the hull's corner ring is already a legal
   45° path, so a detour is that arc with an elbow at each end. Choice between
   them is by cost with a deterministic tie-break, since a router that picks
   differently run to run cannot be used to compare two versions of a board.
   Recursion over successive obstacles is in `HorizontalRouteFinder.swift`:
   detour around the earliest collision, re-check, repeat under a budget, and
   try an obstacle's other side before declaring it blocked. It shoves nothing,
   so it is usable as it stands.

   `HorizontalBoardTrackRouterSession` is the seam to the board: it extracts and
   indexes the world ONCE when a drawing gesture starts — about a millisecond,
   fine once and wasteful sixty times a second — and answers route requests in
   board terms, translating net ids to dense codes and mapping a blocking
   obstacle back to the board object id the UI can highlight. A pad, keepout,
   hole or board edge reports nil rather than a fabricated reference.

   The draw-track tool calls it behind "Route around obstacles" in the tool
   settings, for both the preview and the commit, with the session built once
   when the gesture starts. The toggle was already there but inert — its whole
   section was behind `#if canImport(HorizontalPushShoveRouter)`, a module
   removed with the vendored engine, so it had not been visible since. This
   router is pure Swift and works on both platforms, so the guard is gone.

   First runtime look found two things worth recording. A detour walks the
   obstacle's whole corner ring, which is legal but is a staircase — routes are
   now pulled taut afterwards, dropping any corner whose removal is still clear
   of everything, which took one obstacle from five corners to three. And the
   tool was drawing the router's result even when it had NOT got through: that
   partial path collides with whatever stopped it, so the router looked like it
   ignored pads, and committing it would have laid illegal copper. An incomplete
   route now falls back to the plain elbow.

   **A real-board harness now measures it** (`RouterRealBoardHarnessTests`),
   because the synthetic tests passed twice while the router was visibly broken
   in the app: none of them did the one thing every real route does, which is
   start on a pad. It samples pad-to-pad requests on Randi Short and reports
   completion rate, violations, corner counts and what blocked.

   Its first run is the honest picture: **117 routes tried, 2 completed, 115
   blocked** — by pads (70), vias (23) and tracks (22). The cause it identified:
   a detour picks its entry onto the obstacle's corner ring by PROXIMITY and
   then elbows to it, and that elbow cuts straight through the hull it is meant
   to avoid, so both sides fail and the route gives up. **Tangent selection is
   the fix and is the next piece of work.** The harness is recorded as an
   expected failure so the suite stays honest — it goes green when the router
   actually works.

   **Still honest about quality:** the routes are legal and no longer staircases,
   but they are not yet pretty. The optimiser the study describes — pad exits,
   corner merging beyond simple removal — is not built.

   **Still to do:** the shove itself (steps 4–5), and removing the inert
   `#if canImport(HorizontalPushShoveRouter)` blocks that remain in
   `BoardCanvasView` from the vendored engine.

   Two things this uncovered. A route riding an inflated hull's boundary is
   exactly at its clearance and therefore legal, so the collision test needs
   strict overlap rather than "share any point" — with the wrong one, every
   detour reports as colliding with the obstacle it was drawn to avoid. And a
   segment running in one of the eight directions IS its own octagon, so
   segment-versus-obstacle collision is a decision rather than an
   approximation — a property that only holds because routes are 45°.
4. The node tree, so speculation is free.
5. Single-level shove. Then recursion, with rank and budget.
6. Optimiser.
7. Via shoving.
8. Topology recording — cheap at this point, and the door to RBS.

Steps 1–3 are worth doing regardless of whether the shove ever lands: they give
Horizontal an obstacle-aware interactive router, which is already better than
what it has.

## Honest scale

KiCad's PNS is on the order of twenty thousand lines and a decade of work.
Steps 1–3 here are weeks. A shove that is correct, bounded and deterministic on
real boards is months. Anyone promising otherwise has not written one.

The failure mode to avoid is a shove that mostly works: it produces boards with
violations the user does not notice until fabrication. Better to ship
walkaround, which is honest about what it cannot do, and add shoving when it can
be defended by tests.
