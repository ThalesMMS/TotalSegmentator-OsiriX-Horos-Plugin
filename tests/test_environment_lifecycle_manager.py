from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TYPES_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorPluginTypes.swift"
ENVIRONMENT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Environment.swift"
SEGMENTATION_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Segmentation.swift"
PLUGIN_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "Plugin.swift"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read and return the contents of a file as a string using UTF-8 encoding.
    
    Parameters:
    	path (Path): A pathlib.Path object pointing to the file to read.
    
    Returns:
    	str: The full file contents.
    """
    return path.read_text(encoding="utf-8")


def test_lifecycle_manager_serializes_and_coalesces_callers():
    types_source = _read(TYPES_SWIFT)
    plugin_source = _read(PLUGIN_SWIFT)

    assert "final class EnvironmentLifecycleManager" in types_source
    assert "NSCondition" in types_source
    assert "operationInFlight" in types_source
    assert ".wait()" in types_source
    assert ".broadcast()" in types_source
    assert "EnvironmentReadinessResult" in types_source
    assert "sharedEnvironmentLifecycleManager" in plugin_source
    assert "prepareEnvironmentIfNeeded" in plugin_source


def test_lifecycle_uses_process_lock_and_install_marker():
    environment_source = _read(ENVIRONMENT_SWIFT)

    assert "import Darwin" in environment_source
    assert "EnvironmentProcessLock" in environment_source
    assert "flock" in environment_source
    assert "LOCK_EX | LOCK_NB" in environment_source
    assert "environment-setup.lock" in environment_source
    assert "environment-install-marker.json" in environment_source
    assert "recordEnvironmentMutationMarker" in environment_source
    assert "targetLockIdentifier" in environment_source
    assert "currentManifestIdentifier" in environment_source
    assert "healthStatus" in environment_source
    assert "recoverAbandonedEnvironmentInstallMarker" in environment_source


def test_readiness_result_separates_environment_weights_and_dcm2niix():
    types_source = _read(TYPES_SWIFT)

    assert "enum EnvironmentLifecycleState" in types_source
    assert "enum EnvironmentReadinessError" in types_source
    assert "struct EnvironmentReadinessResult" in types_source
    assert "packageEnvironmentReady" in types_source
    assert "modelWeightsReady" in types_source
    assert "dcm2niixReady" in types_source
    assert "var isReady" in types_source
    assert "case processLockUnavailable" in types_source
    assert "case interruptedInstallRecovered" in types_source


def test_segmentation_and_startup_use_typed_readiness_before_export_and_inference():
    segmentation_source = _read(SEGMENTATION_SWIFT)
    plugin_source = _read(PLUGIN_SWIFT)

    assert "let environmentResult = prepareEnvironmentIfNeeded(progressController: nil)" in segmentation_source
    assert "guard environmentResult.isReady" in segmentation_source
    assert "let environmentResult = prepareEnvironmentIfNeeded(progressController: progressController)" in segmentation_source
    assert "environmentResult.failureMessage" in segmentation_source
    assert "prepareEnvironmentIfNeeded()" in plugin_source


def test_progress_and_docs_describe_repair_and_lifecycle_states():
    environment_source = _read(ENVIRONMENT_SWIFT)
    readme = _read(README)

    for message in [
        "Checking pinned Python environment",
        "Installing pinned TotalSegmentator environment",
        "Validating pinned Python environment",
        "Preparing TotalSegmentator model weights",
        "Preparing pinned dcm2niix",
        "Environment ready",
        "Detected interrupted environment setup",
    ]:
        assert message in environment_source

    assert "environment-install-marker.json" in readme
    assert "environment-setup.lock" in readme
    assert "repair" in readme.lower()
