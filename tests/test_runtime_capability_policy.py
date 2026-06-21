import importlib
import sys
import types
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "MyOsiriXPluginFolder-Swift"
BRIDGE_ROOT = SWIFT_DIR / "python_bridge"
PLUGIN_SWIFT = SWIFT_DIR / "Plugin.swift"
SEGMENTATION_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Segmentation.swift"
SETTINGS_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Settings.swift"
TYPES_SWIFT = SWIFT_DIR / "TotalSegmentatorPluginTypes.swift"
RUNTIME_SWIFT = SWIFT_DIR / "TotalSegmentatorRuntimeCapabilities.swift"
AUDIT_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Audit.swift"
PROJECT_FILES = [
    SWIFT_DIR / "TotalSegmentatorHorosPlugin.xcodeproj" / "project.pbxproj",
    SWIFT_DIR / "TotalSegmentatorHorosPlugin.xcodeproj" / "project_Horos.pbxproj",
    SWIFT_DIR / "TotalSegmentatorHorosPlugin.xcodeproj" / "project_OsiriX.pbxproj",
]


def _read(path: Path) -> str:
    """
    Read the UTF-8 text contents of a file.

    Returns:
    	str: The text contents of the file.
    """
    return path.read_text(encoding="utf-8")


def _load_runtime_module():
    """
    Load the runtime capabilities module with an isolated import path.

    Returns:
        The ts_horos_bridge.runtime_capabilities module.
    """
    original_path = list(sys.path)
    try:
        sys.path.insert(0, str(BRIDGE_ROOT))
        sys.modules.pop("ts_horos_bridge.runtime_capabilities", None)
        return importlib.import_module("ts_horos_bridge.runtime_capabilities")
    finally:
        sys.path[:] = original_path


def test_runtime_module_loader_restores_sys_path_after_import():
    original_path = list(sys.path)
    try:
        while str(BRIDGE_ROOT) in sys.path:
            sys.path.remove(str(BRIDGE_ROOT))
        baseline_path = list(sys.path)

        runtime = _load_runtime_module()

        assert runtime.__name__ == "ts_horos_bridge.runtime_capabilities"
        assert sys.path == baseline_path
    finally:
        sys.path[:] = original_path


def test_runtime_capability_probe_uses_absolute_vm_stat_path():
    source = _read(BRIDGE_ROOT / "ts_horos_bridge" / "runtime_capabilities.py")

    assert 'subprocess.check_output(["/usr/bin/vm_stat"]' in source
    assert 'subprocess.check_output(["vm_stat"]' not in source


def _fake_torch(cuda=None, mps_available=False, mps_built=True, smoke_ok=True, convtranspose_ok=True):
    """
    Create a minimal torch-like module for testing with configurable CUDA and MPS availability.

    Parameters:
        cuda: Optional CUDA-like object. If provided, it is exposed in the returned module.
        mps_available: Whether MPS reports as available.
        mps_built: Whether MPS reports as built.
        smoke_ok: If False, tensor operations on the "mps" device raise RuntimeError.
        convtranspose_ok: If False, ConvTranspose3d operations on the "mps" device raise RuntimeError.

    Returns:
        A namespace object mimicking a torch module with the specified configuration.
    """
    class _FakeTensor:
        def __init__(self, device):
            self.device = device

        def __add__(self, other):
            if self.device == "mps" and not smoke_ok:
                raise RuntimeError("mps operator unavailable")
            return self

        def sum(self):
            return self

        def item(self):
            return 2.0

    class _FakeMPS:
        @staticmethod
        def is_available():
            return mps_available

        @staticmethod
        def is_built():
            return mps_built

    def tensor(values, device="cpu"):
        """Create a fake tensor with the specified device."""
        return _FakeTensor(device)

    def ones(shape, device="cpu"):
        return _FakeTensor(device)

    class _FakeConvTranspose3d:
        def __init__(self, in_channels, out_channels, kernel_size):
            self.device = "cpu"

        def to(self, device):
            self.device = device
            return self

        def __call__(self, tensor):
            if self.device == "mps" and not convtranspose_ok:
                raise RuntimeError("ConvTranspose 3D is not supported on MPS")
            return tensor

    return types.SimpleNamespace(
        __version__="2.6.0-test",
        version=types.SimpleNamespace(cuda="12.4" if cuda else None),
        cuda=cuda or types.SimpleNamespace(is_available=lambda: False, device_count=lambda: 0),
        backends=types.SimpleNamespace(mps=_FakeMPS()),
        nn=types.SimpleNamespace(ConvTranspose3d=_FakeConvTranspose3d),
        tensor=tensor,
        ones=ones,
    )


def test_runtime_probe_reports_cpu_only_without_accelerators():
    runtime = _load_runtime_module()
    payload = runtime.probe_runtime_capabilities(
        torch_module=_fake_torch(),
        available_memory_mb=8192,
        import_status={"cucim": False, "cupy": False},
    )

    assert payload["schema_version"] == 1
    assert payload["probe_version"]
    assert payload["available_memory_mb"] == 8192
    assert payload["backend_recognized_device_values"] == ["cpu", "gpu", "mps"]
    devices = {device["value"]: device for device in payload["devices"]}
    assert devices["cpu"]["available"] is True
    assert devices["cpu"]["validated"] is True
    assert devices["gpu"]["available"] is False
    assert devices["mps"]["available"] is False
    assert payload["resampling_backends"]["cucim"] is False
    assert payload["resampling_backends"]["cupy"] is False


def test_runtime_probe_reports_available_cuda_details():
    runtime = _load_runtime_module()

    cuda = types.SimpleNamespace(
        is_available=lambda: True,
        device_count=lambda: 1,
        get_device_name=lambda index: "NVIDIA Test GPU",
        get_device_capability=lambda index: (8, 9),
        mem_get_info=lambda index=0: (12 * 1024**3, 16 * 1024**3),
    )
    payload = runtime.probe_runtime_capabilities(
        torch_module=_fake_torch(cuda=cuda),
        available_memory_mb=32768,
        import_status={"cucim": True, "cupy": True},
    )

    gpu = {device["value"]: device for device in payload["devices"]}["gpu"]
    assert gpu["available"] is True
    assert gpu["validated"] is True
    assert gpu["name"] == "NVIDIA Test GPU"
    assert gpu["compute_capability"] == "8.9"
    assert gpu["usable_memory_mb"] >= 12000
    assert payload["torch"]["cuda_version"] == "12.4"


def test_runtime_probe_hides_mps_when_required_smoke_test_fails():
    runtime = _load_runtime_module()
    payload = runtime.probe_runtime_capabilities(
        torch_module=_fake_torch(mps_available=True, smoke_ok=False),
        available_memory_mb=16384,
        import_status={"cucim": False, "cupy": False},
    )

    mps = {device["value"]: device for device in payload["devices"]}["mps"]
    assert mps["available"] is False
    assert mps["validated"] is False
    assert "smoke" in mps["reason"].lower()


def test_runtime_probe_hides_mps_when_nnunet_operator_probe_fails():
    runtime = _load_runtime_module()
    payload = runtime.probe_runtime_capabilities(
        torch_module=_fake_torch(mps_available=True, smoke_ok=True, convtranspose_ok=False),
        available_memory_mb=16384,
        import_status={"cucim": False, "cupy": False},
    )

    mps = {device["value"]: device for device in payload["devices"]}["mps"]
    assert mps["available"] is False
    assert mps["validated"] is False
    assert "convtranspose3d" in mps["reason"].lower()


def test_swift_contract_defines_runtime_probe_and_policy_types():
    source = _read(RUNTIME_SWIFT)

    for symbol in [
        "struct RuntimeCapabilityProbe: Codable",
        "struct RuntimeDeviceCapability: Codable",
        "struct RuntimeExecutionPolicy",
        "enum RuntimeCapabilityPolicyError: LocalizedError",
        "requestedQuality",
        "effectiveQuality",
        "selectionReason",
        "probeFailures",
        "runtimeProbe",
        "insufficientMemory",
        "unsupportedQuality",
        "availableMemoryMB < 2_048",
        "availableMemoryMB < 8_192",
    ]:
        assert symbol in source


def test_swift_device_options_are_not_static_gpu_mps_menu_values():
    """
    Ensure Swift device options dynamically resolve runtime devices instead of using static GPU/MPS menu values.
    """
    source = _read(PLUGIN_SWIFT)

    assert '("gpu", "gpu")' not in source
    assert '("mps", "mps")' not in source
    assert "runtimeDeviceOptions" in source
    assert "fallbackRuntimeCapabilityProbe" in source


def test_settings_device_menu_uses_runtime_probe_options():
    source = _read(SETTINGS_SWIFT)

    assert "settingsDeviceOptions" in source
    assert "probeRuntimeCapabilities" in source
    assert "populateDevicePopupButton" in source
    assert "configureSettingsInterfaceIfNeeded(deviceOptions:" in source
    assert "populateSettingsUI(deviceOptions:" in source


def test_segmentation_run_uses_policy_for_cli_arguments_and_provenance():
    segmentation = _read(SEGMENTATION_SWIFT)
    audit = _read(AUDIT_SWIFT)

    for symbol in [
        "probeRuntimeCapabilities",
        "resolveRuntimeExecutionPolicy",
        "runtimePolicy.cliArguments",
        "runtimePolicy.effectiveDevice",
        "runtimePolicy.effectiveQuality",
        "runtimePolicy.selectionReason",
    ]:
        assert symbol in segmentation

    assert "runtimeProbe: RuntimeCapabilityProbe?" in audit
    assert "runtimeCapabilityProbe" in audit


def test_runtime_policy_source_is_bundled_in_xcode_projects():
    """
    Verify that the runtime capabilities Swift source is included in all Xcode projects.

    Confirms that TotalSegmentatorRuntimeCapabilities.swift is present and properly bundled
    as a source file in each project.
    """
    for project_file in PROJECT_FILES:
        project = _read(project_file)
        assert "TotalSegmentatorRuntimeCapabilities.swift" in project
        assert "TotalSegmentatorRuntimeCapabilities.swift in Sources" in project
