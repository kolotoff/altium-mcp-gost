import tempfile
import unittest
from pathlib import Path

from PIL import Image

from server.main import (
    _altium_color,
    _find_edge,
    _normalize_html_color,
    _pcb_3d_registration,
    _rasterize_svg_sync,
    _recolor_svg,
    _stamp_png_dpi_sync,
)


class ImageExportHelpersTests(unittest.TestCase):
    def test_html_color_is_validated_and_normalized(self):
        self.assertEqual("#12ABEF", _normalize_html_color("#12abef", "color"))
        with self.assertRaises(ValueError):
            _normalize_html_color("red", "color")

    def test_altium_color_uses_red_green_blue_packing(self):
        self.assertEqual(0x563412, _altium_color("#123456", "color"))

    def test_pcb_3d_registration_converts_internal_units_to_mm(self):
        registration = _pcb_3d_registration({
            "camera_look_at_x": 20000000,
            "camera_look_at_y": 10000000,
            "camera_view_x": 10000000,
            "camera_view_y": 5000000,
            "camera_units_per_inch": 10000000,
            "camera_mirror_x": True,
            "width": 600,
            "height": 300,
        })
        self.assertAlmostEqual(38.1, registration["left_mm"])
        self.assertAlmostEqual(63.5, registration["right_mm"])
        self.assertAlmostEqual(19.05, registration["bottom_mm"])
        self.assertAlmostEqual(31.75, registration["top_mm"])
        self.assertTrue(registration["mirror_x"])

    def test_svg_raster_has_requested_dpi_and_alpha(self):
        try:
            _find_edge()
        except RuntimeError as exc:
            self.skipTest(str(exc))

        with tempfile.TemporaryDirectory() as directory:
            svg_path = Path(directory) / "shape.svg"
            png_path = Path(directory) / "shape.png"
            svg_path.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="5mm" viewBox="0 0 10 5">\n'
                '  <path d="M 1 1 L 9 4" fill="none" stroke="#111111" stroke-width="0.2"/>\n'
                '</svg>\n',
                encoding="utf-8",
            )

            result = _rasterize_svg_sync(svg_path, png_path, 600)

            self.assertEqual(237, result["width"])
            self.assertEqual(119, result["height"])
            self.assertTrue(result["alpha_channel"])
            self.assertTrue(result["has_transparent_pixels"])
            with Image.open(png_path) as image:
                self.assertEqual("RGBA", image.mode)
                alpha_bounds = image.getchannel("A").getbbox()
                self.assertIsNotNone(alpha_bounds)
                self.assertGreater(alpha_bounds[2], 200)

    def test_svg_recolor_preserves_pad_layer_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            svg_path = Path(directory) / "pads.svg"
            svg_path.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<svg xmlns="http://www.w3.org/2000/svg" data-coordinate-units="mm" width="10mm" height="5mm" viewBox="0 0 10 5">\n'
                '  <g id="Pads" data-layer="pads" fill="#2F80ED">\n'
                '    <path id="U1-pad-1" data-component="U1" data-footprint="QFN-32" '
                'data-pad-number="1" data-pad-index="17" d="M 1 1 L 2 2"/>\n'
                '  </g>\n'
                '  <g id="Shape" data-layer="shape"><path stroke="#111111" d="M 0 0 L 1 1"/></g>\n'
                '  <g id="BoardShape" data-layer="board-shape">\n'
                '    <path id="BoardOutline" data-stroke-width-mm="0.1" stroke="#000000" stroke-width="0.1" d="M 0 0 L 10 0"/>\n'
                '    <g id="StandaloneMountingPads" data-layer="standalone-mounting-pads" data-minimum-hole-diameter-mm="1">\n'
                '      <circle id="standalone-pad-1" data-kind="standalone-mounting-pad" data-hole-diameter-mm="3.2" cx="2" cy="2" r="1.6" fill="none" stroke="#000000" stroke-width="0.1"/>\n'
                '    </g>\n'
                '  </g>\n'
                '</svg>\n',
                encoding="utf-8",
            )

            _recolor_svg(svg_path, "#ABCDEF", "#123456")

            text = svg_path.read_text(encoding="utf-8")
            self.assertIn('id="Pads" data-layer="pads"', text)
            self.assertIn('id="U1-pad-1"', text)
            self.assertIn('data-component="U1"', text)
            self.assertIn('data-footprint="QFN-32"', text)
            self.assertIn('data-pad-number="1"', text)
            self.assertIn('data-pad-index="17"', text)
            self.assertIn('data-kind="standalone-mounting-pad"', text)
            self.assertIn('data-hole-diameter-mm="3.2"', text)
            self.assertIn('data-coordinate-units="mm"', text)
            self.assertIn('data-stroke-width-mm="0.1"', text)
            self.assertIn('fill="#2F80ED"', text)
            self.assertIn('stroke="#ABCDEF"', text)
            self.assertIn('stroke="#123456"', text)

    def test_png_dpi_is_stamped_without_changing_pixels(self):
        with tempfile.TemporaryDirectory() as directory:
            png_path = Path(directory) / "render.png"
            Image.new("RGB", (19, 11), (12, 34, 56)).save(png_path, "PNG")

            result = _stamp_png_dpi_sync(png_path, 600)

            self.assertEqual(19, result["width"])
            self.assertEqual(11, result["height"])
            self.assertFalse(result["alpha_channel"])
            with Image.open(png_path) as image:
                self.assertEqual((19, 11), image.size)
                self.assertAlmostEqual(600, image.info["dpi"][0], delta=0.1)
                self.assertEqual((12, 34, 56), image.getpixel((0, 0)))


if __name__ == "__main__":
    unittest.main()
