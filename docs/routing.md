# Routing inspection, planning and editing

These tools generalize the MIT-licensed inspection, geometry-editing and audit
code from Quilter's PCB routing test. Upstream notices are retained in
[`LICENSES/Quilter-MIT.txt`](../LICENSES/Quilter-MIT.txt). Native design files and
board-specific engineering references are not imported.

Reconnect the Altium MCP server after updating to discover the new tool names.
Use the matching `Altium_API.PrjScr`; it now includes `pcb_routing.pas`. Reconnect
all clients using the old file transport before using concurrent clients.

## Tool reference

| Tool | Behavior |
| --- | --- |
| `export_pcb_routing_snapshot` | Read the exact current PCB into a new versioned snapshot. |
| `compare_pcb_snapshots` | Compare exact geometry, duplicates, placement, rules, layer stack and polygon definitions. |
| `export_pcb_drc_report` | Run native batch DRC on the exact active PCB and export compact text with a capture receipt. |
| `summarize_pcb_drc` | Parse classic or compact native text into full ledgers and category totals. |
| `compare_pcb_drc` | Compare full occurrences, processed-rule coverage and waived counts. |
| `validate_altium_project` | Review compiled schematic, PCB inventory, designator and native DRC evidence in one read-only report. |
| `get_effective_routing_rules` | Query width/impedance and differential-gap values for exact existing objects. |
| `route_connections` | Maze-route unrouted single-ended connections on selected layers. Reports native differential-pair members separately. |
| `plan_pcb_diff_pair` | Route a native pair through straight sections, paired 45° detours and optional through vias. |
| `measure_pcb_path_lengths` | Measure supported two-pad paths and report skew for native pair members. |
| `plan_pcb_length_match` | Tune shorter nets individually or lengthen both rails of several pairs together. |
| `select_pcb_routing` | Select nets, connections, pads or exact routing objects; optionally zoom. |
| `apply_pcb_routing_batch` | Plan or apply track/via addition, edits, width changes and removal. |
| `set_pcb_polygon_outline` | Plan or apply a named polygon's simple line boundary. |
| `repour_pcb_polygons` | Explicitly request native repour, export another snapshot and compare. |
| `audit_pcb_layer_usage` | Check explicit layer-role and allowed-net policy. |
| `preview_pcb_route_clearance` | Screen straight segments against approximate snapshot geometry. |
| `get_pcb_routing_operation` | Read operation progress and exact reconciliation without replaying. |
| `get_altium_command_status` | Read the command channel's unresolved receipt without invoking Altium. |

The snapshot-based planners and edit tools default to `apply=false`. Use
`dry_run=true` with `route_connections` or `route_path` to preview them.
Applying edits leaves the document dirty. Saving remains a separate `save_current_document` operation
that requires an explicit user save request. Snapshots do not save, repour, select,
or rebuild connectivity. Selection and repour are separate explicit tools.

All generated outputs are stored in the repository's `generated/` directory.
Omit `output_directory` for a unique task directory, or supply a new absolute
directory beneath `generated/`. Existing output directories are refused. Large
ledgers stay in artifacts; MCP responses contain counts and small samples.

## Read-only project validation

`validate_altium_project` requires the full Windows `expected_board` path.
Supply `project_path` for an open `.PrjPcb` with a current compiled schematic.
Altium checks that the PCB belongs to that project before reading the schematic.
Supply `snapshot_directory` to review a sealed snapshot, or activate the exact
PCB for a fresh capture. Supply `drc_report_path` for an English native classic
or compact text DRC report. The optional `baseline_drc_report_path` compares
same-format reports for exact new occurrences, processed rules and waiver counts.

```json
{
  "expected_board": "D:\\Boards\\Example.PcbDoc",
  "project_path": "D:\\Boards\\Example.PrjPcb",
  "drc_report_path": "D:\\Boards\\Example.drc"
}
```

The tool writes `validation.json`, `VALIDATION.md` and the applicable evidence
under `generated/project-validation/`. The MCP response includes the verdict,
stage counts, next actions and report paths. A missing prerequisite skips only
the checks that depend on it. A source error, reported violation or failed DRC
baseline comparison produces a `fail` verdict. Skipped checks or designator
differences produce `incomplete` when there are no failures. The designator check
flags footprinted schematic components missing from the PCB, PCB-only components,
and duplicate or blank designators. Review intentional board-only components and
variant differences in Altium.

The tool reads the current compiled state without compiling, and never runs
ERC or DRC, edits, saves, selects, or repours. Omit `project_path` and provide
`snapshot_directory` for an artifact-only run that does not contact Altium.
A `pass` applies to the supplied evidence. A matching path cannot establish that
DRC reflects the captured revision or covers every applicable rule. Snapshot
connectivity counts are observations from Altium's cache.

The staged checks and report structure are adapted from
[CopperPilot CLI validation](https://github.com/CopperPilot/copper-pilot-cli/blob/1.0.1/docs/validate.md).

## Coordinates and snapshots

`expected_board` is a full Windows `.PcbDoc` path. Activate that exact PCB before
live routing queries. The bridge checks the path of Altium's current PCB.
Mutations, selection and repour also check the focused document view.
Batches recheck this before every row. Successful routing selection
replaces the previous selection, including selected components and other objects.

Coordinates and dimensions with `_raw` suffix are **absolute Altium integer
coordinates**, independent of the user origin. Read `internal_units_per_mil`
from `board.tsv`; `mm = raw / internal_units_per_mil * 0.0254`. Existing component
pin MCP coordinates are user-origin-relative mils and must be converted before
use here. All layer references are actual numeric layer IDs; physical ordering
comes from `layers.tsv`, not numeric sorting or displayed layer names.

A snapshot contains `board`, `nets`, `pads`, `tracks`, `vias`, `connections`,
`rules`, `components`, `layers`, `arcs`, and `polygons` TSV tables, a terminal
completion marker, a native board signature and a SHA-256 manifest. The board
table also stores `outline_raw`, `differential_pairs_json` and, when dielectric
thickness is present between adjacent copper layers, `copper_depths_raw`. New snapshots
require all tables, a matching generation ID, valid counts and unchanged bytes.
Native text fields use ASCII JSON escapes so the on-disk field format has an
explicit codec. Cyrillic/CJK/supplementary-character handling in the installed
Altium scripting host still requires runtime qualification.

The signature excludes selection and cached connectivity flags. Before a live
operation, Altium regenerates its modeled board signature and rejects a stale
baseline. It includes component positions, rule summaries, origin, units, stack,
exported copper, board outline, native pair definitions and available copper center depths. Snapshot
geometry omits full pad stacks, keepout semantics, poured polygon copper and reference continuity. Snapshot
comparisons cannot establish electrical or manufacturing acceptance.

## Automatic routes and signal lengths

`route_connections` uses `area` to select ratsnest connections. Supply
`routing_area` to constrain the actual trace and via copper to a rectangle
in origin-relative mils. The maze router approximates clearance from layout
copper, and board outline, keepouts, pours and scoped rule checks require
native review. Use `route_path` with explicit waypoints when you need to
choose the route and run immediate native object checks.

For differential pairs and length matching, export a fresh snapshot and
choose a corridor with a uniform stack and clear of cutouts, keepouts,
fills, regions and poured copper. The planners check the straight-edged
board perimeter and approximate clearance to pad envelopes, via copper,
tracks and arcs. Through-via planning also screens drill spacing across
the full drill span. The planners return an exact operation list
in `signal-plan.json`; pass `apply=true` to run the guarded batch against the
same snapshot. The result includes the post-apply snapshot directory and
exact reconciliation. Each signal plan uses one native Undo group. If an
apply stops early, the group can contain partial edits. Check the operation
receipt and compare a fresh snapshot before retrying.

- `plan_pcb_diff_pair` takes the native pair name, numeric copper layer ID,
  width and clearance in mm, and a `corridor_raw` rectangle in absolute Altium
  units. It supports unrouted two-pad members with horizontal or vertical
  launches, equal pitch and consistent polarity. At the launch pitch, trace
  width determines the edge gap. Choose one width suitable for all allowed
  layers and set clearance from the board's rules. The planner tests up to
  16 shifts in each direction using `detour_step_mm`.
- To allow layer changes, pass `routing_layer_ids` with up to four physical
  signal layers including `layer_id`, the preferred routing layer. Set
  `via_diameter_mm` and `via_hole_mm` from the routing via rule.
  `hole_clearance_mm` defaults to `clearance_mm`. Each transition puts one
  Top–Bottom through via on each rail at the same longitudinal station.
  The planner widens the via pitch symmetrically when drill or copper
  clearance requires it. It searches stations on flat sections, prefers
  fewer transitions and accepts 0–4 via pairs with `max_layer_changes`
  (default 2).
- Set both `mask_expansion_mm` and `min_mask_sliver_mm` to screen open vias
  against nearby pad and via mask openings. The estimate applies the same
  expansion to each opening and can widen the pair or move a transition.
  Run native DRC to check actual mask rules and per-object settings.
  [Altium minimum solder mask sliver rule](https://www.altium.com/documentation/altium-designer/pcb/design-rule-types/manufacturing).
- `measure_pcb_path_lengths` traces a single unbranched chain of tracks and
  via junctions between two pad centers. Each via must meet two track layers
  at its center. The tool reports planar length, vertical length between
  connected copper centers, total length, and pair skew when both members
  are measured. Native signal length and delay use additional information.
  [Altium differential-pair routing](https://www.altium.com/documentation/altium-designer/pcb/high-speed-design/interactively-routing-differential-pairs).
- `plan_pcb_length_match` accepts either `nets` or native `pairs`. Key
  `corridors_raw` by those names for routes that need added length. Set
  `target_mm` or use the longest measured member as the target. In pair mode,
  the tool adds one coupled 45° excursion to a shared straight section of
  each shorter pair. Both rails gain equal length, preserving their skew.
  In pair mode the tolerance also bounds the length spread across all
  members. The edit preserves vias, track width and pad endpoints. Run measurement
  on the resulting snapshot and check applicable native rules.
  [Altium length tuning and matched-length rules](https://www.altium.com/documentation/altium-designer/pcb/high-speed-design/length-tuning).

For placement, `place_components(require_all=true, board_path=...)` resolves
every designator on the target PCB before the transaction. Verify the returned
positions and call `check_placement` with the same `board_path` to inspect
same-side overlaps and primitive clearance. Native component clearance, board
edge and placement keepout checks are separate.

## Explicit batches

First export a snapshot. Read exact rows from its tables, then pass operations:

```json
[
  {
    "kind": "track",
    "action": "edit",
    "old": {
      "net": "SIGNAL", "x1_raw": 100000, "y1_raw": 200000,
      "x2_raw": 300000, "y2_raw": 200000,
      "width_raw": 40000, "layer_id": 1
    },
    "new": {
      "net": "SIGNAL", "x1_raw": 100000, "y1_raw": 200000,
      "x2_raw": 300000, "y2_raw": 200000,
      "width_raw": 50000, "layer_id": 1
    }
  }
]
```

The numbers are illustrative; use the actual board's records and rules. `add`
omits `old`; `remove` omits `new`. An edit preserves its net. Reversed track
endpoints are equivalent. Repeated targets, duplicate destinations, stale targets,
unknown nets and absent copper layers are rejected. The batch checks the width
rule for a single-ended track and the differential routing rule for a pair
member. Width checks run on attached tracks before advancing to the
next row. A failed width check can leave the attempted row applied.
Inspect the audit and use guarded Undo before retrying.
Width readback does not establish clearance or full DRC acceptance.

Via records contain `net`, `x_raw`, `y_raw`, `size_raw`, `hole_size_raw`,
`low_layer_id`, and `high_layer_id`. New vias currently support the standard
Top–Bottom through span; existing via edits preserve their drill span. Coincident
via centers are refused. Via-in-pad requires explicit `allow_via_in_pad=true`
and the same assigned net. That flag does not establish filled/capped fabrication
support or drill clearances.

The default dry run stages `operations.tsv` and `plan.json` without contacting
Altium. Live apply checks the exact baseline and indexes requested nets
and geometry in the same board pass before preparing candidates. It
checks the exact baseline again immediately before editing. Both checks
read only signature fields. Live apply exports the full post-edit
inventory and reconciles the resulting track and via multisets and
immutable records. Explicit batches
use per-row Undo by default. Set `undo_group=true` to use one Undo step
for the attempted edits. Width checks and progress receipts still run per
row in either mode. Native DRC, return paths, timing and manufacturing
review remain separate checks.

Polygon outline edits preserve an existing polygon's name, net, layer and pour
settings. New polygons use a solid same-net pour definition. Boundaries must be
simple polygons with 3–256 distinct integer vertices; arc boundaries remain
preserved in snapshots but cannot be authored by this outline tool. Repour is
explicit and may change poured copper; inspect its fresh comparison and DRC.
Outline editing does not issue a repour command; Altium's automatic pour settings
can still update copper during native editing. Explicit repour records native
polygon child/region counts before and after in `polygon-copper-before.tsv` and
`polygon-copper-after.tsv`. Counts alone do not establish copper-shape correctness.

## Rule, layer and clearance observations

Rule queries require an exact existing object record plus a requested copper
layer. They expose numeric width and impedance constraints for ordinary width
rules and both width and gap for differential-pair rules.
The selected rule applies to that sampled object's context; it is not necessarily
the winner for another object, room, location or proposed segment on the same net.
The tools do not convert unqualified native delay getters into ps/ns.

Layer roles are supplied explicitly. Example policy:

```json
{
  "policies": [
    {"layer_id": 2, "role": "ground", "allowed_nets": ["GND"]},
    {"layer_id": 5, "role": "power", "allowed_nets": ["VCC"],
     "prohibit_controlled_impedance": true}
  ],
  "controlled_impedance_nets": ["CLOCK"]
}
```

Use actual layer IDs/nets. No electrical role, supply class or controlled-impedance
membership is inferred from names or prefixes. The audit includes line/arc
centerline lengths and polygon definitions; summed lengths include branches and
overlaps and are not endpoint delays. Unreviewed layers are listed explicitly.

Clearance preview uses supplied straight segments and a caller-supplied clearance
in mm. It considers other-net tracks, via outer diameters on the physical layer
span, conservative pad bounding rectangles and conflicts between candidates.
It omits arcs, keepouts, board-edge clearance, poured copper, holes, complete pad
stacks and scoped native clearance rules. Even zero modeled conflicts requires
native DRC; the response never claims electrical acceptance.

## DRC and offline command line

Activate the exact PCB and call `export_pcb_drc_report` with its full
`expected_board` path. The tool runs the PCB's configured batch rules on its
current polygon state and writes `native-drc.txt` and `native-drc.txt.capture.json`
under `generated/native-drc/` by default. It records the PCB editor's modified
state before and after the run. On the English polygon warning the tool chooses
**Run DRC**. If the dialog stays open, choose that option in Altium. Keep the two
export files together so subsequent validation can verify the report hash and
board identity. Batch checks can take several minutes. Inspect
`get_altium_command_status` after a client timeout before retrying.

Pass the exported `.txt` path directly to `validate_altium_project` or
`summarize_pcb_drc`. A standalone compact report uses the caller's PCB
association. Validation marks an otherwise clean standalone report for review.
Native warnings are kept in the report and require review. The compact format
omits waiver counts. Compact baseline comparisons require both capture receipts
and return an inconclusive result when the other comparisons pass and the waiver
counts remain unavailable.

The parser supports the donor's English native `.drc` text format. It validates
each rule subtotal and final totals, preserves duplicate occurrences, and checks
exact report board identity. Redacted relative identities are supported for
offline evidence and are explicitly marked as non-absolute and unverified against
a live board. Reports must already exist; these tools do not execute
batch DRC. Optional comparisons retain full rule/finding strings and reject every
new finding by default, as well as coverage/waiver changes. An explicit rejection
category list changes the new-finding policy without discarding any occurrences.
Changed report text is not proof of a newly created or resolved physical defect.

Outputs include `drc-summary.json`, `drc-all-findings.tsv`, `DRC_APPENDIX.md`, and
`electrical-findings.json`. Electrical values are extracted from native findings
without guessing which of two reported delays belongs to a net. Missing findings
are not complete timing coverage or acceptance.

Offline commands require no Altium connection:

```powershell
python -B tools/pcb_routing.py compare <baseline-snapshot> <current-snapshot>
python -B tools/pcb_routing.py drc <report.drc> --expected-board 'D:\Boards\Board.PcbDoc'
python -B tools/pcb_routing.py layers <snapshot> <policy.json>
python -B tools/pcb_routing.py clearance <snapshot> <segments.json> --clearance-mm 0.15
```

`compare --legacy-tsv` can read original donor inventories without sealing them.
Legacy exports are not permitted as mutation baselines. CLI exit status is 0 for
the selected policy passing, 1 for findings/regressions, and 2 for invalid input.
Specify a fresh absolute `--output-directory` under `generated/`, or omit it.

## Interrupted commands

Expected validation failures return through the command channel without raising
DelphiScript exceptions or opening message dialogs. The runner reports errors
without `ShowMessage`. Unexpected native API/interpreter faults can still pause
Altium's debugger: dismiss the error, open the script editor and choose
**Run → Stop (Ctrl+F3)** before recovery. Closing the dialog alone does not stop
the script. Do not launch another request while the debugger is paused.

Routing commands enter the native procedure dispatcher directly from `Run` and
pass response text through explicit output parameters. This avoids the nested
function return corruption observed during selection in AD 26.11.1. A valid
local JSON value did not guarantee the value received by its function caller;
qualify the complete MCP response as well as the saved native artifacts.

`undo_pcb_routing(snapshot_directory, steps=1, apply=false)` provides guarded
native Undo. Live Undo checks the exact active PCB and baseline, requests a bounded
number of steps, and exports fresh geometry. Compare that output with the intended
pre-edit snapshot to verify restoration; requesting Undo alone is not proof.
No document is saved. Batch, polygon, repour and Undo calls allow up to ten minutes
for native work; their progress remains available through the status tools.

Via-in-pad preflight uses conservative rotated top-pad rectangles and the via
radius, including off-center overlap. Full custom pad stacks remain outside this
approximation; explicit allowance requires the same net, and native DRC is still
required.

The bridge serializes callers within and across server processes. Every command
gets a UUID and a persistent pending receipt. The bridge reads its correlated
reply from `response.json` while holding the shared exchange lock. A
timeout is unknown execution, not a failed no-op. Until a terminal response for
that request appears, later commands cannot overwrite the shared request. Caller
cancellation also keeps the writer lock until the operation reaches a terminal
response or timeout.

Use `get_altium_command_status` and `get_pcb_routing_operation` to inspect progress.
`batch-audit.tsv` records attempted rows; `completed_rows` is not sufficient to
exclude a partially applied next row. Do not replay a request blindly. After a
terminal response, export a fresh snapshot and replan from actual geometry. If a
native script never starts or cannot return a terminal response, first establish
that no script/interactive command is active, inspect the PCB, and have an operator
archive the unresolved exchange receipt before recovering the channel. There is
no automatic abandonment or rollback.

## Optional utilities and validation

Passive WGC screenshots/timelapse and saved-file checkpoints are separate CLI
utilities; see [`tools/optional/README.md`](../tools/optional/README.md). They are
not imported by the MCP server and add no default media dependencies. No desktop
provisioning, publication commands or historical board-repair recipes are imported.

Run offline tests with the project's Python environment. Exclude the older
interactive `test_altium_script.py`, which requires an operator and live Altium.
The new routing tests never call Altium. Optional capture tests mock native frame
capture and exercise actual local video encoding when the extras are installed.
Read-only existing-tool verification is distinct from qualifying new mutation,
Undo, repour, prospective-rule and encoding behavior on a disposable PCB copy.
