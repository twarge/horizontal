---
name: review
description: Review a board, schematic or circuit in the Horizontal app or a Horizon EDA project. Use for requests such as "review my board in Horizontal", hardware design audits, sanity checks, finding circuit or layout problems, or comparing parts, values and topologies with numbers.
---

# Review a design

A useful review traces what the circuit is meant to do, checks it against the datasheets, and puts numbers on every finding. Read the model, not exports: schematic PDFs, BOMs and Gerbers in the repository are often older than the project files.

## 1. Load the design

1. Connect first (the `connect` skill). Prefer `source: "live"` when the user has the project open, so you see unsaved work. Note `diagnostics`, `warnings` and `unsaved_changes` from `open_project`.
2. Map the design:
   - `list_sheets`, then `render_sheet` for each sheet at about 90 dpi to see the whole page. Use `region` crops at about 200 dpi to read detail.
   - `list_components` with `fields`, and `get_component` for parts that matter: pins and nets, symbol positions, board placement and side, part details.
   - `bom` (with `include_no_populate`) and `netlist`; use `get_net` for one net.
   - Note do-not-populate parts, parts on the bottom side, parts without a part, and sheet text notes. These carry design intent ("255 Hz low pass", "5 V adjusted to 9 V").
3. Run `check` with `full: true` as a baseline. Horizontal has no geometric design rule check: `check` covers load diagnostics, rules, annotation, connectivity, unplaced packages and unrouted connections, not clearances.
4. Look in the repository for simulations, design notes and older exports, and use `git log` to date them against the project files.

## 2. Establish intent, then verify

For each functional block, say in one line what you believe it does: the signal chain, the ranges and the load. Ask the user what you cannot infer — load parameters, the maximum current or voltage, the stability or noise target and its frequency band, and whether outputs may float.

Check behaviour against datasheets, not memory. Ask the user for the datasheets you need, with the specific questions each should answer. Read pinouts before judging unusual connections: a shutdown pin tied to a rail, or a heater ground on a negative supply, may be exactly what the datasheet prescribes. When a datasheet contradicts a finding, withdraw it explicitly.

## 3. What to check

**Power**
- Regulator headroom against dropout at maximum load, including cable drop.
- Dissipation and thermal path, using the datasheet's θJA conditions.
- Enable, power-good and soft-start pins.
- Supply minimums of what each rail feeds; a part may disable a function below a threshold.
- Bypass capacitors at the pins the datasheet names, including level-shifted grounds.

**Precision analog**
- Offset, drift and noise budgets with every contributor listed.
- Resistor matching and TCR tracking in ratio-critical networks, and self-heating of resistors that carry signal current.
- Kelvin sense connections, and current flowing in sense leads.
- Capacitor leakage in RC filters: the fractional error is τ_RC / τ_insulation.
- Dielectric absorption, which shows up as slow settling.
- Op amp bias current into source impedance; input and output ranges on the actual rails.

**Feedback loops**
- Phase margin with the real load: inductive, capacitive, or switched by relays.
- Compensation pins and recommended values.
- Integrator windup and behaviour when the load opens.

**Protection and switching**
- Inductive kickback and clamp polarity for bipolar signals.
- Relay switching under load.
- Leakage of anything shunting a precision node.

**Mixed signal**
- Isolation barrier integrity and spare channels.
- Ground return paths of large currents relative to precision references.

**Layout**
- Thermal coupling from hot parts to references and matched networks.
- Copper left after footprint changes, such as exposed-pad vias under a part without a pad.

Use `highlight`, `select` and `zoom_to` to show the user the parts and nets you mean in the app.

## 4. Quantify

Write small scripts for loop gain and phase margin, noise and drift budgets, and settling, rather than estimating by eye. State each assumption and which datasheet value it rests on. Compare alternatives side by side over the band the user cares about. A part that wins at DC can lose at 10–100 Hz: chopper amplifiers' white noise exceeds bipolar parts' above their 1/f corner.

## 5. Report

- Restate the signal chain as you understood it, so the user can correct it.
- Give findings ranked high, medium and low. Each names the evidence (refdes, net, pin), the consequence with numbers, and a fix.
- Keep "confirm with datasheet" items separate from confirmed ones.
- List the datasheets you still need and the questions about intent.
- Do not change the design in a review unless asked. Edits follow the `edit` skill.
