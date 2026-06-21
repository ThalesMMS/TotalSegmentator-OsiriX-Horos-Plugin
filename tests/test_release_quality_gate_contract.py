import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "release_quality_gate.schema.json"
HOST_SMOKE_TEMPLATE = ROOT / "docs" / "release" / "host-smoke-report-template.json"
CHECKLIST_PATH = ROOT / "docs" / "release" / "robustness-release-checklist.md"
README_PATH = ROOT / "README.md"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "release-quality-gate.yml"
PROJECT_PATH = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin.xcodeproj" / "project.pbxproj"
SCHEME_PATH = (
    ROOT
    / "MyOsiriXPluginFolder-Swift"
    / "TotalSegmentatorHorosPlugin.xcodeproj"
    / "xcshareddata"
    / "xcschemes"
    / "TotalSegmentatorHorosPlugin.xcscheme"
)


def _read(path: Path) -> str:
    """
    Read file contents as UTF-8 text.

    Returns:
    	str: The file contents
    """
    return path.read_text(encoding="utf-8")


def _load_json(path: Path) -> dict:
    """
    Load and parse JSON from a file.

    Returns:
        dict: The parsed JSON content.
    """
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def test_release_gate_schema_and_host_smoke_template_are_versioned_contracts():
    schema = _load_json(SCHEMA_PATH)
    template = _load_json(HOST_SMOKE_TEMPLATE)

    assert schema["schema_version"] == 1
    assert schema["title"] == "TotalSegmentator Horos/OsiriX Release Quality Gate"
    for required in [
        "supported_matrix",
        "automated_evidence",
        "geometry_corpus",
        "host_smoke_evidence",
        "artifact_retention",
        "certification_status",
        "sign_off",
    ]:
        assert required in schema["required"]

    assert template["schema_version"] == schema["schema_version"]
    assert template["geometry_corpus_version"] == "2026.06.geometry-v1"
    for scenario in [
        "install_load_plugin",
        "known_fixture_or_mocked_inference",
        "exact_source_viewer_roi_application",
        "safe_reopen_resync",
        "reject_unrelated_same_size_series",
        "cancel_and_recover",
        "provenance_and_cleanup",
    ]:
        assert scenario in template["host_smoke_scenarios"]


def test_release_gate_schema_constrains_nested_evidence_objects():
    schema = _load_json(SCHEMA_PATH)
    properties = schema["properties"]

    expected_nested_fields = {
        "supported_matrix": ["plugin_version", "git_commit", "host_apps", "macos", "python", "backend_lock"],
        "automated_evidence": ["pytest_junit_xml", "xcode_result_bundle", "test_command", "completed_at"],
        "geometry_corpus": ["corpus_version", "corpus_path", "round_trip_fixture", "negative_fixture_ids"],
        "artifact_retention": ["non_phi_artifacts", "retention_path", "excluded_artifacts"],
        "certification_status": ["status_identifier", "medical_imaging_certified", "validation_evidence_version"],
        "sign_off": ["release_candidate_tag", "approver", "approval_date"],
    }
    for object_name, required_fields in expected_nested_fields.items():
        object_schema = properties[object_name]
        assert object_schema["type"] == "object"
        assert object_schema["additionalProperties"] is False
        assert sorted(object_schema["properties"]) == sorted(required_fields)
        for field_name in required_fields:
            assert "type" in object_schema["properties"][field_name]

    host_smoke_schema = properties["host_smoke_evidence"]
    assert host_smoke_schema["type"] == "array"
    assert host_smoke_schema["minItems"] >= 1
    assert host_smoke_schema["items"]["additionalProperties"] is False
    assert sorted(host_smoke_schema["items"]["properties"]) == sorted(host_smoke_schema["items"]["required"])
    assert host_smoke_schema["items"]["properties"]["scenario_results"]["type"] == "object"


def test_ci_release_gate_runs_locked_python_tests_and_xcode_test_with_artifacts():
    """
    Verify that the release quality gate CI workflow is configured to run locked Python and Xcode tests with artifact uploads.
    """
    workflow = _read(WORKFLOW_PATH)

    assert "release-quality-gate" in workflow
    assert "TotalSegmentatorEnvironmentLock.json" in workflow
    assert "PythonEnvironment" in workflow
    assert "pytest" in workflow
    assert "--junitxml" in workflow
    assert "pytest-release-gate.xml" in workflow
    assert "xcodebuild" in workflow
    assert " test" in workflow
    assert "-resultBundlePath" in workflow
    assert "release-quality-gate.xcresult" in workflow
    assert "actions/upload-artifact" in workflow


def test_ci_release_gate_pins_actions_and_installs_from_environment_lock():
    workflow = _read(WORKFLOW_PATH)

    assert "uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5" in workflow
    assert "persist-credentials: false" in workflow
    assert "uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02" in workflow
    assert "uses: actions/checkout@v4" not in workflow
    assert "uses: actions/upload-artifact@v4" not in workflow
    assert '"\\n".join(' in workflow
    assert 'package["requirement"]' in workflow
    assert "-m pip install -r" in workflow
    assert "-m pip install pytest numpy nibabel pydicom" not in workflow


def test_xcode_project_exposes_a_real_host_independent_xctest_target():
    """
    Validate that the Xcode project exposes a real host-independent unit test target with the correct configuration.

    Asserts the Xcode project and shared scheme are properly configured:
    - `TotalSegmentatorHorosPluginTests` test target exists in the project
    - The project declares a unit test bundle type (`com.apple.product-type.bundle.unit-test`)
    - The project includes the contract test source file (`ReleaseGateContractTests.swift`)
    - The scheme references the test bundle (`TotalSegmentatorHorosPluginTests.xctest`)
    - The scheme has testable references configured
    """
    project = _read(PROJECT_PATH)
    scheme = _read(SCHEME_PATH)

    assert "TotalSegmentatorHorosPluginTests" in project
    assert "com.apple.product-type.bundle.unit-test" in project
    assert "ReleaseGateContractTests.swift in Sources" in project
    assert "TotalSegmentatorHorosPluginTests.xctest" in scheme
    assert "<TestableReference" in scheme


def test_release_docs_require_geometry_corpus_and_host_smoke_evidence_paths():
    checklist = _read(CHECKLIST_PATH)
    readme = _read(README_PATH)

    for phrase in [
        "release_quality_gate.schema.json",
        "host-smoke-report-template.json",
        "geometry-corpus.json",
        "pytest-release-gate.xml",
        "release-quality-gate.xcresult",
    ]:
        assert phrase in checklist

    assert "release-quality-gate" in readme
    assert "2026.06.geometry-v1" in readme
