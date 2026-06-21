"""Contracts for keeping volumetric brush ROIs visible after 2D reslice."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"
IMPORTER_M = ROOT / "MyOsiriXPluginFolder-Swift" / "TSVolumetricROIImporter.m"
PROJECTION_PY = ROOT / "MyOsiriXPluginFolder-Swift" / "python_bridge" / "ts_horos_bridge" / "volumetric_projection.py"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_roi_resync_tracks_same_viewer_after_reslice_replaces_source_identity():
    source = _read(IMPORT_SWIFT)
    current_start = source.find("private func currentViewer")
    current_end = source.find("/// Schedules a resynchronization", current_start)
    current_block = source[current_start:current_end]

    assert "ViewerController.getDisplayed2DViewers()" in current_block
    assert "displayedViewers.contains(where: { $0 === viewer })" in current_block


def test_roi_resync_projects_manifest_for_generated_reslice_geometry():
    source = _read(IMPORT_SWIFT)
    resync_start = source.find("private func resync()")
    resync_block = source[resync_start:]

    assert "makeVolumetricProjectionRequest(viewer: viewer" in resync_block
    assert "generateProjectedVolumetricManifest(request: request)" in resync_block
    assert "lastProjectionGeometryHash = request.geometryHash" in resync_block
    assert "projectionInProgress" in resync_block


def test_resync_projects_when_display_geometry_no_longer_matches_source():
    source = _read(IMPORT_SWIFT)
    resync_start = source.find("private func resync()")
    projected_start = source.find("private func resyncProjectedROIs", resync_start)
    resync_block = source[resync_start:projected_start]

    assert "fileprivate func viewerGeometryMatchesSource(" in source
    assert "viewerGeometryMatchesSource(viewer, jobManifest: context.jobManifest)" in resync_block
    assert resync_block.find("viewerGeometryMatchesSource") < resync_block.find("owner.reloadROIs")


def test_roi_resync_observes_standard_2d_view_update_notifications():
    source = _read(IMPORT_SWIFT)
    observing_start = source.find("private func startObservingIfNeeded()")
    observing_end = source.find("private func stopObserving()", observing_start)
    observing_block = source[observing_start:observing_end]

    assert "NSNotification.Name.OsirixDCMViewIndexChanged" in observing_block
    assert "NSNotification.Name.OsirixDCMUpdateCurrentImage" in observing_block
    assert "NSNotification.Name.OsirixUpdateView" in observing_block


def test_roi_resync_does_not_observe_window_update_refresh_loop():
    source = _read(IMPORT_SWIFT)
    observing_start = source.find("private func startObservingIfNeeded()")
    observing_end = source.find("private func stopObserving()", observing_start)
    observing_block = source[observing_start:observing_end]

    assert "NSWindow.didUpdateNotification" not in observing_block


def test_projected_manifest_uses_explicit_viewer_geometry_projection_contract():
    projection = _read(PROJECTION_PY)
    importer = _read(IMPORTER_M)

    assert '"viewer_geometry_projection": True' in projection
    assert "isProjectedViewerGeometryManifest" in importer
    assert "projectedViewerSliceIndexMapForPixList" in importer
    assert 'map[[NSString stringWithFormat:@"viewer_slice_%lu"' in importer

    slice_mapper = importer[
        importer.find("+ (NSInteger)viewerSliceIndexForSlice") : importer.find("+ (NSUInteger)removeGeneratedROIsNamed")
    ]
    assert "slice_index" not in slice_mapper
