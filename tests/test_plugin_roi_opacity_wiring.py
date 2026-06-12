"""Tests that generated TotalSegmentator ROI overlays receive display opacity."""

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
IMPORT_SWIFT = REPO_ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"
VOLUMETRIC_IMPORTER = REPO_ROOT / "MyOsiriXPluginFolder-Swift" / "TSVolumetricROIImporter.m"


class PluginROIOpacityWiringTests(unittest.TestCase):
    def test_rtstruct_created_rois_are_opacity_adjusted_after_reload(self):
        source = IMPORT_SWIFT.read_text()

        self.assertIn("totalSegmentatorROIDisplayOpacity", source)
        self.assertIn("applyTotalSegmentatorROIOpacity", source)

        rtstruct_finish_block = re.search(
            r"if appliedOverlayCount > 0 \{\n(?P<body>.*?)\n\s*\} else if importedVolumetricROICount > 0",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(rtstruct_finish_block)
        body = rtstruct_finish_block.group("body")
        self.assertRegex(
            body,
            r"(?s)reloadROIs\(in: activeViewer\).*applyTotalSegmentatorROIOpacity\(in: activeViewer",
        )

    def test_volumetric_importer_uses_native_opacity_api(self):
        source = VOLUMETRIC_IMPORTER.read_text()

        self.assertIn("TSVolumetricROIImporterDisplayOpacity", source)
        self.assertIn("setOpacity:globally:", source)
        self.assertIn("setOpacity:TSVolumetricROIImporterDisplayOpacity forROI:roi", source)
        self.assertNotIn("@0.45 forKey:@\"opacity\"", source)


if __name__ == "__main__":
    unittest.main()
