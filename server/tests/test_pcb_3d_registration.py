import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

from tools.normalize_pcb_3d_background import flatten_workspace
from tools.board_test_localization import localized_text, ui_text
from tools.generate_board_test_description_docx import require_verbatim_board_name
from tools.generate_end_user_board_description_docx import SpecError
from tools.pcb_3d_registration import CameraRegistration


class CameraRegistrationTests(unittest.TestCase):
    def test_bottom_view_mirrors_only_horizontal_axis(self):
        top = CameraRegistration(10, 30, 20, 30, False, 200, 100)
        bottom = CameraRegistration(10, 30, 20, 30, True, 200, 100)
        self.assertEqual((50.0, 25.0), top.pixel_for_physical(15, 27.5))
        self.assertEqual((150.0, 25.0), bottom.pixel_for_physical(15, 27.5))

    def test_bilingual_text_uses_both_languages_without_changing_identifiers(self):
        catalog = {"Контрольная точка": {"en": "Test point", "zh": "测试点"}}
        self.assertEqual(
            "Test point\n测试点",
            localized_text("Контрольная точка", "en-zh", translations=catalog),
        )
        self.assertEqual("TOP SIDE TEST ACCESS MAP / 顶面测试访问图", ui_text(
            "map_top", "en-zh", separator=" / "))
        self.assertEqual("VCC_IN", localized_text("VCC_IN", "en-zh", translations=catalog))

    def test_russian_mode_uses_source_prose_and_russian_ui(self):
        catalog = {"Контрольная точка": {"en": "Test point", "zh": "测试点"}}
        self.assertEqual(
            "Контрольная точка",
            localized_text("Контрольная точка", "ru", translations=catalog),
        )
        self.assertEqual("Верхняя сторона", ui_text("top", "ru"))
        self.assertEqual(
            "ВЕРХНЯЯ СТОРОНА КАРТА ТЕСТОВОГО ДОСТУПА",
            ui_text("map_top", "ru"),
        )

    def test_board_name_symbols_must_be_preserved_verbatim(self):
        require_verbatim_board_name(
            "Main_v1.5X Board Test Access Description", "Main_v1.5X", "title")
        with self.assertRaises(SpecError):
            require_verbatim_board_name(
                "Main v1 5X Board Test Access Description", "Main_v1.5X", "title")


class BackgroundNormalizationTests(unittest.TestCase):
    def test_flattens_gradient_without_erasing_board(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.png"
            output = Path(directory) / "output.png"
            image = Image.new("RGB", (100, 50))
            image.putdata([
                (200 - y, 180 - y, 175 - y)
                for y in range(50)
                for _ in range(100)
            ])
            ImageDraw.Draw(image).rectangle((20, 10, 80, 40), fill=(8, 8, 8))
            image.save(source)

            replaced = flatten_workspace(source, output, tolerance=5)

            with Image.open(output) as result:
                self.assertEqual((255, 255, 255), result.getpixel((0, 0)))
                self.assertEqual((255, 255, 255), result.getpixel((99, 49)))
                self.assertEqual((8, 8, 8), result.getpixel((50, 25)))
            self.assertGreater(replaced, 3000)


if __name__ == "__main__":
    unittest.main()
