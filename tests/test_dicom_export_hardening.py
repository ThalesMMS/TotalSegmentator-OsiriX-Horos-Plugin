from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
JOB_MANIFEST_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorJobManifestTypes.swift"
EXPORT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Export.swift"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read a file as UTF-8 text.

    Parameters:
    	path (Path): File path to read

    Returns:
    	str: File contents
    """
    return path.read_text(encoding="utf-8")


def test_export_manifest_schema_tracks_each_source_instance():
    source = _read(JOB_MANIFEST_SWIFT)

    assert "struct DicomExportManifest: Codable" in source
    assert "struct DicomExportedInstance: Codable" in source
    for field in [
        "sourcePathHash",
        "destinationName",
        "sopInstanceUID",
        "studyInstanceUID",
        "seriesInstanceUID",
        "frameOfReferenceUID",
        "modality",
        "sourceOrderIndex",
        "dicomFrameID",
        "frameCount",
        "byteCount",
        "sha256",
    ]:
        assert field in source


def test_export_uses_deterministic_sop_uid_destination_names():
    source = _read(EXPORT_SWIFT)

    assert "destinationFileName" in source
    assert "%06d_%@.dcm" in source
    assert "sanitizePathComponent(instance.sopInstanceUID)" in source
    assert "destinationURLs = sourceInstances.map" in source
    destination_block_start = source.find("destinationURLs = sourceInstances.map")
    destination_block_end = source.find("let copyResult", destination_block_start)
    assert "lastPathComponent" not in source[destination_block_start:destination_block_end]


def test_export_never_reuses_existing_destination_files():
    source = _read(EXPORT_SWIFT)

    copy_block_start = source.find("private static func copyDicomFile")
    copy_block_end = source.find("private func copyFilesInParallel", copy_block_start)
    assert "destinationCollision" in source[copy_block_start:copy_block_end]
    assert "return false" not in source[copy_block_start:copy_block_end]


def test_export_rejects_missing_duplicate_or_mixed_source_identity():
    source = _read(EXPORT_SWIFT)

    for case_name in [
        "missingSOPInstanceUID",
        "duplicateSOPInstanceUID",
        "mixedStudyInstanceUID",
        "mixedSeriesInstanceUID",
        "mixedFrameOfReferenceUID",
        "unsupportedDerivedSource",
    ]:
        assert case_name in source

    assert "validateSourceInstances" in source
    assert "sourceIdentityHash" in source
    assert "frameOfReferenceUID" in source


def test_export_validates_copied_files_and_persists_completion_marker():
    """
    Verify that the DICOM export implementation includes copied file validation and completion marker persistence.

    Asserts the presence of validation functions, persistence functions, atomic write operations, and directory cleanup logic.
    """
    source = _read(EXPORT_SWIFT)

    assert "validateCopiedExportFiles" in source
    assert "emptyExportedFile" in source
    assert "destinationCollision" in source
    assert "dicom-export-manifest.json" in source
    assert "export-complete.json" in source
    assert "persistDicomExportManifest" in source
    assert "persistExportCompletionMarker" in source
    assert ".atomic" in source
    assert "cleanupTemporaryDirectory(exportDirectory)" in source


def test_study_export_manifest_uses_same_primary_series_instances_as_job_manifest():
    source = _read(EXPORT_SWIFT)
    study_export_start = source.find("private func exportCompatibleSeries")
    study_export_end = source.find("private func exportSeries", study_export_start)
    study_export = source[study_export_start:study_export_end]

    assert "primaryPreparedSeries.validatedInstances" in study_export
    assert "validatedInstances: allValidatedInstances" not in study_export


def test_readme_mentions_collision_safe_export_manifest():
    readme = _read(README)

    assert "dicom-export-manifest.json" in readme
    assert "collision-safe" in readme
