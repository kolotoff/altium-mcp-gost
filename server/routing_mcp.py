"""MCP surface for routing; optional capture and checkpoint tools stay separate."""

import asyncio
import json
from pathlib import Path

from mcp.server.fastmcp import Context

from .native_drc import continue_polygon_warning
from .routing_audit import read_snapshot
from .signal_routing import measure_paths
from .pcb_routing import (
    RoutingService,
    compare_snapshot_artifacts,
    operation_status,
    snapshot_observations,
    summarize_drc_artifacts,
)


def register_routing_tools(register_tool, bridge):
    service = RoutingService(
        lambda command, params: bridge.execute_command(command, params),
        lambda directory: continue_polygon_warning(directory, bridge.config.altium_exe_path),
    )
    exported = {}

    def tool(read_only=False):
        def register(function):
            exported[function.__name__] = function
            return register_tool(read_only=read_only)(function)
        return register

    def encode(value):
        return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)

    @tool(read_only=True)
    async def export_pcb_routing_snapshot(
        ctx: Context, expected_board: str, output_directory: str = ""
    ) -> str:
        """Read the exact current .PcbDoc into a versioned snapshot under generated/.

        Includes raw-unit pads, tracks, vias, connections, rules, components,
        copper stack, arcs and polygon boundaries. No save, repour or selection.
        Returns compact counts and paths; cached connectivity is not acceptance.
        """
        return encode(await service.snapshot(expected_board, output_directory))

    @tool(read_only=True)
    async def compare_pcb_snapshots(
        ctx: Context,
        baseline_directory: str,
        current_directory: str,
        allowed_nets: list = [],
        allow_removals: bool = False,
        allow_placement_changes: bool = False,
        allow_rule_changes: bool = False,
        allow_polygon_changes: bool = False,
        output_directory: str = "",
    ) -> str:
        """Compare complete snapshots exactly, preserving duplicate primitives.

        Empty allowed_nets means all nets. Explicit policies permit intended
        changes; no successful comparison establishes electrical acceptance.
        """
        return encode(
            await asyncio.to_thread(
                compare_snapshot_artifacts,
                baseline_directory,
                current_directory,
                output_directory,
                allowed_nets=allowed_nets or None,
                allow_removals=allow_removals,
                allow_placement_changes=allow_placement_changes,
                allow_rule_changes=allow_rule_changes,
                allow_polygon_changes=allow_polygon_changes,
            )
        )

    @tool(read_only=True)
    async def export_pcb_drc_report(
        ctx: Context, expected_board: str, output_directory: str = ""
    ) -> str:
        """Run Altium batch DRC on the exact active PCB and export its compact text.

        Uses the board's configured batch rules and its current polygon state.
        Continues the English polygon warning with Run DRC. If the dialog stays
        open, choose Run DRC in Altium. Never repours, changes rules or saves.
        Keep the .txt and adjacent .capture.json together for board verification.
        """
        return encode(await service.export_drc(expected_board, output_directory))

    @tool(read_only=True)
    async def summarize_pcb_drc(
        ctx: Context,
        report_path: str,
        expected_board: str,
        baseline_report_path: str = "",
        output_directory: str = "",
    ) -> str:
        """Parse classic or compact English native DRC text and verify its totals.

        Writes full ledgers plus timing/coupling observations. Optional baseline
        comparison rejects every new occurrence, coverage or waiver change.
        Does not run native DRC or save a design.
        """
        return encode(
            await asyncio.to_thread(
                summarize_drc_artifacts,
                report_path,
                expected_board,
                baseline_report_path,
                output_directory,
            )
        )

    @tool(read_only=True)
    async def get_effective_routing_rules(
        ctx: Context, snapshot_directory: str, objects: list, output_directory: str = ""
    ) -> str:
        """Read dominant width/impedance and pair-gap rules for exact existing objects.

        objects: [{kind: track|via|pad, net: exact_name, record: snapshot_row,
        layer_id: actual_copper_layer}]. A sampled object's rule is not a rule
        for an entire net or qualified prospective geometry.
        """
        return encode(
            await service.selectors(
                "rules", snapshot_directory, objects, output_directory
            )
        )

    @tool()
    async def select_pcb_routing(
        ctx: Context,
        snapshot_directory: str,
        selectors: list,
        zoom: bool = False,
        output_directory: str = "",
    ) -> str:
        """Select nets, connections or exact primitive records on the bound PCB.

        selectors: [{kind: all|connection|pad|track|via|arc|polygon, net: name,
        record: optional_exact_snapshot_row}]. Unmatched requests preserve selection.
        Changes UI selection only; does not save.
        """
        return encode(
            await service.selectors(
                "select", snapshot_directory, selectors, output_directory, zoom
            )
        )

    @tool()
    async def apply_pcb_routing_batch(
        ctx: Context,
        snapshot_directory: str,
        operations: list,
        apply: bool = False,
        output_directory: str = "",
        allow_via_in_pad: bool = False,
        undo_group: bool = False,
    ) -> str:
        """Plan or apply exact track/via add/edit/remove operations, leaving edits dirty.

        operations: [{kind: track|via, action: add|edit|remove, old: exact_record,
        new: desired_record}]. Omit old for add and new for remove. Width changes
        are track edits. Coordinates/dimensions are absolute native integers from
        the snapshot, NOT user-origin mils. New vias are Top-Bottom through vias.
        Default is dry run. Live apply checks the whole baseline, records partial
        progress and reconciles exact readback. By default each row has an Undo
        step. Set undo_group=true for one Undo step covering attempted edits.
        The group can contain partial edits if the apply stops early.
        On timeout inspect get_pcb_routing_operation before any retry. Native DRC
        remains required; this tool never saves.
        """
        return encode(
            await service.batch(
                snapshot_directory,
                operations,
                apply,
                output_directory,
                allow_via_in_pad,
                undo_group,
            )
        )

    @tool()
    async def set_pcb_polygon_outline(
        ctx: Context,
        snapshot_directory: str,
        name: str,
        net: str,
        layer_id: int,
        vertices_raw: list,
        apply: bool = False,
        output_directory: str = "",
    ) -> str:
        """Plan/create/edit a named polygon with an explicit simple line boundary.

        vertices_raw is [[x,y],...] in absolute native units. Existing polygons
        retain net, layer and pour settings; new polygons use solid same-net pour.
        Default dry run. Does not issue an explicit repour or save; native DRC
        remains required. Altium's automatic pour settings can update copper.
        """
        return encode(
            await service.polygon(
                snapshot_directory,
                name,
                net,
                layer_id,
                vertices_raw,
                apply,
                output_directory,
            )
        )

    @tool(read_only=True)
    async def audit_pcb_layer_usage(
        ctx: Context,
        snapshot_directory: str,
        policies: list,
        controlled_impedance_nets: list = [],
        output_directory: str = "",
    ) -> str:
        """Audit copper against explicit layer roles and allowed nets.

        policies: [{layer_id, role: signal|ground|power|mixed, allowed_nets: [...],
        prohibit_controlled_impedance: false}]. Dedicated ground/power roles need
        allowed_nets. No roles, supplies or impedance classes are guessed by name.
        """
        return encode(
            await asyncio.to_thread(
                snapshot_observations,
                "layers",
                snapshot_directory,
                output_directory,
                policies=policies,
                controlled_impedance_nets=controlled_impedance_nets,
            )
        )

    @tool(read_only=True)
    async def compare_pcb_drc(
        ctx: Context,
        baseline_report_path: str,
        current_report_path: str,
        expected_board: str,
        reject_categories: list = [],
        output_directory: str = "",
    ) -> str:
        """Compare exact native DRC occurrences, rule coverage and waiver counts.

        Default rejects every new category. An explicit nonempty category list
        changes the acceptance policy while preserving all findings in the ledger.
        Category names use the summary labels, e.g. Delay or Matched Lengths.
        """
        return encode(
            await asyncio.to_thread(
                summarize_drc_artifacts,
                current_report_path,
                expected_board,
                baseline_report_path,
                output_directory,
                reject_categories or None,
            )
        )

    @tool()
    async def repour_pcb_polygons(
        ctx: Context,
        snapshot_directory: str,
        apply: bool = False,
        output_directory: str = "",
    ) -> str:
        """Explicitly request native polygon repour and export a fresh snapshot.

        Default dry run. Requires the exact PCB to be active and unchanged from
        the snapshot. Repour changes copper; inspect the comparison and run native
        DRC. This tool never saves and is separate from read-only inventory.
        """
        return encode(await service.repour(snapshot_directory, apply, output_directory))

    @tool()
    async def undo_pcb_routing(
        ctx: Context,
        snapshot_directory: str,
        steps: int = 1,
        apply: bool = False,
        output_directory: str = "",
    ) -> str:
        """Request 1-256 native Undo steps on the exact active snapshot-bound PCB.

        Default dry run. Checks the current baseline before touching the Undo
        stack. Exports actual geometry afterwards; compare with the intended
        pre-edit snapshot to prove restoration. Never saves or changes boards.
        """
        return encode(
            await service.undo(snapshot_directory, steps, apply, output_directory)
        )

    @tool(read_only=True)
    async def preview_pcb_route_clearance(
        ctx: Context,
        snapshot_directory: str,
        segments: list,
        clearance_mm: float,
        output_directory: str = "",
    ) -> str:
        """Approximate candidate straight-segment clearance against a snapshot.

        segments: [{net,layer_id,x1_raw,y1_raw,x2_raw,y2_raw,width_raw}]. Clearance
        is caller supplied in mm. Uses pad bounding rectangles and via diameters;
        omits arcs, keepouts, poured copper, board edges and full pad stacks.
        Candidate screening only, never native DRC/electrical acceptance.
        """
        return encode(
            await asyncio.to_thread(
                snapshot_observations,
                "clearance",
                snapshot_directory,
                output_directory,
                segments=segments,
                clearance_mm=clearance_mm,
            )
        )

    @tool(read_only=True)
    async def measure_pcb_path_lengths(ctx: Context, snapshot_directory: str, nets: list) -> str:
        """Measure routed lengths in mm and report skew for native pairs among the requested nets.

        Accepts up to 32 exact net names. Each measured net must be a single
        unbranched track-and-via chain between two pad centers. Reports
        planar track and vertical via lengths separately, and unsupported
        topology per net. Multilayer paths require a fresh stack snapshot.
        """
        try:
            snapshot = await asyncio.to_thread(read_snapshot, Path(snapshot_directory))
            return encode({"success": True, **await asyncio.to_thread(measure_paths, snapshot, nets)})
        except (ValueError, OSError) as error:
            return encode({"success": False, "error": str(error)})

    @tool()
    async def plan_pcb_diff_pair(
        ctx: Context, snapshot_directory: str, pair: str, layer_id: int,
        width_mm: float, clearance_mm: float, corridor_raw: list,
        detour_step_mm: float = 0.25, edge_clearance_mm: float = 0.25,
        apply: bool = False, output_directory: str = "",
        routing_layer_ids: list | None = None, via_diameter_mm: float | None = None,
        via_hole_mm: float | None = None, hole_clearance_mm: float | None = None,
        max_layer_changes: int = 2, mask_expansion_mm: float | None = None,
        min_mask_sliver_mm: float | None = None,
    ) -> str:
        """Plan both rails of a native differential pair, with optional paired through vias.

        Two unrouted two-pad nets with aligned horizontal or vertical launches
        of equal pitch and matching polarity. Tests the straight path
        and paired 45-degree detours inside corridor_raw [x1,y1,x2,y2] in
        absolute Altium units. With routing_layer_ids including layer_id, supply
        via_diameter_mm and via_hole_mm. The planner may place a paired
        Top–Bottom through via at each transition and widen the via pitch
        symmetrically. hole_clearance_mm defaults to clearance_mm.
        Supply both mask_expansion_mm and min_mask_sliver_mm to also screen
        via sites against nearby pad/via mask openings under a uniform expansion.
        Choose a corridor clear of keepouts, cutouts, fills, regions and pours.
        Default dry run. Apply uses the guarded batch and leaves the PCB dirty.
        """
        try:
            return encode(await service.signal_plan(
                "pair", snapshot_directory, apply, output_directory, pair=pair, layer_id=layer_id,
                width_mm=width_mm, clearance_mm=clearance_mm, corridor_raw=corridor_raw,
                detour_step_mm=detour_step_mm, edge_clearance_mm=edge_clearance_mm,
                routing_layer_ids=routing_layer_ids, via_diameter_mm=via_diameter_mm,
                via_hole_mm=via_hole_mm, hole_clearance_mm=hole_clearance_mm,
                max_layer_changes=max_layer_changes, mask_expansion_mm=mask_expansion_mm,
                min_mask_sliver_mm=min_mask_sliver_mm,
            ))
        except (ValueError, OSError) as error:
            return encode({"success": False, "error": str(error)})

    @tool()
    async def plan_pcb_length_match(
        ctx: Context, snapshot_directory: str, corridors_raw: dict,
        tolerance_mm: float, clearance_mm: float, target_mm: float | None = None,
        edge_clearance_mm: float = 0.25, apply: bool = False, output_directory: str = "",
        nets: list | None = None, pairs: list | None = None,
    ) -> str:
        """Plan length matching for up to 32 two-pad track-and-via routes.

        Supply nets for individual tuning or pairs for coupled tuning by native
        pair name. Supply a corridor [x1,y1,x2,y2] in absolute Altium units for
        each net or pair that needs added length, clear of keepouts, cutouts,
        fills, regions and pours. Default target is the longest member's
        measured length including traversed via height. Paired tuning adds
        equal length to both rails and preserves their existing skew and vias.
        Tolerance is absolute around target in mm and also bounds the total
        spread across the members in pair mode.
        Default dry run. Apply uses the guarded batch and leaves the PCB dirty.
        """
        try:
            return encode(await service.signal_plan(
                "length-match", snapshot_directory, apply, output_directory, nets=nets,
                corridors_raw=corridors_raw, tolerance_mm=tolerance_mm, clearance_mm=clearance_mm,
                target_mm=target_mm, edge_clearance_mm=edge_clearance_mm, pairs=pairs,
            ))
        except (ValueError, OSError) as error:
            return encode({"success": False, "error": str(error)})

    @tool(read_only=True)
    async def get_pcb_routing_operation(ctx: Context, operation_directory: str) -> str:
        """Inspect saved progress/reconciliation after interruption; never replays edits."""
        return encode(await asyncio.to_thread(operation_status, operation_directory))

    @tool(read_only=True)
    async def get_altium_command_status(ctx: Context) -> str:
        """Inspect the correlated transport's pending command without sending a script."""
        return encode(await bridge.inspect_command_status())

    return exported
