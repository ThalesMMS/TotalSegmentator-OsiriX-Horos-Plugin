from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TYPES_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorPluginTypes.swift"
SEGMENTATION_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Segmentation.swift"
IMPORT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read a file using UTF-8 encoding and return its contents as a string.
    
    Returns:
        str: The file contents.
    """
    return path.read_text(encoding="utf-8")


def test_run_workspace_schema_tracks_persistent_transactional_layout():
    source = _read(TYPES_SWIFT)

    assert "struct SegmentationRunWorkspace" in source
    assert "struct SegmentationRunCompletionManifest: Codable" in source
    assert "struct SegmentationArtifactRecord: Codable" in source
    for field in [
        "rootDirectory",
        "inputDirectory",
        "workDirectory",
        "outputDirectory",
        "completionManifestURL",
        "jobManifestURL",
        "exportManifestURL",
        "publicationBaseDirectory",
        "publishedOutputDirectory",
        "jobUUID",
        "sourceIdentityHash",
        "artifactCount",
        "artifacts",
        "sha256",
        "byteCount",
    ]:
        assert field in source


def test_segmentation_uses_uuid_run_workspace_instead_of_live_user_output_directory():
    source = _read(SEGMENTATION_SWIFT)

    assert "makeRunWorkspace" in source
    assert "pluginRunWorkspacesDirectory" in source
    assert "runs" in source
    assert "jobManifest.jobUUID" in source
    assert "runWorkspace.outputDirectory" in source
    assert "publishedOutputDirectory" in source
    assert "publicationBaseDirectory" in source
    assert "resolvePublicationDirectoryIfProvided" in source

    launch_block_start = source.find("let runWorkspace")
    launch_block_end = source.find("prepareBridgeScript", launch_block_start)
    assert "resolveOutputDirectory(using:" not in source[launch_block_start:launch_block_end]


def test_validation_requires_expected_nifti_artifacts_not_any_regular_file():
    source = _read(IMPORT_SWIFT)

    assert "validateSegmentationOutput(at outputDirectory: URL, for jobManifest: SegmentationJobManifest)" in source
    assert "collectValidatedRunArtifacts" in source
    assert "isLikelyNiftiFile" in source
    assert "expectedArtifactMissing" in source
    assert "outputArtifactEmpty" in source

    validation_start = source.find("func validateSegmentationOutput")
    validation_end = source.find("func translateErrorOutput", validation_start)
    validation_block = source[validation_start:validation_end]
    assert "return" not in validation_block.split("throw SegmentationValidationError.expectedArtifactMissing")[0]
    assert "values.isRegularFile == true" in validation_block


def test_artifact_kind_classifies_known_outputs_before_dicom_metadata_probe():
    source = _read(IMPORT_SWIFT)

    method_start = source.find("private func runArtifactKind")
    method_end = source.find("private func relativeRunArtifactPath", method_start)
    method = source[method_start:method_end]

    rtstruct_probe = method.find("isLikelyRTStruct(at: url)")
    dicom_probe = method.find("isLikelyDicomFile(at: url)")
    volumetric_manifest = method.find('url.lastPathComponent == "manifest.json"')
    volumetric_mask = method.find('url.pathExtension.lowercased() == "raw"')

    assert volumetric_manifest < dicom_probe
    assert volumetric_mask < dicom_probe
    assert dicom_probe < rtstruct_probe


def test_success_writes_completion_and_publishes_only_validated_job_artifacts():
    segmentation = _read(SEGMENTATION_SWIFT)
    imports = _read(IMPORT_SWIFT)

    assert "persistRunCompletionManifest" in imports
    assert "completion.json" in segmentation
    assert ".atomic" in imports
    assert "publishValidatedRunOutput" in segmentation
    assert ".staging" in segmentation
    assert "copyRunOutputContents" in segmentation
    assert "completionManifestURL" in segmentation
    assert "runCompletionManifestPath" in segmentation


def test_readme_documents_transactional_workspace_and_completion_manifest():
    readme = _read(README)

    assert "runs/<jobUUID>" in readme
    assert "completion.json" in readme
    assert "validated artifacts" in readme
