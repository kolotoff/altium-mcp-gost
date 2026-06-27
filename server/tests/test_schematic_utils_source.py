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


if __name__ == "__main__":
    unittest.main()
