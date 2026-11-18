import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from docx import Document

from tools.altium_cfb_inspect import (
    ALTIUM_COORD_TO_MM,
    extract_board_bounds,
    iter_schematic_text,
)
from tools.generate_board_description_docx import generate
from tools.generate_step_silhouette import model_for_body
from tools.optional import checkpoints


class FakeCFB:
    def __init__(self, streams):
        self.streams = streams

    def read_stream(self, path):
        return self.streams[path]


class AltiumCFBInspectTest(unittest.TestCase):
    def test_extract_board_bounds_converts_internal_coordinates_to_mm(self):
        header = b"V7_LAYER=1|"
        coordinates = (10.0, 20.0, 110.0, 20.0, 110.0, 70.0, 10.0, 70.0)
        stream = (
            struct.pack("<I", len(header))
            + header
            + struct.pack("<I", 4)
            + struct.pack("<8d", *coordinates)
        )
        bounds = extract_board_bounds(FakeCFB({"BoardRegions/Data": stream}))

        self.assertEqual(bounds.vertices, 4)
        self.assertAlmostEqual(bounds.width_mm, 100.0 * ALTIUM_COORD_TO_MM)
        self.assertAlmostEqual(bounds.height_mm, 50.0 * ALTIUM_COORD_TO_MM)

    def test_iter_schematic_text_prefers_utf8_text_field(self):
        record = "|Text=Fallback|%UTF8%Text=Строка~1две|".encode()
        stream = struct.pack("<I", len(record)) + record

        values = list(iter_schematic_text(FakeCFB({"FileHeader": stream})))

        self.assertEqual(values, ["Строка\nдве"])

    def test_iter_schematic_text_skips_binary_records_and_preserves_ansi(self):
        record = b"|Record=4|Text=Caf\xe9\x00"
        stream = struct.pack("<I", 0x01000002) + b"\x00\xff" + struct.pack("<I", len(record)) + record

        self.assertEqual(list(iter_schematic_text(FakeCFB({"FileHeader": stream}))), ["Café"])


class BoardDescriptionGeneratorTest(unittest.TestCase):
    def test_generate_uses_only_cli_supplied_template_data_and_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "template.docx"
            data = root / "description.json"
            output = root / "result.docx"

            template_doc = Document()
            template_doc.add_paragraph("OLD TITLE")
            template_doc.add_paragraph("old subtitle")
            template_doc.add_paragraph("01  Old section")
            table = template_doc.add_table(rows=2, cols=2)
            table.cell(0, 0).text = "Parameter"
            table.cell(0, 1).text = "Value"
            table.cell(1, 0).text = "Old"
            table.cell(1, 1).text = "Old value"
            template_doc.sections[0].footer.paragraphs[0].text = "Old footer"
            template_doc.save(template)

            data.write_text(
                json.dumps(
                    {
                        "title": "ТЕХНИЧЕСКИЕ ХАРАКТЕРИСТИКИ",
                        "subtitle": "печатной платы TestBoard",
                        "footer_label": "TestBoard",
                        "sections": [
                            {
                                "number": "01",
                                "title": "Общие сведения",
                                "rows": [
                                    ["Назначение", "Испытательная плата"],
                                    ["Размер", "10 × 20 мм"],
                                ],
                            }
                        ],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            generate(template, data, output)

            result = Document(output)
            self.assertEqual(result.paragraphs[0].text, "ТЕХНИЧЕСКИЕ ХАРАКТЕРИСТИКИ")
            self.assertEqual(result.paragraphs[1].text, "печатной платы TestBoard")
            self.assertEqual(result.tables[0].cell(2, 1).text, "10 × 20 мм")
            footer_xml = result.sections[0].footer._element.xml
            self.assertIn("TestBoard", footer_xml)
            self.assertIn("PAGE", footer_xml)


class StepBodyModelTest(unittest.TestCase):
    def test_footprint_filename_matches_unscoped_legacy_placement(self):
        file = Path("QFN48.step")
        state = {"identifier": "", "model_name": file.name,
                 "model_name_key": file.name.upper(), "rotz": 90.0}
        body = {"footprint": "QFN48"}
        model, placement, error = model_for_body(body, [state], [file], single_body=True)
        self.assertEqual((model, placement, error), (file, state, None))

        model, placement, error = model_for_body(body, [state, dict(state, rotz=45)], [file], single_body=True)
        self.assertIsNone(model)
        self.assertIsNone(placement)
        self.assertIn("multiple saved 3D body placements", error)

    def test_each_body_uses_its_own_model_and_rotation(self):
        files = [Path("Receiver-v1.step"), Path("Shield-v1.step")]
        states = [
            {"footprint": "Assembly", "identifier": "Receiver", "model_name": files[0].name,
             "model_name_key": files[0].name.upper(), "rotz": 25},
            {"footprint": "Assembly", "identifier": "Shield", "model_name": files[1].name,
             "model_name_key": files[1].name.upper(), "rotz": 70},
            {"footprint": "Unrelated", "identifier": "Receiver", "model_name": files[0].name,
             "model_name_key": files[0].name.upper(), "rotz": 90},
        ]
        for identifier, file, rotation in zip(("Receiver", "Shield"), files, (25, 70)):
            model, state, error = model_for_body(
                {"footprint": "Assembly", "identifier": identifier}, states, files, single_body=False,
            )
            self.assertIsNone(error)
            self.assertEqual((file, rotation), (model, state["rotz"]))

    def test_unidentified_multi_body_does_not_guess_a_footprint_step(self):
        model, _, error = model_for_body(
            {"footprint": "Assembly"}, [], [Path("Assembly.step")], single_body=False,
        )
        self.assertIsNone(model)
        self.assertIn("not found", error)


class CheckpointSourceChangesTest(unittest.TestCase):
    def test_rejects_files_added_or_earlier_files_changed_while_copying(self):
        for added in (False, True):
            with self.subTest(added=added), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, destination = root / "source", root / "generated" / "checkpoint"
                source.mkdir()
                (source / "a.txt").write_text("saved content")
                (source / "b.txt").write_text("second file")
                real_copy = checkpoints.shutil.copy2

                def update_during_copy(original, target):
                    real_copy(original, target)
                    if original.name == "b.txt":
                        (source / ("c.txt" if added else "a.txt")).write_text("new content")

                with (patch.object(checkpoints, "GENERATED", destination.parent),
                      patch.object(checkpoints.shutil, "copy2", side_effect=update_during_copy),
                      self.assertRaisesRegex(ValueError, "Source changed")):
                    checkpoints.copy_checkpoint(source, destination)
                self.assertFalse((destination / "checkpoint-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
