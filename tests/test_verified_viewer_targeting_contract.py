from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"
SCRIPTS_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Scripts.swift"
VOLUMETRIC_IMPORTER = ROOT / "MyOsiriXPluginFolder-Swift" / "TSVolumetricROIImporter.m"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read UTF-8 text from a file.

    Parameters:
    	path (Path): The file path to read from

    Returns:
    	str: The text content of the file
    """
    return path.read_text(encoding="utf-8")


def test_swift_uses_viewer_series_identity_not_frontmost_viewer_for_roi_actions():
    source = _read(IMPORT_SWIFT)
    update_start = source.find("func updateVisualization")
    update_end = source.find("private func openViewer", update_start)
    update_block = source[update_start:update_end]
    resync_start = source.find("final class TotalSegmentatorROIResyncCoordinator")
    resync_block = source[resync_start:]

    assert "struct ViewerSeriesIdentity" in source
    assert "enum ViewerSeriesIdentityMatch" in source
    assert "verifiedSourceViewer" in update_block
    assert "viewerSeriesIdentity" in source
    assert "sourceIdentityHash" in source
    assert "preferredDisplayed2DViewer()" not in update_block
    assert "frontMostDisplayed2DViewer" not in resync_block
    assert "isKeyWindow" not in resync_block


def test_resync_and_deduplication_use_job_specific_roi_provenance():
    source = _read(IMPORT_SWIFT)

    assert "roiProvenanceComment(for jobManifest: SegmentationJobManifest)" in source
    assert "jobManifest: exportContext.jobManifest" in source
    assert "expectedROIComment" in source
    assert "viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)" in source
    assert "deduplicateDisplayedTotalSegmentatorROIs(labelNames: labelNames, jobManifest: exportContext.jobManifest" in source
    assert "labelNames.contains(name)" not in source


def test_volumetric_manifest_carries_source_identity_and_roi_provenance():
    scripts = _read(SCRIPTS_SWIFT)

    for symbol in [
        "\"job_uuid\"",
        "\"source_identity_hash\"",
        "\"roi_provenance_comment\"",
        "\"source_identity\"",
        "\"ordered_sop_instance_uids\"",
        "\"study_instance_uid\"",
        "\"series_instance_uid\"",
        "\"frame_of_reference_uid\"",
    ]:
        assert symbol in scripts


def test_objective_c_importer_fails_closed_without_source_identity_and_never_uses_slice_index_fallback():
    source = _read(VOLUMETRIC_IMPORTER)

    assert "viewerIdentityMatchesManifest" in source
    assert "source identity mismatch" in source
    assert "source_identity" in source
    assert "roi_provenance_comment" in source
    assert "TSVolumetricROIImporterGeneratedCommentPrefix" in source
    assert "viewerSliceIndexForSlice:(NSDictionary *)slice uidMap:(NSDictionary<NSString *, NSNumber *> *)uidMap" in source
    assert "fallbackCount" not in source
    assert "slice_index" not in source[source.find("+ (NSInteger)viewerSliceIndexForSlice") : source.find("+ (NSUInteger)removeGeneratedROIsNamed")]


def test_objective_c_series_identity_requires_all_reported_series_uids_to_match():
    source = _read(VOLUMETRIC_IMPORTER)
    start = source.find("+ (BOOL)viewer:(ViewerController *)viewer hasSeriesInstanceUID")
    end = source.find("\n}\n\n", start) + 3
    method = source[start:end]

    assert "BOOL foundExpectedSeriesUID = NO;" in method
    assert "seriesInstanceUIDFromObject:object" in method
    assert 'safeValueForKey:@"seriesInstanceUID"' not in method
    assert "foundExpectedSeriesUID = YES;" in method
    assert "return foundExpectedSeriesUID;" in method
    assert "return YES;" not in method


def test_objective_c_importer_rejects_duplicate_viewer_sop_instance_uids():
    source = _read(VOLUMETRIC_IMPORTER)
    identity_start = source.find("+ (BOOL)viewerIdentityMatchesManifest")
    identity_end = source.find("\n}\n\n", identity_start) + 3
    identity_method = source[identity_start:identity_end]

    assert "viewerSOPInstanceUIDCountForViewer" in source
    assert "NSUInteger viewerSOPCount" in identity_method
    assert "actualSet.count != viewerSOPCount" in identity_method
    assert "viewer SOP Instance UIDs differ" in identity_method


def test_readme_documents_verified_source_viewer_failure_mode():
    readme = _read(README)

    assert "verified source-series viewer" in readme
    assert "source identity mismatch" in readme
