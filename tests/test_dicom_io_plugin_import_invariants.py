#
# test_dicom_io_plugin_import_invariants.py
# TotalSegmentator
#
# Source-level invariants for Horos/OsiriX ROI import sequencing.
#

"""Check plugin import invariants that are not covered by an Xcode test target."""

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
IMPORT_SOURCE = REPO_ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"


class PluginROIImportInvariantTests(unittest.TestCase):
    def test_stale_total_segmentator_rois_are_persisted_before_rtstruct_reload(self):
        source = IMPORT_SOURCE.read_text(encoding="utf-8")
        match = re.search(
            r"let removedROICount = self\.removeTotalSegmentatorROIs"
            r"(?P<body>.*?)"
            r"\n\s*for path in importResult\.rtStructPaths",
            source,
            flags=re.DOTALL,
        )

        self.assertIsNotNone(match, "Could not find pre-RTStruct TotalSegmentator ROI cleanup block.")
        self.assertIn("self.persistROIs(from: activeViewer)", match.group("body"))

    def test_projected_resync_rois_are_not_persisted_into_axial_roi_database(self):
        source = IMPORT_SOURCE.read_text(encoding="utf-8")
        match = re.search(
            r"TSVolumetricROIImporter\.importVolumetricROIs\(fromManifest: projectedManifestPath, into: activeViewer\)"
            r"(?P<body>.*?)"
            r"\n\s*activeViewer\.refresh\(\)",
            source,
            flags=re.DOTALL,
        )

        self.assertIsNotNone(match, "Could not find projected volumetric ROI import block.")
        self.assertNotIn("persistROIs", match.group("body"))


if __name__ == "__main__":
    unittest.main()
