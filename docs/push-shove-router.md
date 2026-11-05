# A push-and-shove router for Horizontal

A design study. No code yet — this is the specification work that has to happen
before any, and the licensing constraint that shapes it.

## A search, not a walk (September 2026)

The walkaround router completed two percent of pad-to-pad routes on the real
board, and every failure fell back to the plain elbow, so in the app it looked
as if it ignored obstacles altogether. The diagnosis, from a harness that
classified the failures: of 122 failures, 94 had both endpoints reachable at
that width. The rules were not the limit; the greedy walk was. It detoured
around one obstacle at a time and committed to each side before seeing the
next, and the way past a dense component is a sequence of such decisions.

`HorizontalRouteFinder` now runs a **search**. When the plain elbow is not clear
it hands the request to `HorizontalRouteGridSearch`: A* over an octilinear grid
whose moves are the eight routing directions, so every path it returns is a
legal 45° route, and whose every move is tested exactly against the obstacle
hulls, so every path it returns is clear. The grid is anchored on the start
point, so grid points stay on integer nanometres, and the target is reached by
an elbow from whichever node first sees it clear. What comes back is a
staircase; the finder pulls it taut — from each anchor the furthest later point
a clear elbow reaches, found by galloping and bisection — and then drops any
corner whose removal is still clear. Each shortcut is tested, so the pulling
shortens a route but never makes it illegal.

Things learned making it fast enough, all measured on the real board in a
release build (`swift test -c release`; the unoptimised test build is fifty
times slower and its timings mean nothing):

- **The heuristic is over-weighted, by 1.5.** Plain A* expands every node whose
  estimate is below the true cost, and in a dense field where the route is
  much longer than the crow flies that is an ellipse of thousands of cells.
  Weighting makes the search greedy towards the target; the pulling pass
  recovers most of what that costs in route quality.
- **The spatial index was queried once per node, and that was most of the
  cost.** Its cells were sized to the average obstacle, which on a board with
  long tracks is millimetres, so a query in a dense area sorted hundreds of
  pads. Cells are now sized for the query (a quarter of a millimetre) with
  obstacles spread over every cell they touch, and the search queries once per
  8×8 block of grid cells and then screens the block's list per node by a
  distance lower bound — an obstacle further from the node than the longest
  move cannot be touched by any move — so most nodes test a handful of hulls
  exactly and many test none.
- **The octagon is a `SIMD8<Double>`, not an array.** An array-backed octagon
  heap-allocated on every inflate, in the innermost loop.
- **A target nothing can arrive at is checked first.** If no step of one cell
  in any direction can end on the target, no grid path can, and the search
  would otherwise flood its whole window to discover that.
- **One retry, wider or finer.** When the search empties its heap it says
  whether the region it explored reached the window's edge. If it did, the way
  round may lie beyond: the window doubles, the pitch coarsens with it (a far
  detour needs no fine grid) and the budget doubles. If it did not, the start
  is enclosed at that pitch and only a channel narrower than the grid could
  help: the pitch halves, the cells quadruple, the budget triples. On the real
  board the retry rescues about a tenth of what the first attempt gives up on.

The measured result on Randi Short, top copper, 0.2 mm tracks, 125 sampled
pad pairs one to twenty millimetres apart: **53% complete, none with a
violation**, against 2% before. A completed route takes about 2 ms at the
median and 4 ms at the ninetieth percentile; a request that fails takes up to
about 12 ms, because failing means flooding the reachable region. The other
47% are, as far as a much finer grid and a much wider window can tell, not
routable at that width on that layer: the board is dense and already routed,
and the target pad's neighbours leave no gap or the start sits in a pocket of
finished copper. The harness now asserts a completion floor as well as the
violation invariant, and samples its pads in a sorted order — the board hands
them back in dictionary order, which differs from one process to the next,
and a sample that differs run to run turns every number into noise.

**The router keeps the routing offset (November 2026).** Horizon's router
keeps each clearance rule's `routing_offset` beyond its clearance
(PNS_HORIZON_RULE_RESOLVER::Clearance), so a route doesn't sit at the minimum
the rules check allows; the rules check asks only the clearance. This one now
does too (`HorizontalRouterClearances.includesRoutingOffset`, on in the track
tool's session, off for anything that measures against the rules), with a
file that leaves the offset out given RuleClearanceCopper's 0.05 mm and a
keepout no rule takes given nothing. On Randi Short, whose copper rule's
offset is 0.025 mm and copper-to-other's 0.05 mm, the same 125 sampled pairs
now complete 38% of the time, against 53% at the bare clearance, still with
no violation: the board is dense enough that the margin closes channels. A
board that wants the old behaviour sets the offset to 0, in the route
inspector or the rules window.

The walkaround (`HorizontalRouteWalkaround`) stays in the tree. The finder no
longer calls it, but it is tested, it is the piece a shove is built from, and
its tangent-selection lesson below still stands.

## Tangent selection (September 2026)

The detour entry used to be the ring corner *nearest* the approach. That is the
obvious choice and the wrong one: the 45° elbow onto a near corner frequently
cuts straight across the hull the detour exists to avoid. The route was then
either rejected downstream — which is where most of the "blocked" count came
from — or, worse, reported complete while sitting on copper.

`HorizontalRouteWalkaround.detours` now treats every corner the approach can
reach *without crossing the hull* as a candidate and takes the cheapest pairing.
The ring has at most eight corners, so this is a small exhaustive search rather
than a heuristic, and the crossing test is exact: a segment running in one of
the eight routing directions is its own octagon hull, so the separating-axis
test decides it outright. An approach that starts inside the hull — which
happens when the colliding segment's elbow corner lands on the obstacle — keeps
every corner, because filtering there would reject them all and report the way
blocked when it is not.

The measured effect on the real-board harness: violations went from every
completed route to **none**, stable across samples. Completion did not
materially change — a few percent — because that is a different problem. The
finder walks around one obstacle at a time and gives up after trying both ways
past each; getting past a few percent means a real search, not better corner
selection. The harness now asserts the violation invariant and merely reports
completion, because pinning a completion number would only record one sample.

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
   Recursion over successive obstacles WAS in `HorizontalRouteFinder.swift`:
   detour around the earliest collision, re-check, repeat under a budget, and
   try an obstacle's other side before declaring it blocked. That greedy walk
   completed two percent of real routes and was replaced by the grid search
   described at the top of this document (`HorizontalRouteGridSearch.swift`);
   the finder now tries the plain elbow, then the search, then pulls the
   result taut. It shoves nothing, so it is usable as it stands.

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

   Its first run was the honest picture: **117 routes tried, 2 completed, 115
   blocked** — by pads (70), vias (23) and tracks (22). Tangent selection fixed
   the violations but not the completion; the grid search did, and the harness
   now asserts a floor on it (see the top of this document).

   **Still honest about quality:** the routes are legal and no longer staircases,
   but they are not yet pretty. The optimiser the study describes — pad exits,
   corner merging beyond simple removal — is not built.

   When the router finds no way through, the tool now draws NO preview and a
   click lays nothing — it used to fall back to the plain elbow, which cut
   through everything and looked exactly like a router ignoring obstacles.

   **Since then the route stops at the nearest legal point instead**
   (`HorizontalRouteFinder.approach`, which the track tool previews and
   lays). Even with the empty preview, the cursor over another net's pad or
   track still drew the route straight into it. The exemption a route needs
   for the pad it STARTS in applied to the cursor too, so whatever the
   cursor was over stopped being an obstacle. Now the end keeps that
   exemption only where the route joins copper there: its own net's, where
   a fine pitch puts the neighbours' clearances over the pad's centre, or
   any copper while the route has no net yet. Anywhere else, a cursor too
   close to something makes the route aim at the nearest point that isn't
   (`nearestClearPoint`). That point is worked out from the octagons: the
   feet of perpendiculars onto their faces and the corners where faces
   meet, within a radius that doubles from the cursor's depth inside, each
   round tested against the hulls reaching it, in whole nanometres. A goal
   the search can't reach, enclosed, ends the route at the nearest point
   the search did reach. The grid search now hands that path back with its
   verdict, and the route carries on from there along the elbow for as far
   as it stays clear, to the nanometre. So the preview never comes nearer
   anything than the rules allow, and is empty only when the route can
   go nowhere towards the cursor. A click lays what it shows: a click on
   another net's copper, which lays nothing without the router, lays the
   route to that copper's clearance and carries on from there, and a click
   on a pad the route can't get into lays no pad connection and doesn't
   end the route. `route` itself still exempts both ends, for the
   harness's pad-to-pad requests. The session keeps its last eight
   answers, because the canvas asks the same question several times for
   one cursor position (the preview, the route inspector, the click) and an
   unreachable goal costs a whole search. On Randi Short, with the cursor on another
   net's pad (`RouterRealBoardHarnessTests`, 96 requests): every one stops
   short, none violates, and in a release build they take 8 ms on average
   and 27 ms at worst — the nearest legal point about 0.2 ms of that, the rest
   the search, which on that finished board can't reach two goals in three,
   the same cost an unreachable route already had (29 ms at worst in the
   pad-to-pad harness). The first version of `nearestClearPoint` paired every
   face line and asked the index about every candidate, and took 14 s for one
   cursor unoptimised; keeping only the feet and crossings that lie on the
   hulls' own faces, and testing them against one list of hulls per round,
   brought the whole sample's share from 41 s to 2 s. An armed via is dropped where the
   route stops, which the route's own clearance doesn't account for.

   **Loop removal is back** (`BoardTrackLoops`, "Remove loops" in the tool
   settings, on by default). The vendored engine replaced the copper a
   reroute bypassed; this router only ever added copper, so rerouting a
   section left the old one in place. Now a route that leaves its net's
   copper and comes back to it replaces the plain chain between the two
   points: tracks meeting two at a time, through nothing but a via that only
   passes the chain to another layer (and stands in no plane's fill). A chain
   with a branch, a pad or a plane connection inside it stays. The click
   takes it off, vias and their holes included, and the board is drawn
   without it while the cursor rests where that click would be made — both
   through the same function, so the preview is what the click does. A click
   that closes a loop — back on copper already joined to where the stretch
   began, whether or not anything is replaced — ends the route, as a click on
   a pad does, and drops no armed via; plane fills aren't followed in deciding
   that. A route from or to the middle of a track cuts it there at a junction
   first, where it used to end on the track without joining it. Removed vias
   are flagged (`HorizontalBoard.removedViaIDs`) because the writer keeps a
   via entry the model lacks. Delete on a via now flags it too: its entry used to stay in
   the file, so the via came back on reload wherever a track still ended on it.

   **A route starts on copper** ("Start on copper only" in the route inspector,
   on by default; `BoardTrackRouting.copperStart`). Its first click starts it
   only on copper of its layer: in a pad, from the pad's centre; within a via
   that reaches the layer, from the via's centre; within half a track's width
   of its end, from the end; on a straight track's copper, from the nearest
   point of its centreline with whole-nanometre coordinates exactly on the
   line, where the route's first click cuts it. A fractional point would be
   written as a decimal Horizon can't read, and a rounded one off the line
   wouldn't join the track, so on a track at an odd angle with no such point
   near the click it doesn't start. A click anywhere else starts nothing, and
   ⌘-click starts a route anywhere.

   **A route's width is the rules'** (`HorizontalRouteWidth`), as Horizon's
   router takes it. A route that starts on a pad takes the default of the
   first enabled track width rule by order that takes its net, on its layer
   (BoardRules::get_default_track_width), where a layer the rule leaves out
   has RuleTrackWidth's 0.2 mm (BoardRules::update_for_board). One that starts
   on a track continues the track's width, or takes the rules' where the
   track's is theirs, as Horizon's router inherits a track's width and whether
   it is explicit. Either clears a custom width (W, the tool settings), which
   otherwise gives the width of a route started anywhere else; one that starts
   on a pad clears a custom via size too, so its via is the rules' again. A
   track says nothing of a via, so one started on a track keeps the via it
   had. Only with no
   rule taking the net does the width fall back to the one most of the net's
   tracks have, as it always did before the rules were read. A width from the
   rules follows the route onto the layer a via takes it to and the net it
   joins, and follows a change to the rules; the tracks it lays take their
   width from the rules (`width_from_net_class`), as the router's do in
   Horizon, and the others have their own.

   **Each track's width is the rules' or its own** (`HorizontalSegment.widthFromRules`,
   Horizon's `width_from_rules`: a track's `width_from_net_class`, a net tie's
   `width_from_rules`, true where the file leaves it out). The selection
   inspector's Width from: Rules gives a track or net tie the matching rule's
   width and the flag, and a width typed in makes it its own. The rules are
   kept applied (`HorizontalBoardRuleApplication`, BoardRules::apply for every
   kind Horizon applies, which Horizon does only when its Apply is pressed):
   after every board edit, rules change and netlist sync, every track and net
   tie whose width is the rules', on a net, takes its rule's default on its
   layer (`HorizontalTrackWidthRules`), except where no rule takes the net,
   where Horizon's 0 is left alone; a via from the rules takes its via rule's
   padstack and parameters, one from a via definition the definition's and
   its span; a plane from the rules its plane rule's settings. A change to the
   rules' parameters reloads the board, which derives the pads from them.
   The rules window's Apply is gone; its Apply & Check, the arrow beside its
   Rules heading, applies every rule to a board that disagrees with them (as
   one Horizon wrote can; opening a board changes nothing) and runs every
   check into the rules results sidebar, which replaced the window's Checks
   tab. A via's Shape from and a plane's Settings from use the same Rules /
   Custom picker, and choosing Rules gives the item the rule's shape at once;
   a setting given a plane makes it Custom, as a width typed into a track
   does.

   **The route inspector** (`HorizontalRouteInspectorView`) is the sidebar
   while the track tool is in use. Routing leaves the sidebar open or closed
   as it was: an open one on the Mac turns to the route inspector for the
   route and back to its pane a few seconds after the last route ends, and a
   closed one stays closed. The track tool's settings are at its
   top: the corner style, Route around obstacles, Remove loops and Start on
   copper only, which a route under way follows (they were the rail's Track
   Settings popover; S and View ▸ Show Track Settings open the sidebar on
   them while the tool is in use). It shows the route's layer (a picker before the
   route starts), its net and net class, the width and where it
   comes from, the via V drops and where its size comes from, the clearance
   a track keeps from tracks, pads, through-hole
   pads, vias, planes, the board edge, unplated holes and keepouts with the
   rule each comes from (`HorizontalRouteSpacing`: the copper rule is the one
   most other nets get with this one, and the others are listed with how many
   nets they take), and the nearest thing of each kind to the route preview,
   measured copper to copper on the real shapes, with what the rules ask
   between them (`HorizontalRouteClearanceProbe`). Its clearance fields
   change the rules: each clearance its rule's entry (a new catch-all rule
   where none matches), and each clearance rule's routing offset
   (`HorizontalRouteRuleEditing`). Width and via each have Rules / Custom:
   Custom is the tool settings' own size (W, or the via size in the settings);
   Rules clears it, and gives a route that continued a track's width the
   rules' instead. A width, diameter or hole typed in is the route's own and
   never changes a rule, even typed while the rules' showed: the picker turns
   to Custom with it. While the width or via isn't the rules', Define Rule in
   front of the picker makes it theirs: the width the default of the track
   width rule taking the net on the layer, its range widened to take it (a
   new rule taking every net where none does), the via's diameter and hole
   the matching via rule's parameters (a new via rule with the board's default
   via where none takes the net); then the picker goes back to Rules. The rule's
   minimum and maximum widths are the rules window's to edit, not the
   inspector's. A via dropped from the rules
   keeps taking its shape from them (`from_rules`), as Horizon's router places
   one; a custom one is its own. Each change is one undoable step, written
   to the archive and taken into the board without a reload
   (`HorizontalBoard.takeRules`), so the route in progress carries on with
   them; the canvas takes them into the boards it holds on `rulesRevision`.
   The rules window's own edits now go the same way, so the board in memory
   no longer keeps the rules it loaded with until it is opened again.

   **Still to do:** the shove itself (steps 4–5); removing the inert
   `#if canImport(HorizontalPushShoveRouter)` blocks that remain in
   `BoardCanvasView` from the vendored engine; and telling the user WHAT is in
   the way when a route fails — the finder names the obstacle and the session
   maps it to a board object, but the tool does not yet highlight it.

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
