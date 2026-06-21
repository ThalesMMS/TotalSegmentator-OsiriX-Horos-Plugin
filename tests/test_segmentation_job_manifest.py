from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TYPES_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorPluginTypes.swift"
JOB_MANIFEST_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorJobManifestTypes.swift"
EXPORT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Export.swift"
SEGMENTATION_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Segmentation.swift"
AUDIT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Audit.swift"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read the entire contents of a file as UTF-8 text.

    Returns:
    	str: The UTF-8 decoded text contents of the file
    """
    return path.read_text(encoding="utf-8")


def test_segmentation_job_manifest_schema_covers_identity_geometry_and_snapshots():
    source = _read(JOB_MANIFEST_SWIFT)

    assert "struct SegmentationJobManifest: Codable" in source
    assert "static let currentSchemaVersion = 1" in source
    for field in [
        "jobUUID",
        "createdAt",
        "pluginVersion",
        "pluginBuild",
        "studyInstanceUID",
        "seriesInstanceUID",
        "frameOfReferenceUID",
        "modality",
        "orderedSOPInstanceUIDs",
        "sourceIdentityHash",
        "sourceFileCount",
        "sourceFiles",
        "geometry",
        "frameIdentities",
        "derivedGeometry",
        "hostHints",
        "runSnapshot",
        "environmentSnapshot",
        "canonicalOutputPaths",
        "runState",
    ]:
        assert field in source

    assert "coordinateSystemConvention" in source
    assert "DICOM_LPS" in source
    assert "sourceToDerivedTransform" in source


def test_source_identity_hash_uses_frame_of_reference_and_ordered_sop_uids():
    source = _read(JOB_MANIFEST_SWIFT)

    assert "computeSourceIdentityHash" in source
    assert "frameOfReferenceUID" in source
    assert "orderedSOPInstanceUIDs" in source
    assert "SHA256.hash" in source
    assert "sourceIdentityPayload" in source


def test_export_builds_and_persists_job_manifest_before_inference():
    source = _read(EXPORT_SWIFT)

    assert "makeSegmentationJobManifest" in source
    assert "persistSegmentationJobManifest" in source
    assert "segmentation-job.json" in source
    assert ".atomic" in source
    assert "jobManifestURL" in source
    assert "jobManifest:" in source
    assert "orderedSOPInstanceUIDs" in source
    assert "sourceFiles" in source
    assert "sha256" in source


def test_export_geometry_rejects_non_uniform_spacing_and_orientation():
    source = _read(EXPORT_SWIFT)
    geometry_start = source.find("private func makeSegmentationJobGeometry")
    geometry_end = source.find("private func sortedImages", geometry_start)
    geometry_body = source[geometry_start:geometry_end]

    assert "try consistentValue(in: pixelSpacings, field: \"pixelSpacing\")" in geometry_body
    assert "try consistentValue(in: sliceSpacings, field: \"sliceSpacing\")" in geometry_body
    assert (
        "try consistentValue(in: imageOrientationPatients, field: \"imageOrientationPatient\")"
        in geometry_body
    )
    assert "firstPix.flatMap { pix -> [Double]?" not in geometry_body
    assert "firstPix.flatMap { pix -> Double?" not in geometry_body
    assert "firstPix.flatMap { orientationPatient(from: $0) }" not in geometry_body


def test_image_orientation_patient_contract_returns_six_dicom_cosines():
    source = _read(EXPORT_SWIFT)
    orientation_start = source.find("private func orientationPatient")
    orientation_end = source.find("private func normalizedAffine", orientation_start)
    orientation_body = source[orientation_start:orientation_end]

    assert "Array(orientation.prefix(6))" in orientation_body
    assert "return orientation" not in orientation_body


def test_segmentation_updates_job_snapshot_before_launch_and_passes_same_job_downstream():
    source = _read(SEGMENTATION_SWIFT)

    assert "var jobManifest = exportResult.jobManifest" in source
    assert "snapshotForRun" in source
    assert "environmentSnapshot" in source
    assert "canonicalOutputPaths" in source
    assert "persistSegmentationJobManifest" in source
    assert "jobManifestURL" in source
    assert "persistAuditMetadata" in source


def test_segmentation_persists_terminal_job_manifest_for_failed_and_cancelled_runs():
    source = _read(SEGMENTATION_SWIFT)

    assert "persistTerminalSegmentationJobManifest" in source
    helper_start = source.find("private func persistTerminalSegmentationJobManifest")
    helper_end = source.find("\n    static func snapshotForRun", helper_start)
    helper = source[helper_start:helper_end]
    assert 'runState = "failed"' not in source[source.find("if process.terminationStatus == 0") :]
    assert "manifest.runState = runState" in helper
    assert "persistSegmentationJobManifest(manifest, to: exportContext.jobManifestURL)" in helper
    assert 'runState: "completed"' in source
    assert 'runState: "cancelled"' in source
    assert 'runState: "failed"' in source


def test_audit_references_job_uuid_and_manifest_hash():
    types_source = _read(TYPES_SWIFT)
    audit_source = _read(AUDIT_SWIFT)

    assert "jobUUID" in types_source
    assert "jobManifestHash" in types_source
    assert "jobManifestPath" in types_source
    assert "exportContext.jobManifest" in audit_source
    assert "exportContext.jobManifestURL" in audit_source


def test_readme_documents_immutable_job_manifest():
    readme = _read(README)

    assert "segmentation-job.json" in readme
    assert "source identity hash" in readme
    assert "DICOM LPS" in readme
