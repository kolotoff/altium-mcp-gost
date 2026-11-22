import tempfile
import unittest
import xml.etree.ElementTree as ET
from importlib.util import find_spec
from io import BytesIO
from pathlib import Path
from zipfile import ZipFile

from docx import Document
from docx.shared import Cm
from lxml import etree
from PIL import Image

from tools.generate_end_user_board_description_docx import add_svg_picture, write_pdf_source
from tools.pcb_svg_geometry import parse_numbers
from tools.svg_label_text import add_label_ink


@unittest.skipUnless(find_spec("skia"), "vector PDF export requires the manual-pdf extra")
class ManualPdfSourceTests(unittest.TestCase):
    def test_renders_svg_strokes_and_labels_as_filled_vector_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            editable = Path(directory) / "manual.docx"
            render_copy = Path(directory) / "render.docx"
            document = Document()
            png = BytesIO()
            Image.new("RGB", (40, 40), "white").save(png, format="PNG")
            png.seek(0)
            svg = ET.fromstring(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">'
                '<line x1="5" y1="4" x2="35" y2="4" stroke="#000000" stroke-width="0.4" fill="none"/>'
                '</svg>'
            )
            add_label_ink(svg, "1: GND", 18, 10, size=2, fill="#263746")
            svg = ET.tostring(svg)
            add_svg_picture(document.add_paragraph().add_run(), svg, png, width=Cm(2), height=Cm(2), alt_text="Map")
            document.save(editable)

            write_pdf_source(editable, render_copy)

            with ZipFile(editable) as source, ZipFile(render_copy) as render:
                source_tree = etree.fromstring(source.read("word/document.xml"))
                render_tree = etree.fromstring(render.read("word/document.xml"))
                self.assertIsNotNone(source_tree.find(".//{*}svgBlip"))
                self.assertEqual(source.read("word/document.xml"), render.read("word/document.xml"))
                self.assertIsNotNone(render_tree.find(".//{*}svgBlip"))
                self.assertEqual(source_tree.find(".//{*}blip").attrib, render_tree.find(".//{*}blip").attrib)
                png_name = next(name for name in source.namelist() if name.startswith("word/media/") and name.endswith(".png"))
                self.assertEqual(source.read(png_name), render.read(png_name))
                svg_name = next(name for name in source.namelist() if name.startswith("word/media/") and name.endswith(".svg"))
                artwork = etree.fromstring(render.read(svg_name))
                self.assertIsNone(artwork.find(".//{*}image"))
                self.assertIsNotNone(artwork.find(".//{*}g[@aria-label='1: GND']/{*}path"))
                outline = artwork.find("{*}path")
                coordinates = parse_numbers(outline.get("d"))
                self.assertAlmostEqual(max(coordinates[1::2]) - min(coordinates[1::2]), 0.4)
            self.assertEqual(Document(render_copy).inline_shapes[0]._inline.docPr.get("descr"), "Map")
