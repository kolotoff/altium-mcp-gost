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


if __name__ == "__main__":
    unittest.main()
