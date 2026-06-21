from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "MyOsiriXPluginFolder-Swift"
TYPES_SWIFT = SWIFT_DIR / "TotalSegmentatorPluginTypes.swift"
AUDIT_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Audit.swift"
SEGMENTATION_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Segmentation.swift"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read the contents of a file as UTF-8 text.

    Returns:
    	content (str): The file contents
    """
    return path.read_text(encoding="utf-8")


def test_provenance_schema_captures_identity_runtime_configuration_and_integrity():
    """
    Validate that the Swift types file defines the expected provenance schema structures and integrity metadata fields.
    """
    source = _read(TYPES_SWIFT)

    for symbol in [
        "struct SegmentationProvenanceRecord: Codable",
        "struct SegmentationRunStageOutcome: Codable",
        "struct SegmentationSourceIdentityProvenance: Codable",
        "struct SegmentationRuntimeProvenance: Codable",
        "struct SegmentationConfigurationProvenance: Codable",
        "struct SegmentationBackendProvenance: Codable",
        "struct SegmentationDiagnosticSummary: Codable",
        "static let currentSchemaVersion = 1",
        "jobManifestSchemaVersion",
        "jobManifestHash",
        "sourceIdentityHash",
        "orderedSOPInstanceUIDsHash",
        "requestedDevice",
        "effectiveDevice",
        "requestedQuality",
        "effectiveQuality",
        "normalizedCLIArguments",
        "stageOutcomes",
        "acceptedArtifacts",
        "completionManifestHash",
        "warnings",
        "fallbackUsed",
    ]:
        assert symbol in source


def test_run_workspace_tracks_provenance_and_diagnostic_summary_files():
    types = _read(TYPES_SWIFT)
    segmentation = _read(SEGMENTATION_SWIFT)
    audit = _read(AUDIT_SWIFT)

    assert "provenanceManifestURL" in types
    assert "diagnosticSummaryURL" in types
    assert "provenance.json" in segmentation
    assert "diagnostic-summary.json" in segmentation
    assert "persistSegmentationProvenance" in segmentation
    assert "persistDiagnosticSummary" in audit
    assert "validateProvenanceRecord" in audit


def test_audit_persistence_is_atomic_and_handles_corrupt_jsonl():
    """
    Verify that audit log persistence uses atomic operations and includes validation and quarantine logic for corrupt JSONL entries.
    """
    audit = _read(AUDIT_SWIFT)

    assert "appendAuditEntryAtomically" in audit
    assert "validateAuditLogLine" in audit
    assert "quarantineCorruptAuditLog" in audit
    assert ".atomic" in audit
    assert ".corrupt-" in audit


def test_artifact_integrity_hashing_streams_files_incrementally():
    audit = _read(AUDIT_SWIFT)
    hash_start = audit.find("private func sha256ForAudit(of fileURL: URL)")
    hash_end = audit.find("\n    private func relativeProvenancePath", hash_start)
    if hash_end == -1:
        hash_end = audit.find("\n}", hash_start)
    hash_body = audit[hash_start:hash_end]

    assert "FileHandle(forReadingFrom: fileURL)" in hash_body
    assert "readData(ofLength:" in hash_body
    assert "hasher.update(data:" in hash_body
    assert "Data(contentsOf: fileURL)" not in hash_body


def test_diagnostic_export_redacts_phi_paths_and_secrets_by_default():
    audit = _read(AUDIT_SWIFT)

    for symbol in [
        "makeDiagnosticSummary",
        "redactedDiagnosticString",
        "redactedCommandLineArguments",
        "redactedSourceIdentity",
        "containsSensitiveDiagnosticToken",
        "sourceDICOMIncluded: false",
        "directPatientIdentifiersIncluded: false",
        "license",
        "token",
        "password",
        "secret",
    ]:
        assert symbol in audit

    assert "sourceFiles" not in audit[audit.find("makeDiagnosticSummary"):audit.find("persistDiagnosticSummary")]


def test_audit_log_redacts_additional_arguments_before_serialization():
    audit = _read(AUDIT_SWIFT)
    persist_start = audit.find("func persistAuditMetadata")
    persist_end = audit.find("@discardableResult", persist_start)
    persist_body = audit[persist_start:persist_end]

    assert "let redactedAdditionalArguments" in persist_body
    assert "redactedCommandLineArguments(Self.tokenize(commandLine: additionalArguments))" in persist_body
    assert "additionalArguments: redactedAdditionalArguments" in persist_body
    assert "additionalArguments: preferences.additionalArguments" not in persist_body


def test_provenance_records_success_failure_cancellation_and_artifact_mismatch():
    audit = _read(AUDIT_SWIFT)
    segmentation = _read(SEGMENTATION_SWIFT)
    types = _read(TYPES_SWIFT)

    assert "let artifactIntegrityMismatches = verifyArtifactIntegrity(" in audit
    assert "let startedAt: Date?" in types[types.find("struct SegmentationProvenanceRecord: Codable"):]
    assert "let endedAt: Date?" in types[types.find("struct SegmentationProvenanceRecord: Codable"):]
    assert "let processExitStatus: Int?" in types[types.find("struct SegmentationProvenanceRecord: Codable"):]
    assert "startedAt: startedAt" in audit
    assert "endedAt: endedAt" in audit
    assert "processExitStatus: processExitStatus" in audit
    assert "processExitStatus: Int(process.terminationStatus)" in segmentation
    assert "cancellationRequested: cancellationRequested" in audit
    assert "artifactIntegrityMismatches: artifactIntegrityMismatches" in audit
    assert "stage: \"inference\"" in segmentation
    assert "stage: \"postProcessing\"" in segmentation
    assert "inferenceStatus = \"cancelled\"" in segmentation
    assert "postProcessingStatus = \"failed\"" in segmentation
    assert "finalRunState = didRequestCancellation ? \"cancelled\" : \"failed\"" in segmentation
    assert "finalRunState = \"completed\"" in segmentation
    assert "postProcessingStatus = \"completed\"" in segmentation


def test_readme_documents_safe_diagnostic_provenance():
    readme = _read(README)

    assert "provenance.json" in readme
    assert "diagnostic-summary.json" in readme
    assert "source DICOM" in readme
    assert "plaintext license" in readme
