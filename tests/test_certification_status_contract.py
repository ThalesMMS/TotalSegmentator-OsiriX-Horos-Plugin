import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "MyOsiriXPluginFolder-Swift"
PLUGIN_SOURCE = SWIFT_DIR / "Plugin.swift"
SETTINGS_SOURCE = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Settings.swift"
SEGMENTATION_SOURCE = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Segmentation.swift"
AUDIT_SOURCE = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Audit.swift"
TYPES_SOURCE = SWIFT_DIR / "TotalSegmentatorPluginTypes.swift"
INFO_PLIST = SWIFT_DIR / "Info.plist"
README_PATH = ROOT / "README.md"
ADR_PATH = ROOT / "docs" / "adr" / "0001-slicer-parity-robustness-and-clinical-boundary.md"
CHECKLIST_PATH = ROOT / "docs" / "release" / "robustness-release-checklist.md"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _read_plist(path: Path) -> dict:
    with path.open("rb") as file:
        return plistlib.load(file)


def test_host_medical_imaging_flag_defaults_to_non_certified_status():
    plugin_source = _read(PLUGIN_SOURCE)

    assert "override func isCertifiedForMedicalImaging() -> Bool" in plugin_source
    assert "return Self.medicalImagingCertified" in plugin_source
    assert "return true" not in plugin_source
    assert "certificationStatusIdentifier" in plugin_source
    assert "validationEvidenceVersion" in plugin_source

    assert "production-validation" in plugin_source


def test_package_metadata_is_conservative_and_release_configurable():
    metadata = _read_plist(INFO_PLIST)

    assert metadata["TotalSegmentatorCertificationStatusIdentifier"] == "research-non-diagnostic"
    assert metadata["TotalSegmentatorCertificationStatusDisplayName"] == "Research/non-diagnostic"
    assert metadata["TotalSegmentatorMedicalImagingCertified"] is False
    assert metadata["TotalSegmentatorValidationEvidenceVersion"] == "none"


def test_ui_and_run_log_report_non_diagnostic_status():
    settings_source = _read(SETTINGS_SOURCE)
    segmentation_source = _read(SEGMENTATION_SOURCE)

    assert "certificationStatusDisplayName" in settings_source
    assert "certificationNotice" in segmentation_source
    assert "progressController.append(Self.certificationNotice)" in segmentation_source


def test_settings_capability_controls_refresh_class_summary_after_clearing_unsupported_classes():
    settings_source = _read(SETTINGS_SOURCE)
    start = settings_source.find("private func updateSettingsCapabilityControls")
    end = settings_source.find("func persistPreferencesFromUI", start)
    body = settings_source[start:end]

    assert "if !supportsClasses, !selectedClassNames.isEmpty" in body
    assert "selectedClassNames.removeAll()\n            updateClassSelectionSummary()" in body


def test_audit_provenance_records_certification_status():
    audit_source = _read(AUDIT_SOURCE)
    types_source = _read(TYPES_SOURCE)

    required_fields = [
        "certificationStatusIdentifier",
        "certificationStatusDisplayName",
        "medicalImagingCertified",
        "validationEvidenceVersion",
    ]
    for field in required_fields:
        assert field in types_source
        assert f"{field}: Self.{field}" in audit_source


def test_docs_explain_host_flag_and_evidence_gate():
    readme = _read(README_PATH)
    adr = _read(ADR_PATH)
    checklist = _read(CHECKLIST_PATH)

    assert "isCertifiedForMedicalImaging()" in readme
    assert "non-certified plugin warning" in readme
    assert "does not validate every TotalSegmentator task, anatomy, device, or input series" in readme

    assert "Horos/OsiriX host certification flag" in adr
    assert "validation evidence version" in adr

    assert "Host certification flag check" in checklist
    assert "TotalSegmentatorValidationEvidenceVersion" in checklist
    assert "must remain false" in checklist
