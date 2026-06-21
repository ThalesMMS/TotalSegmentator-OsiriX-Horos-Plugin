"""Contract tests for matching the original OsiriX TotalSegmentator ROI importer."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = ROOT / "MyOsiriXPluginFolder-Swift" / "TSVolumetricROIImporter.m"


def test_volumetric_importer_matches_original_osirix_brush_roi_finalization():
    source = IMPORTER.read_text(encoding="utf-8")

    assert "initWithTexture:(unsigned char *)textureData.mutableBytes" in source
    assert 'setValue:@YES forKey:@"textNameOnly" forROI:roi' in source
    assert 'setValue:@YES forKey:@"locked" forROI:roi' in source
    assert "reduceTextureIfPossibleForROI:roi" in source
    assert "isValidBrushROI:roi" in source


def test_volumetric_importer_posts_roi_change_and_merges_when_viewer_supports_it():
    source = IMPORTER.read_text(encoding="utf-8")

    assert "postROIChangeNotification" in source
    assert "OsirixROIChangeNotification" in source
    assert 'NSSelectorFromString(@"mergeBrushROIsWithSameName:")' in source
    assert "mergeBrushROIsWithSameNameIfAvailableForViewer:viewer" in source
