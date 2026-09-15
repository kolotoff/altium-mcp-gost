import tempfile
import unittest
from pathlib import Path

from PIL import Image

from server.main import (
    _altium_color,
    _find_edge,
    _normalize_html_color,
    _rasterize_svg_sync,
    _stamp_png_dpi_sync,
)


class ImageExportHelpersTests(unittest.TestCase):
    def test_html_color_is_validated_and_normalized(self):
        self.assertEqual("#12ABEF", _normalize_html_color("#12abef", "color"))
        with self.assertRaises(ValueError):
            _normalize_html_color("red", "color")

    def test_altium_color_uses_red_green_blue_packing(self):
        self.assertEqual(0x563412, _altium_color("#123456", "color"))

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
