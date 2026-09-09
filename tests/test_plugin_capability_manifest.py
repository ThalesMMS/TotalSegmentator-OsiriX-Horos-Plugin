import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorTaskCapabilities.json"
PLUGIN_SWIFT_PATH = ROOT / "MyOsiriXPluginFolder-Swift" / "Plugin.swift"
CONTRACT_PATH = ROOT / "tests" / "fixtures" / "totalsegmentator-2.18.0-contract.json"


def _contract() -> dict:
    """Load reviewed metadata for the installed backend, not the 2.11 reference tree.

    The fixture records the immutable upstream commit and source identities.
    tools/validate_backend_upgrade.py --installed independently compares them
    with the installed distribution without importing the checkout's backend.
    """
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


def _manifest() -> dict:
    """
    Load the task capability manifest.

    Returns:
        dict: The parsed capability manifest dictionary.
    """
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def test_manifest_tasks_are_accepted_by_pinned_cli_choices():
    contract = _contract()
    manifest_tasks = {task["identifier"] for task in _manifest()["tasks"]}
    assert manifest_tasks
    assert manifest_tasks == set(contract["tasks"]) - set(contract["excludedTasks"])


def test_manifest_roi_subset_tasks_exist_in_backend_class_map():
    supported = set(_contract()["roiSubsetTasks"])
    selected = {task["identifier"] for task in _manifest()["tasks"] if task["supportsRoiSubset"]}
    assert selected == supported - set(_contract()["excludedTasks"])


def test_manifest_license_requirements_match_backend_commercial_models():
    manifest = _manifest()["tasks"]
    exposed = {task["identifier"] for task in manifest}
    commercial = {task["identifier"] for task in manifest if task["requiresLicense"]}
    # Deprecated/report-only commercial models need not appear in the picker.
    assert commercial == set(_contract()["commercialTasks"]) & exposed
    assert not next(task for task in manifest if task["identifier"] == "vertebrae_body")["requiresLicense"]


def test_manifest_fast_modes_do_not_conflict_with_backend_rejections():
    quality_modes = _contract()["qualityModes"]
    for task in _manifest()["tasks"]:
        assert task["qualityModes"] == quality_modes.get(task["identifier"], ["normal"])


def test_manifest_non_multilabel_tasks_are_documented_backend_exceptions():
    # In 2.18 the replacement lung_vessels model uses the normal multilabel
    # output path. Its old two-mask model is now lung_vessels_LEGACY (excluded).
    non_multilabel_tasks = {task["identifier"] for task in _manifest()["tasks"] if not task["supportsMultilabel"]}
    assert non_multilabel_tasks == set()


def test_manifest_contains_no_anatomy_aliases_as_task_identifiers():
    invalid_aliases = {
        "lung", "heart", "kidney", "liver", "pelvis", "prostate", "spleen",
        "pancreas", "headneck", "femur", "hip", "vertebrae",
    }
    manifest_tasks = {task["identifier"] for task in _manifest()["tasks"]}
    assert manifest_tasks.isdisjoint(invalid_aliases)


def test_manifest_and_environment_lock_target_the_same_release():
    lock_path = MANIFEST_PATH.with_name("TotalSegmentatorEnvironmentLock.json")
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    assert lock["backend"]["version"] == _manifest()["backendVersion"] == _contract()["engineVersion"] == "2.18.0"
    package = next(package for package in lock["packages"] if package["distributionName"] == "TotalSegmentator")
    assert package["requirement"] == "TotalSegmentator==2.18.0"
    assert package["exactVersion"] == "2.18.0"


def test_manifest_modality_matches_upstream_registry():
    for task in _manifest()["tasks"]:
        identifier = task["identifier"]
        modality = "MR" if identifier.endswith("_mr") or identifier in _contract()["mrTasksWithoutSuffix"] else "CT"
        assert task["supportedModalities"] == [modality]
    aneurysm = next(task for task in _manifest()["tasks"] if task["identifier"] == "brain_aneurysm")
    assert "TOF" in aneurysm["description"]


def test_unsafe_standalone_and_prerelease_tasks_stay_excluded():
    excluded = _contract()["excludedTasks"]
    assert {"total_v3", "renal_arteries", "aorta_annulus", "aortic_dissection"} <= set(excluded)
    assert all(excluded.values())
    assert _manifest()["defaultTask"] == "total"


def test_swift_task_options_are_derived_from_capability_manifest():
    """
    Validate that the Swift plugin derives task options from the capability manifest instead of hardcoding them.
    """
    source = PLUGIN_SWIFT_PATH.read_text(encoding="utf-8")
    types_source = (ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorPluginTypes.swift").read_text(
        encoding="utf-8"
    )

    assert "taskCapabilityManifest" in source
    assert "taskGroupsFromCapabilityManifest" in source
    assert "TaskOption(" not in source
    assert "fatalError(error.localizedDescription)" not in types_source


def test_swift_task_capability_manifest_load_failure_is_nonfatal_and_user_visible():
    plugin_source = PLUGIN_SWIFT_PATH.read_text(encoding="utf-8")
    types_source = (ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorPluginTypes.swift").read_text(
        encoding="utf-8"
    )
    segmentation_source = (ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Segmentation.swift").read_text(
        encoding="utf-8"
    )

    assert "taskCapabilityManifestLoadError" in types_source
    assert "fallbackUnavailableManifest" in types_source
    assert "fatalError(" not in types_source[types_source.find("static let taskCapabilityManifest") :]
    assert "capabilityManifestIsAvailable" in plugin_source
    assert "presentCapabilityManifestLoadFailure" in plugin_source
    assert "guard Self.capabilityManifestIsAvailable else" in segmentation_source


def test_swift_does_not_reintroduce_invalid_task_values():
    source = PLUGIN_SWIFT_PATH.read_text(encoding="utf-8")
    invalid_aliases = [
        "lung", "heart", "kidney", "liver", "pelvis", "prostate", "spleen",
        "pancreas", "headneck", "femur", "hip", "vertebrae",
    ]

    for alias in invalid_aliases:
        assert not re.search(rf'value:\s*"{re.escape(alias)}"', source)
