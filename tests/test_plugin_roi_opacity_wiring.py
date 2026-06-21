"""Tests that generated TotalSegmentator ROI overlays receive display opacity."""

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
IMPORT_SWIFT = REPO_ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"
VOLUMETRIC_IMPORTER = REPO_ROOT / "MyOsiriXPluginFolder-Swift" / "TSVolumetricROIImporter.m"


class PluginROIOpacityWiringTests(unittest.TestCase):
    def test_volumetric_created_rois_are_opacity_adjusted_after_import(self):
        source = IMPORT_SWIFT.read_text()

        self.assertIn("totalSegmentatorROIDisplayOpacity", source)
        self.assertIn("applyTotalSegmentatorROIOpacity", source)

        volumetric_finish_block = re.search(
            r"let finishVisualization: \(\) -> Void = \{\n(?P<body>.*?)\n\s*semaphore\.signal\(\)",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(volumetric_finish_block)
        body = volumetric_finish_block.group("body")
        self.assertRegex(
            body,
            r"(?s)deduplicateTotalSegmentatorROIs\(in: activeViewer.*applyTotalSegmentatorROIOpacity\(in: activeViewer",
        )

    def test_volumetric_importer_uses_native_opacity_api(self):
        source = VOLUMETRIC_IMPORTER.read_text()

        self.assertIn("TSVolumetricROIImporterDisplayOpacity", source)
        self.assertIn("setOpacity:globally:", source)
        self.assertIn("setOpacity:TSVolumetricROIImporterDisplayOpacity forROI:roi", source)
        self.assertNotIn("@0.45 forKey:@\"opacity\"", source)


if __name__ == "__main__":
    unittest.main()
