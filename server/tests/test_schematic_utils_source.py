from pathlib import Path
import unittest


class SchematicUtilsSourceTest(unittest.TestCase):
    def test_pin_data_pipe_parsing_uses_strict_delimiter(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "schematic_utils.pas"
        lines = source_path.read_text(encoding="utf-8").splitlines()

        violations = []
        for index, line in enumerate(lines):
            if "PinData.Delimiter := '|'" not in line:
                continue

            context = lines[max(0, index - 2) : index]
            if not any("PinData.StrictDelimiter := True" in item for item in context):
                violations.append(index + 1)

        self.assertFalse(
            violations,
            "PinData pipe parsing must set StrictDelimiter before DelimitedText "
            f"to keep pin names with spaces in one field. Missing near lines: {violations}",
        )

    def test_single_sided_symbols_have_nonzero_body_width_guard(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "schematic_utils.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "if (MaxX = MinX) then",
            source,
            "Single-sided symbols need a nonzero body width when all pins share the same X coordinate.",
        )

    def test_reference_parameter_copy_deduplicates_by_name(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "schematic_utils.pas"
        lines = source_path.read_text(encoding="utf-8").splitlines()

        replicate_line = next(
            index for index, line in enumerate(lines) if "SchParameter := SourceParameter.Replicate" in line
        )
        context = "\n".join(lines[max(0, replicate_line - 8) : replicate_line])

        self.assertIn(
            "CopiedParameterNames.IndexOf(UpperCase(ParameterName)) < 0",
            context,
            "Reference parameter copying must skip duplicate parameter names before replication.",
        )

    def test_reference_parameter_copy_skips_component_comment_parameter(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "schematic_utils.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "UpperCase(ParameterName) <> 'COMMENT'",
            source,
            "Component Comment is set directly and must not be copied again as a custom parameter.",
        )

    def test_generated_component_comment_is_set_from_metadata(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "schematic_utils.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "SchComponent.Comment.Text := CommentText",
            source,
            "Generated symbols must set the component Comment so =Comment parameters resolve correctly.",
        )
        self.assertNotIn(
            "SchComponent.Comment.IsHidden := True",
            source,
            "Do not hide the default Comment primitive as a workaround.",
        )

    def test_reference_dividers_include_polylines(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "schematic_utils.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "StyleIterator.AddFilter_ObjectSet(MkSet(ePolyline))",
            source,
            "Reference divider discovery must include polyline primitives used by TXS0102DCTT.",
        )
        self.assertIn(
            "VerticalSeparatorsEnabled := HasReferenceDividerGeometry",
            source,
            "Polyline divider geometry should enable generated vertical separators by default.",
        )

    def test_mcp_docs_expose_center_label_metadata(self):
        source_path = Path(__file__).resolve().parents[1] / "main.py"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn("CenterLabel=<functional text>", source)
        self.assertIn("CenterLabelPosition=TOPCENTER", source)


class PcbUtilsSourceTest(unittest.TestCase):
    def test_schlib_footprint_library_patch_uses_library_name_only(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_utils.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "SCH_LIB_SET_FOOTPRINT_LIBRARY",
            source,
            "SchLib footprint library patch command must stay available through the maintenance channel.",
        )
        self.assertIn(
            "FindSchLibrarySetFootprintLibraryCommand(LayerMoves, SchFootprintLibraryName, SchFootprintLibraryPath)",
            source,
            "The SchLib patch command must dispatch before normal PCB-library maintenance.",
        )
        self.assertIn(
            "SchImplementation.AddDataFileLink(SchImplementation.ModelName, LibraryName, 'PCBLIB')",
            source,
            "Footprint links must use the provided library file name, not an absolute path.",
        )

    def test_pcb_layer_rename_commands_are_exposed_end_to_end(self):
        server_path = Path(__file__).resolve().parents[1] / "main.py"
        api_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "Altium_API.pas"
        utils_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_utils.pas"
        focus_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "other_utils.pas"
        readme_path = Path(__file__).resolve().parents[2] / "README.md"

        server_source = server_path.read_text(encoding="utf-8")
        api_source = api_path.read_text(encoding="utf-8")
        utils_source = utils_path.read_text(encoding="utf-8")
        focus_source = focus_path.read_text(encoding="utf-8")
        readme_source = readme_path.read_text(encoding="utf-8")

        self.assertIn("async def set_pcb_layer_names_by_id", server_source)
        self.assertIn("async def clear_pcb_route_tool_path_layer", server_source)
        self.assertIn('"set_pcb_layer_names_by_id"', server_source)
        self.assertIn('"clear_pcb_route_tool_path_layer"', server_source)

        self.assertIn("function ExecuteSetPCBLayerNamesById(RequestData: TStringList): String", api_source)
        self.assertIn("function ExecuteClearPCBRouteToolPathLayer(RequestData: TStringList): String", api_source)
        self.assertIn("'set_pcb_layer_names_by_id':", api_source)
        self.assertIn("'clear_pcb_route_tool_path_layer':", api_source)

        self.assertIn("function SetPCBLayerNamesById(LayerNameSpecs: TStringList): String", utils_source)
        self.assertIn("function ClearPCBRouteToolPathLayer(): String", utils_source)
        self.assertIn("LayerObj.Name := NewName", utils_source)
        self.assertIn("Board.RouteToolPathLayer := eNoLayer", utils_source)

        self.assertIn("(CommandName = 'set_pcb_layer_names_by_id')", focus_source)
        self.assertIn("(CommandName = 'clear_pcb_route_tool_path_layer')", focus_source)

        self.assertIn("set_pcb_layer_names_by_id", readme_source)
        self.assertIn("clear_pcb_route_tool_path_layer", readme_source)


class PcbLayoutDuplicatorSourceTest(unittest.TestCase):
    def test_selection_phase_does_not_start_interactive_inside_area_selection(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_layout_duplicator.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertNotIn(
            "Scope=InsideArea",
            source,
            "MCP layout duplication must not leave Altium in an interactive mouse selection command.",
        )
        self.assertNotIn(
            "Client.SendMessage('PCB:Select'",
            source,
            "Selection phase should select duplicated primitives programmatically, not start PCB:Select.",
        )
        self.assertIn(
            "Client.SendMessage('PCB:Cancel'",
            source,
            "Selection phase should explicitly cancel any active PCB command before returning.",
        )

    def test_apply_keeps_destination_anchor_xy_instead_of_source_absolute_xy(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_layout_duplicator.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "AnchorOffsetX := AnchorDstOriginalX - AnchorSrc.x",
            source,
            "Layout duplication must compute placement from the destination base component location.",
        )
        self.assertIn(
            "CmpDst.x := CmpSrc.x + AnchorOffsetX",
            source,
            "Destination component X should preserve the base IC location and copy source-relative offsets.",
        )
        self.assertIn(
            "CmpDst.y := CmpSrc.y + AnchorOffsetY",
            source,
            "Destination component Y should preserve the base IC location and copy source-relative offsets.",
        )
        self.assertNotIn(
            "CmpDst.x := CmpSrc.x;",
            source,
            "Destination components must not be moved to source absolute X.",
        )
        self.assertNotIn(
            "CmpDst.y := CmpSrc.y;",
            source,
            "Destination components must not be moved to source absolute Y.",
        )

    def test_apply_moves_selected_routing_by_anchor_offset_before_net_assignment(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_layout_duplicator.pas"
        source = source_path.read_text(encoding="utf-8")

        move_index = source.index("ConnectedPrim.MoveByXY(AnchorOffsetX, AnchorOffsetY)")
        net_assign_index = source.index("ConnectedPrim.Net := Net")

        self.assertLess(
            move_index,
            net_assign_index,
            "Copied routing primitives must be moved to the destination before pad-based net assignment.",
        )
        self.assertIn(
            "SourcePadCount := CountComponentPads(CmpSrc)",
            source,
            "The base component should be chosen from the source component with the most pads, not list order.",
        )

    def test_apply_supports_repeated_source_groups_for_multiple_destinations(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_layout_duplicator.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "function DetermineLayoutDuplicatorSourceGroupSize(SourceList: TStringList): Integer",
            source,
            "Apply must detect repeated source groups so multiple destinations get separate anchor offsets.",
        )
        self.assertIn(
            "GroupStart := SourceList.Count - SourceGroupSize",
            source,
            "Apply should process destination groups independently, starting from the last group.",
        )
        self.assertIn(
            "NewPrim := TemplatePrim.Replicate",
            source,
            "Each additional destination group needs its own replicated routing primitives.",
        )
        self.assertIn(
            "GroupObjects.Add(NewPrim)",
            source,
            "Net assignment should operate on the copied primitives for the current destination group only.",
        )

    def test_apply_translates_unreached_copied_primitives_from_source_to_destination_nets(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_layout_duplicator.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "BuildLayoutDuplicatorNetNameMap(Board, SourceList, DestList, GroupStart, GroupEnd, NetNameMap)",
            source,
            "Apply should build a per-destination source-net to destination-net map from matched component pads.",
        )
        self.assertIn(
            "TranslateLayoutDuplicatorPrimitiveNets(Board, GroupObjects, NetNameMap)",
            source,
            "Copied vias or other primitives not reached by pad tracing must not keep source nets.",
        )
        self.assertLess(
            source.index("ConnectedPrim.Net := Net"),
            source.index("TranslateLayoutDuplicatorPrimitiveNets(Board, GroupObjects, NetNameMap)"),
            "Fallback source-net translation should run after normal pad-based net assignment.",
        )

    def test_repair_command_exists_for_existing_copied_source_net_leaks(self):
        script_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_layout_duplicator.pas"
        api_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "Altium_API.pas"
        script_source = script_path.read_text(encoding="utf-8")
        api_source = api_path.read_text(encoding="utf-8")

        self.assertIn(
            "function RepairLayoutDuplicatorCopiedNets(SourceList: TStringList; DestList: TStringList): String",
            script_source,
            "Existing copied layouts need a non-duplicating repair path for source-net leaks.",
        )
        self.assertIn(
            "'layout_duplicator_repair_copied_nets':",
            api_source,
            "The Altium bridge should expose the repair command for one-off board cleanup.",
        )

    def test_grouped_apply_wrapper_repeats_source_groups_in_one_command(self):
        source_path = Path(__file__).resolve().parents[1] / "main.py"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "async def layout_duplicator_apply_groups",
            source,
            "MCP should expose a grouped layout apply helper for multi-destination routing copies.",
        )
        self.assertIn(
            "destination_designator_groups",
            source,
            "Grouped apply should accept destination groups instead of a pre-flattened list.",
        )
        self.assertIn(
            "expanded_source_designators.extend(source_designators)",
            source,
            "Grouped apply must repeat the source list once for each destination group.",
        )
        self.assertIn(
            "flattened_destination_designators.extend(destination_group)",
            source,
            "Grouped apply must flatten destination groups for the existing Altium command.",
        )
        self.assertIn(
            '"layout_duplicator_apply"',
            source,
            "Grouped apply should reuse the existing Pascal apply command.",
        )
        self.assertIn(
            "Separate layout_duplicator_apply calls can move the same duplicated routing primitives",
            source,
            "The wrapper documentation should warn against separate apply calls for copied routing.",
        )


class PcbLibraryCustomPadSourceTest(unittest.TestCase):
    def test_selected_pad_join_uses_custom_pad_contour_conversion(self):
        source_path = Path(__file__).resolve().parents[1] / "AltiumScript" / "pcb_utils.pas"
        source = source_path.read_text(encoding="utf-8")

        self.assertIn(
            "PCB_LIB_JOIN_SELECTED_PADS_CUSTOM",
            source,
            "Selected pad joining should be exposed through the PcbLib command dispatcher.",
        )
        self.assertIn(
            "PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_PREPARE",
            source,
            "Pad joining needs a separate prepare phase so Altium sees a stable selected outline.",
        )
        self.assertIn(
            "PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_CONVERT",
            source,
            "Pad joining needs a separate convert phase for the editor custom-pad command.",
        )
        self.assertIn(
            "PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_CLEANUP",
            source,
            "Pad joining needs a cleanup phase after conversion readback.",
        )
        self.assertIn(
            "PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_REBUILD_SOURCE",
            source,
            "Already converted pads need a rebuild-source phase before reconversion.",
        )
        self.assertIn(
            "Client.SendMessage('PCB:CustomPadShape'",
            source,
            "Selected pad joining must use Altium's custom pad editor command.",
        )
        self.assertIn(
            "Action=Convert|Object=Track",
            source,
            "Selected pad joining must invoke Altium's contour conversion action.",
        )
        self.assertIn(
            "JoinSelectedPadsAsCustomPadShape",
            source,
            "Selected pad joining should be implemented as a single custom-shape pad operation.",
        )
        self.assertLess(
            source.index("function JoinSelectedPadsAsCustomPadShape(JoinAction: String): String; forward;"),
            source.index("function MovePCBLibraryMechanicalLayers"),
            "DelphiScript dispatcher must see a forward declaration before calling the custom pad join function.",
        )

        join_start = source.index("function AddJoinCustomPadContourTrack", source.index("function MoveComponentsByDesignators"))
        join_end = source.index("function MoveSelectedViasByOffset", join_start)
        join_source = source[join_start:join_end]

        self.assertIn(
            "Board.AddPCBObject(Track)",
            join_source,
            "Temporary contour tracks must be registered through the active PcbLib board.",
        )
        self.assertIn(
            "Board.AddPCBObject(Arc)",
            join_source,
            "Temporary contour arcs must be registered through the active PcbLib board.",
        )
        self.assertNotIn(
            "eRegionObject",
            join_source,
            "Joining selected pads must not create a separate copper region.",
        )
        self.assertEqual(
            join_source.count("PCBObjectFactory(ePadObject"),
            1,
            "Only the explicit rebuild-source phase may recreate original source pads.",
        )
        self.assertNotIn(
            "Int64(",
            join_source,
            "Altium DelphiScript does not support Int64 casts in this script context.",
        )
        self.assertNotIn(
            "IPCB_Primitive(",
            join_source,
            "Altium DelphiScript does not support interface-style cast calls here.",
        )
        self.assertIn(
            "auto_duplicate_same_name",
            join_source,
            "Selection-loss recovery should only use the single supported duplicate same-name pad pair.",
        )
        self.assertIn(
            "cleanup_duplicate_same_name_largest_pad",
            join_source,
            "Cleanup needs a post-conversion fallback that keeps the largest same-name pad.",
        )
        self.assertIn(
            "AddJoinSourceRoundedPad",
            join_source,
            "Rebuilding an already converted pad should recreate the original rounded source pads.",
        )
        self.assertIn(
            "180, 270",
            join_source,
            "Rounded custom-pad contour arcs should use outward arc direction.",
        )
        self.assertIn(
            "270, 0",
            join_source,
            "Rounded custom-pad contour arcs should use outward arc direction.",
        )
        self.assertIn(
            "0, 90",
            join_source,
            "Rounded custom-pad contour arcs should use outward arc direction.",
        )
        self.assertIn(
            "90, 180",
            join_source,
            "Rounded custom-pad contour arcs should use outward arc direction.",
        )
        self.assertNotIn(
            "ShapeOnLayer[AnchorPad.Layer] = OriginalShape",
            join_source,
            "Normal pad shape enums do not prove whether Altium created a custom pad shape.",
        )
        self.assertNotIn(
            "Footprint.RemovePCBObject(ExtensionPad)",
            join_source,
            "Cleanup must use the PCB editor delete path after custom-pad conversion.",
        )
        self.assertIn(
            "DeleteJoinObjects(TempObjects)",
            join_source,
            "Cleanup must delete temporary contour primitives through selected editor objects.",
        )


if __name__ == "__main__":
    unittest.main()
