# Length tuning and differential pairs for Horizontal

A design study, with the groundwork that needs no new router already built.
Horizon gets length tuning and differential-pair routing from the vendored
KiCad PNS router, which this repository removed for licensing (see
[push-shove-router.md](push-shove-router.md)). Horizontal's own router walks
around obstacles and shoves nothing, so what can be had now is the data and the
measurements; the meanders and the coupled routing are specified here for a
clean-room implementation.

## What exists (November 2026)

### Pairing

- **The file.** Horizon names a pair once, on its primary: the primary net's
  `diffpair` is the secondary's uuid, and the secondary carries nothing
  (Net::serialize). The secondary learns its partner as the block loads
  (Block::update_diffpairs), and a `diffpair` naming no net of the block, or the
  null uuid, pairs nothing. There is no `diffpair_primary` key in the file;
  `diffpair_primary` is Horizon's in-memory flag. `HorizontalDiffpairs` reads and
  writes exactly that, and two places that had it wrong are fixed: the block
  flattener looked for a `diffpair_primary` key no file has, so an instance's
  pair was always dropped from the board, and a paste wrote a null `diffpair`
  and a `diffpair_primary` where Horizon writes neither.
- **The model.** `HorizontalNetDetails.diffpairID` and `isDiffpairPrimary`, on the
  schematic's nets and the board's, so the board knows each net's partner.
- **Set Diff Pair and Clear Diff Pair**, as Horizon's tools are:
  - the inspector's **Diff pair** row on a schematic net (wire, label,
    junction, bus ripper) and a board net (track, pad, via) — Horizon's
    Diffpair property, "Pri: TX-", "Sec: TX+" or "None", as a choice of
    partner. Choosing a net pairs this one with it as the primary, as Horizon's
    Set Diff Pair does with the net its dialog picks; None clears it. The
    partners offered are the named nets in no pair, power nets left out. On the
    board only the top block's own nets can be paired; an instance's net is its
    block's, paired in that block's schematic.
  - **Design ▸ Set Diff Pair** for two selected nets (the one whose name sorts
    first is the primary, so TX+ before TX-) and **Clear Diff Pair** for one.
  - the MCP ops `set_diffpair` (net, partner) and `clear_diffpair` (net).
    `list_nets` and `get_net` give each net's `diffpair` (partner name, id, and
    whether it is the primary) and its `routed_length_mm`.

  A pair is refused when either net is already paired with a third, as Horizon
  refuses it; clearing first is explicit. Retiring or merging away one net of a
  pair leaves no `diffpair` naming it, as Horizon's next save would.
- **Drawing.** The schematic draws a pair's wires, junctions and labels in the
  Diff Pair colour, its wires 0.2 mm wide, as Horizon's canvas does
  (Canvas::render). Horizon's highlight does not reach the partner, and neither
  does Horizontal's.

### Measurements

- **The track HUD** (ImpBoard::get_hud_text), under the inspector's Tracks
  heading: the layers and **total length** of the selected tracks, the
  **spacing** between two parallel ones (centreline to centreline, Horizon's
  number) with the **gap** copper to copper, which is what a diff pair rule's
  track gap is; for tracks all on one net its **net length**, and for a net in
  a pair its **pair skew** against the partner.
- **Exact lengths.** `HorizontalTrackLength` measures an arc along its circle,
  radius times sweep, as Track::get_length does. The drawing's 48-chord
  polyline falls short of an arc, by a part in twenty thousand on a quarter
  circle and one in five thousand on a half, which is noise on screen and a
  whole tolerance on a length match.
- **The Length Tuning window** (Horizon's TuningWindow): Measure and Measure
  All (the inspector's buttons, and Design ▸ Measure Tracks / Measure All
  Tracks) add a row per net with the selected tracks, or with every track on
  the net. Each row has its All Tracks switch, a Ref to make it the reference,
  and its length as a bar, millimetres and picoseconds at the velocity factor
  (or εr, vf = 1/√εr), with its difference from the reference in time and in
  length. The list lives as long as the document is open, as Horizon's does,
  and follows the board as it changes. The reference length
  (`HorizontalLengthTuningModel.referenceLength`) is the target the tuning
  tools below take, as Horizon's tune tools ask its window for it.

### The diffpair rule

`HorizontalBoardRules.diffpair(net:layer:)` reads it: the first enabled rule
by order whose net class is the pair's, its primary's for either net, and
whose layer is the route's or any (`HorizontalRuleDiffpair`: track width, track
gap, via gap). While a net in a pair is routed, the route inspector's Diff Pair
section shows the partner, the rule and its numbers, and the gap the pair will
route at: the rule's, or the copper clearance between the two nets where that
is wider, with a warning, since the rules check holds the two nets to it. The
coupled router below is what will route by it; the track tool still routes one
track at a time.

### Meander tuning (single track)

Steps 2 to 4 of the order below are built: `HorizontalMeander` (the cells,
their pieces and the sizing, pure geometry), `HorizontalMeanderTuner` (each
slot's room on a board, laying the meander, the exact check), and the tune
tool on the board canvas (`BoardTuneState`), with its settings and readout in
the route inspector. What follows in this document describes each as built;
where the build departed from the first draft of the design, it says so and
why. On Board B (`HorizontalMeanderTunerTests`), sixteen straight tracks of
four millimetres or more, its pairs' first, each asked for a millimetre more:
eleven had room and all eleven reached it, nothing they laid broke a clearance
rule on the exact shapes, and the slowest tune took 50 to 60 ms in a debug build.

## The licensing constraint comes first

The same constraint as the shove router, for the same reason. Horizon's tune
and diff-pair tools are PNS's meander placer and diff-pair placer, GPLv3. Do
not read them, or Horizon's glue to them, to write these. Everything below is
built from geometry, from the published signal-integrity literature, and from
watching what Horizon *produces* on a board, which is output, not source:
routing a pair in Horizon and measuring the copper it lays is fair; reading how
it decided is not.

Background that is safe to read: Johnson and Graham, *High-Speed Digital
Design* (1993) and *High-Speed Signal Propagation* (2003), on serpentine delay
and why adjacent legs couple; Bogatin, *Signal and Power Integrity — Simplified*,
on differential pairs, skew and mode conversion; and the length-matching routing
literature (Ozdal and Wong, "A length-matching routing algorithm for
high-performance printed circuit boards", IEEE TCAD 2006; Yan and Wong,
"BSG-Route", ICCAD 2008), which treats tuning as a routing problem in its own
right. They describe ideas; none is an implementation to translate.

The test from the router study applies: a constant you can't derive is a
constant you copied.

## What it has to mean

The router's bar, with two of its own (the second and the fourth):

1. **It never produces a rules violation**, checked by the same exact-shape
   clearance check the rules window runs (`HorizontalBoardClearanceCheck`).
2. **It hits the target to a stated tolerance or says by how much it missed.**
   A tuner that silently falls short is as bad as one that overshoots.
3. **It is deterministic**, so two runs on one board give the same copper.
4. **Its lengths are the window's lengths.** The tuner measures with
   `HorizontalTrackLength`, so what it reports reaching is what the window
   then shows.
5. **One undo** takes the whole tune back.

## Meander tuning: one track

### The pattern

A meander replaces a straight run of a track — the *baseline*, between two
points on it — with a chain of *cells*. In the baseline's frame (u along it,
v across), a cell is a bump: up a leg of height A (the amplitude, centreline to
centreline from the baseline), across a join of length s (the spacing, leg
centre to leg centre), down a leg of A. Cells sit a spacing apart, so the
period along the baseline is 2s. A *trombone* puts every cell on one side; a
*serpentine* alternates sides. Both add the same length per cell.

With square corners a cell turns a baseline length of s into 2A + s, adding
2A. Horizontal routes at 45°, so each of a cell's four corners is either a
chamfer or an arc:

- **45° chamfer** of size c (c cut from each leg it joins): two lengths c become
  one of c√2, losing (2 − √2)c ≈ 0.586c a corner.
- **Arc** of radius r: two lengths r become a quarter circle πr/2, losing
  (2 − π/2)r ≈ 0.429r a corner. r = s/2 makes the join a semicircle.

So a cell adds

    e(A) = 2A − 4k,   k = (2 − √2)c  or  (2 − π/2)r,

and fits when c (or r) ≤ s/2 and ≤ A/2. Every number is from the geometry;
nothing here is tuned.

### What bounds the cell

- **Spacing.** Two legs of one net are the same copper to the clearance rules
  (same-net is zero in `HorizontalRouterClearances`; Horizon's same-net rule,
  `clearance_same_net`, holds pads, vias and holes of a net apart, not a
  track's own runs), so nothing checks how close a meander's legs are. The
  generator holds it by construction: the gap between legs, s − w for a track
  of width w, is a setting with a floor of w. The signal-integrity texts above
  explain why it should be wider — adjacent legs couple, and a pulse takes the
  shortcut across them, so a tight serpentine adds less delay than its length
  says. The setting's default should be 3w. The window's delay is the copper's
  length over the velocity, which a tight serpentine beats: it measures copper,
  not coupling.
- **Amplitude.** A setting, Amax, and the room the board leaves (below).
- **Margins.** The cells stay a spacing and a corner, m = s + c (or s + r), from the ends
  of the track, where it meets a corner, a via or a pad, and within the
  stretch the tool gives them.
- **Cells that fit.** N cells need (2N − 1)s of baseline, plus the margins.

### Sizing

With ΔL = target − length (from the window's reference, or a typed target),
nothing is done within the tolerance (1 µm by default). Otherwise, as built
(`HorizontalMeander.plan`):

1. **Lattice.** The track runs in one of the eight directions, and everything
   is laid out in its steps: one nanometre on an axis, √2 nm on a diagonal,
   where a step is (1, 1). Every vertex and every arc centre is then a whole
   point, and a chamfer runs in one of the eight directions too. A track at
   another angle, or an arc, takes no tune.
2. **Slots.** Starting where the tune starts and running towards the cursor,
   cell positions two spacings apart, within the margins.
3. **The fewest cells.** Each slot's room (below) caps its amplitude, Amax at
   most; the cells are the fewest, in order from the start, whose capped
   amplitudes reach ΔL. A slot whose room is less than Amin, the track's width
   or two corners, takes none.
4. **One amplitude.** All of them at the largest common amplitude that stays
   within ΔL, found by bisection in steps, each held to its own cap; then one
   step more on as many cells as bring the length nearer, two steps of length
   each. The residual is at most a step: a nanometre on an axis.
5. **Corners.** An arc's radius is half the spacing, which rounds a join and
   the gap between cells into half circles, a chamfer a quarter of it. A ΔL too
   short for one cell with them (a cell is at least two corners tall) is tried
   with smaller corners, halving down to square.
6. **Short.** If the stretch can't hold enough cells, the plan is as much as
   fits and the result says how much is missing. The tool shows that before
   the click that lays it: a click lays what the preview shows, short or not.

The length reached is measured from the pieces (`HorizontalTrackLength`, arcs
along their circles), not taken from the formula, and the tests check the two
agree.

### Clearance: shrinking where blocked

Each cell is tested against the router world (`HorizontalRouterWorld`,
`HorizontalRouterIndex`), each obstacle grown by its clearance and half the
track's width. A cell that collides is shrunk.

The draft took the clearances the track tool routes with, routing offset
included. As built they are the rules' own, with no offset: a tune edits a
track already there, and a track may legally pass copper within the offset, in
which case the offset would refuse every cell on both sides of it. Copper of
the track's own net is kept out of too, at no clearance, so a meander never
folds onto its own pads or tracks, which would short its added length out; the
track itself is the one exception.

Shrinking needs care, because collision is **not monotone in amplitude**: an
obstacle that sits between a tall cell's legs, clear of them, is cut by the
join of a shorter cell. Bisection on A would be wrong. Two sound ways:

- **The swept box.** Test the rectangle the cell covers, baseline to A, legs
  included, against the obstacles, instead of the copper. A shorter cell's box
  is inside a taller one's, so this is monotone and bisection over integer
  nanometres is exact. It refuses a cell that would have threaded round an
  obstacle, which is the right way to be wrong.
- **Candidate amplitudes.** The amplitudes where the join starts and stops
  touching an obstacle are the obstacle hull's extents across the baseline, in
  closed form from its octagon (the same idea as `nearestClearPoint`'s face
  feet). Test those, largest first.

The swept box is what is built. Its rectangle runs along the baseline from a
corner before the first leg to a corner after the second, and across from one
step off the baseline to the join: copper on the far side of the baseline
clears the track already, at exactly its clearance, and a box that started on
the baseline itself would touch it. Then:

- Each slot's room is found once per tune gesture and kept, since the slots
  don't move along the track as the cursor does; the plan takes them as caps,
  so no repeated pass is needed: a slot below Amin is simply not used, and the
  common amplitude rises on the others.
- A one-sided tune takes the cursor's side for each slot, and the other side
  for one that has more room there. A serpentine alternates from the cursor's
  side and drops a blocked slot rather than break the alternation.
- What is laid is checked once more with `HorizontalBoardClearanceCheck` on the
  exact shapes, over the copper within 5 mm of the new tracks, planes left out,
  since a pour is redone round new copper and its old fill isn't an obstacle.
  A tune that fails it isn't laid, and the tool says what it would have broken;
  that would be a bug in the boxes, and the tests have a negative control that
  finds cells forced into a wall.

### The tool

As built (Design ▸ Tune Track, or the board rail's Tune track button):

- A click within six points of a straight track on a net starts the tune there,
  at the click's place on the track. The cursor's place along the track ends
  the stretch the cells may take, and its side of the track is the side they
  grow on. The board draws with the meander laid as it would be, under ids
  that stay the same from one frame to the next.
- The target is the Length Tuning window's reference, or a length typed with
  Return (0 takes the reference again) or in the inspector; the net's length
  is every track on it, as the window's All Tracks measures it. A track on no
  net is measured alone.
- The route inspector, in the sidebar while the tool is in use, has the
  meander's style (one side or serpentine), corners (45° or arc), amplitude and
  spacing, the target and where it comes from, and the readout: the net, its
  length now, the tuned length, the cells and how many slots were blocked, and
  what the tune does or why it doesn't.
- A second click lays it as one undo step: the track replaced by the chain of
  tracks and junctions, each the track's width, layer and net, its width from
  the rules if the original's was (`widthFromRules`), an arc stored from the end
  that makes it the minor arc, as Horizon stores one. The tool stays, for the
  next track; Esc drops a tune under way and a second Esc ends the tool.
- Not built: retuning (a meander is ordinary copper; finding its cells again
  means walking the chain between the baseline's ends, as `BoardTrackLoops`
  walks such chains), a baseline across corners, and the iPad's own controls
  beyond the rail button and the inspector.

## Meander tuning: a pair

### Length

A pair is meandered as one: the centreline is the cell chain above, for a
"track" of width W = 2w + g (track width w and gap g from the diffpair rule),
and the two members are its offsets at ±(w + g)/2. The spacing's floor is W
plus the leg gap.

Corners are where a pair loses its match. Two parallel tracks a distance
D = w + g apart, turning through θ, come out with the outer one longer by Dθ
for concentric arcs, and by 2D·tan(θ/2) for mitred bends — 0.828D for a 45°
bend. But a cell turns as far left as right (two right angles each way), so the
corners' skew cancels within a cell, exactly for arcs and for equal chamfers.
Meandering a pair adds the same length to both members, and tunes the pair's
length without touching its skew. That is the property to test first.

### Skew

Skew is tuned on the shorter member alone, with small bumps away from its
partner, in the pair's own corridor: the pair separates locally, so the bumps
are kept small and few (amplitude a setting, a few gaps at most). The literature
advises compensating a mismatch near where it arises; for a pair that is
usually the uncoupled entry at one end, so the skew tool places its bumps on
the straight nearest the end whose uncoupled lengths differ. The target is zero
skew within a tolerance, read in length and, at the window's velocity factor,
in time. The HUD's pair skew and the window's two rows are the readouts it
works against.

## Coupled differential-pair routing

### The rule

The diffpair rule taking a pair is the first enabled one, by order, whose net
class is the primary's and whose layer is the route's or any layer, as every
other Horizon rule matches. That is a reading of the rule's fields, not of the
router; confirm it against what Horizon lays. Two numbers come from elsewhere:

- **The gap is at least the clearance.** P and N are different nets, so the
  copper clearance between them applies to the pair's own gap, and the rules
  check flags a gap below it. The router routes at max(gap, clearance(P, N)) on
  the layer, and the route inspector says so when the rule's gap is the smaller.
- **Via gap.** Read as the gap between the two vias' copper, edge to edge, as
  the track gap is between the tracks'. Confirm it by placing a via pair in
  Horizon and measuring.

### The centreline is a fat track

Route the pair's centreline with the router as it stands, as one track of width
W = 2w + g. Obstacles are inflated by W/2 plus the clearance — the larger of the
two members' clearances to each obstacle's net — and `HorizontalRouteGridSearch`,
`HorizontalRouteFinder.approach` and the taut-pulling pass work unchanged.

This is conservative, not approximate, and the octagons are why. A member is
the centreline offset by D/2, with copper w/2 round it. At a 45° bend the outer
member's mitre vertex lies D/2·sec(22.5°) out along the bisector, which is
exactly an octagon vertex direction: the vertex is on the boundary of the
centreline's octagon of apothem D/2, its copper within that octagon plus one of
apothem w/2, and octagons' apothems add. So both members' copper is inside the
centreline's octagonal hull at W/2 everywhere, and a fat route clear of
everything gives two member routes clear of everything.

### Members from the centreline, in integer nanometres

The members are the centreline's offsets, and their coordinates must be whole
nanometres, as the writer needs (a decimal Horizon can't read). On an
axis-aligned segment the offset is D/2 in one coordinate, a half when D is
odd; the members then sit at ⌊D/2⌋ and ⌈D/2⌉, still D apart. On a diagonal it
is (D/2)/√2 in both coordinates, never whole; each member takes a whole number
per coordinate, the two together rounded *up*, so the gap never falls below
the rule (by under a nanometre), and the centreline's hull takes a nanometre
more, so the containment above still holds. A member's vertex is the meeting
of its two offset lines, and that is a whole point: an axis line meets a
diagonal at whole coordinates, and two diagonals offset from a whole vertex by
whole amounts meet where their intercepts differ by an even number. So the
members are exact 45° paths. Check that the inner member's chamfers keep a
positive length: a bend tighter than the pair's width leaves none, and the
centreline must then take a wider corner.

### Uncoupled entry

A pair starts on two pads seldom at the pair's spacing. The route is three
parts:

1. **Fan-out**: each member from its pad to a *gate* — two points D apart,
   across one of the eight directions — routed singly by the router as it is.
2. **The coupled run** from the start gate's midpoint to the end gate's, as the
   fat centreline above.
3. **Fan-in** to the other pads, as the fan-out.

Gates are candidates on a small grid near each pad pair, in each of the eight
directions; each is costed as its two fan-out routes' lengths plus a penalty on
their difference (the skew the entry makes) and on their uncoupled length, and
the cheapest wins, ties broken by a fixed order. Adjacent pins at about the
pair's pitch, the common case, get a gate straight out from the pads.

### Via pairs

A layer change in the coupled run is two vias side by side, across the pair's
direction, their centres the via diameter plus the via gap apart. Where that is
wider than D the members jog apart to the vias and back, uncoupled for the
jog's length. In the search a layer change is a move like any other, costed as
a via, legal only where the pair's whole footprint is clear on every layer the
vias span — the two via pads and the jog, the same exact test the router makes
for one via.

### What it reports

The route inspector, while the pair is routed: the rule and where it comes
from, the gap used and why, each member's length, the skew, and the uncoupled
length at each end. Recording which side of each obstacle the pair passed, as
the router study recommends for single tracks, costs the same here and matters
more: a pair that must be re-routed should keep its topology.

## Testing

What has to hold, checkable without a golden:

- **Exact length.** A tuned track's length, measured, is within tolerance of the
  target, or the tune says it fell short by the measured amount.
- **No violation.** `HorizontalBoardClearanceCheck` finds nothing new after a
  tune or a pair route, on synthetic boards and on the real one.
- **The pair's gap.** Along every coupled stretch, the members' centres are D
  apart to the nanometre's rounding, and never closer.
- **Skew cancels.** A pair meander changes the pair's skew by no more than the
  rounding, for chamfers and for arcs.
- **Determinism.** The same request twice gives the same copper.
- **Monotone shrink.** A cell's swept box clears at every amplitude below the
  one chosen.

And a real-board harness, as the router has: Board B pairs TX±, RX± and
PPS In± already, so it is the board to tune and route on, with the input board
fingerprinted so an edit to it can't pass for a regression.

The single-track tune has the first, second, fourth and fifth of these
(`HorizontalMeanderTests`, `HorizontalMeanderTunerTests`): lengths to a step
across a sweep of targets on axis, diagonal and vertical baselines, with both
corners; the exact check on every laid tune, with a negative control; the same
plan twice; boxes clear by construction, bisected only where monotone; and
Board B, read from its path, not yet fingerprinted.

## Suggested order

1. ~~Pairing, the readouts, the Length Tuning window.~~ **Done.**
2. ~~Read the diffpair rule: `HorizontalBoardRules` gains the lookup above, and
   the route inspector shows it for a net in a pair.~~ **Done.**
3. ~~The cell generator as pure geometry: a baseline, a target, settings in;
   tracks out, exact length measured; property tests on e(A) and the corners.~~
   **Done** — `HorizontalMeander`, `HorizontalMeanderTests`.
4. ~~Clearance-checked placement (the swept box), the tune tool, its preview and
   its commit.~~ **Done** — `HorizontalMeanderTuner`, `BoardTuneState`,
   `HorizontalMeanderTunerTests`, `BoardTuneToolTests`.
5. Pair offsetting in integer nanometres, with its tests, before any routing.
6. The fat-centreline route and the fan-out gates.
7. Via pairs.
8. Pair meanders and the skew tool.

Steps 3 and 4 give single-ended length matching, which is most of what boards
ask for, and need nothing of the router but its index. Steps 5 to 8 lean on the
router as it is; none needs the shove.

## Honest scale

The cell generator is days, the clearance-checked tune a few weeks with its
tests. The coupled router is months, even standing on the existing search: the
gates, the via pairs and the corners of a pair are where the work is, and where
a pair router that mostly works lays boards with skew nobody measured. Ship the
measurements first, which is what this change does, so every later step has a
readout to be tested against.
