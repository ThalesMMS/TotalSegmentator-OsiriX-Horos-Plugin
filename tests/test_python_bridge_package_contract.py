import ast
from contextlib import contextmanager
import hashlib
import importlib
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "MyOsiriXPluginFolder-Swift"
BRIDGE_ROOT = SWIFT_DIR / "python_bridge"
PACKAGE_ROOT = BRIDGE_ROOT / "ts_horos_bridge"
SCRIPTS_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Scripts.swift"
SEGMENTATION_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Segmentation.swift"
IMPORT_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Import.swift"
TYPES_SWIFT = SWIFT_DIR / "TotalSegmentatorPluginTypes.swift"
PROJECT_FILES = [
    SWIFT_DIR / "TotalSegmentatorHorosPlugin.xcodeproj" / "project.pbxproj",
    SWIFT_DIR / "TotalSegmentatorHorosPlugin.xcodeproj" / "project_Horos.pbxproj",
    SWIFT_DIR / "TotalSegmentatorHorosPlugin.xcodeproj" / "project_OsiriX.pbxproj",
]


def _read(path: Path) -> str:
    """
    Read a text file as a UTF-8 string.

    Parameters:
    	path (Path): The file path to read.

    Returns:
    	str: The file contents.
    """
    return path.read_text(encoding="utf-8")


def _bridge_package_hash() -> str:
    """
    Compute a SHA-256 hash of the bridge package directory.

    Excludes __pycache__ directories and .pyc files. The hash incorporates both the relative file paths and file contents.

    Returns:
        str: The hexadecimal digest string.
    """
    files = [
        path
        for path in BRIDGE_ROOT.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"
    ]
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda item: str(item)):
        digest.update(str(path.relative_to(BRIDGE_ROOT)).encode("utf-8"))
        digest.update(path.read_bytes())
    return digest.hexdigest()


@contextmanager
def _bridge_import_path():
    original_path = list(sys.path)
    try:
        sys.path.insert(0, str(BRIDGE_ROOT))
        yield
    finally:
        sys.path[:] = original_path


def _fresh_bridge_import(module_name: str):
    for cached_name in list(sys.modules):
        if cached_name == "ts_horos_bridge" or cached_name.startswith("ts_horos_bridge."):
            sys.modules.pop(cached_name, None)
    with _bridge_import_path():
        return importlib.import_module(module_name)


def test_fresh_bridge_import_clears_cached_modules_and_restores_sys_path():
    original_path = list(sys.path)
    cached_module = "ts_horos_bridge.nifti_conversion"
    sys.modules[cached_module] = object()

    package = _fresh_bridge_import("ts_horos_bridge")

    assert package.__name__ == "ts_horos_bridge"
    assert cached_module not in sys.modules
    assert sys.path == original_path


def test_python_bridge_is_versioned_package_and_bundled_resource():
    """
    Verify that the Python bridge package is properly versioned and bundled as a resource in the Swift project.

    Ensures the bridge package contains required files (pyproject.toml, __init__.py, cli.py, schemas.py), exposes a __version__ attribute, defines BRIDGE_SCHEMA_VERSION >= 1, and appears in all Swift Xcode project Resource configurations.
    """
    assert (BRIDGE_ROOT / "pyproject.toml").exists()
    assert (PACKAGE_ROOT / "__init__.py").exists()
    assert (PACKAGE_ROOT / "cli.py").exists()
    assert (PACKAGE_ROOT / "schemas.py").exists()

    package = _fresh_bridge_import("ts_horos_bridge")
    assert package.__version__
    assert package.BRIDGE_SCHEMA_VERSION >= 1

    for project_file in PROJECT_FILES:
        project = _read(project_file)
        assert "python_bridge in Resources" in project
        assert "path = python_bridge" in project


def test_swift_no_longer_embeds_runtime_python_programs():
    """
    Validate that Swift code delegates Python program execution to bundled bridge package mechanisms.

    Asserts that the Swift implementation no longer embeds Python source code or directly invokes subprocesses, and instead uses dedicated functions to resolve and copy the bundled bridge package.
    """
    source = _read(SCRIPTS_SWIFT)

    assert "scriptContents = \"\"\"" not in source
    assert "from totalsegmentator" not in source
    assert "subprocess.run(command" not in source
    assert "resolveBundledBridgeScript" in source
    assert "copyBundledBridgePackage" in source


def test_bridge_clis_are_normal_python_modules_with_entrypoints():
    """
    Verify that bridge CLI modules define a main entry point, except for the schemas module.
    """
    for module_name in [
        "ts_horos_bridge.cli",
        "ts_horos_bridge.nifti_conversion",
        "ts_horos_bridge.runtime_capabilities",
        "ts_horos_bridge.volumetric_projection",
        "ts_horos_bridge.schemas",
    ]:
        source_path = BRIDGE_ROOT / Path(*module_name.split(".")).with_suffix(".py")
        tree = ast.parse(_read(source_path))
        defined_functions = {node.name for node in tree.body if isinstance(node, ast.FunctionDef)}
        assert "main" in defined_functions or module_name.endswith("schemas")


def test_machine_results_use_result_files_not_final_stdout_line():
    scripts_source = _read(SCRIPTS_SWIFT)
    segmentation_source = _read(SEGMENTATION_SWIFT)
    import_source = _read(IMPORT_SWIFT)

    assert "--result" in segmentation_source
    assert "--result" in import_source
    assert "readBridgeResult" in scripts_source
    assert ".split(whereSeparator: \\.isNewline)" not in import_source
    assert "meaningfulLines" not in import_source


def test_bridge_result_reader_requires_expected_stage_to_be_present_and_matching():
    source = _read(SCRIPTS_SWIFT)
    reader_start = source.find("func readBridgeResult")
    reader_end = source.find("if let status = payload", reader_start)
    reader_body = source[reader_start:reader_end]

    assert "guard let stage = payload[\"stage\"] as? String" in reader_body
    assert "stage != expectedStage" in reader_body
    assert "missing" in reader_body.lower()


def test_bridge_version_hash_recorded_in_job_and_audit_contracts():
    """
    Verify that job and audit contract fields are present in all Swift source files.

    Asserts that `bridgeVersion`, `bridgeSchemaVersion`, and `bridgePackageHash` are defined
    in the types, segmentation, and scripts Swift modules.
    """
    scripts_source = _read(SCRIPTS_SWIFT)
    segmentation_source = _read(SEGMENTATION_SWIFT)
    types_source = _read(TYPES_SWIFT)

    for field in ["bridgeVersion", "bridgeSchemaVersion", "bridgePackageHash"]:
        assert field in types_source
        assert field in segmentation_source
        assert field in scripts_source


def test_bridge_request_schema_and_package_health_are_checked_before_inference():
    schemas = _fresh_bridge_import("ts_horos_bridge.schemas")

    schemas.validate_request_schema({"schema_version": schemas.BRIDGE_SCHEMA_VERSION})
    with pytest.raises(ValueError):
        schemas.validate_request_schema({"schema_version": schemas.BRIDGE_SCHEMA_VERSION + 1})

    scripts_source = _read(SCRIPTS_SWIFT)
    cli_source = _read(PACKAGE_ROOT / "cli.py")

    assert "schema_version" in scripts_source
    assert "verifyBundledBridgeHealth" in scripts_source
    assert "expectedBridgePackageHash" in scripts_source
    assert f'expectedBridgePackageHash = "{_bridge_package_hash()}"' in scripts_source
    assert "validate_request_schema(config)" in cli_source
    main_source = cli_source[cli_source.index("def main()"):]
    assert main_source.index("validate_request_schema(config)") < main_source.index("run_totalsegmentator_command(command)")


def test_swift_bridge_hash_uses_canonical_relative_paths():
    scripts_source = _read(SCRIPTS_SWIFT)
    hash_start = scripts_source.index("func bridgePackageHash(for packageURL: URL) throws -> String")
    hash_end = scripts_source.index("    /// Validates", hash_start)
    hash_body = scripts_source[hash_start:hash_end]

    assert "resolvingSymlinksInPath()" in hash_body
    assert "packageRootPrefix" in hash_body
    assert "dropFirst(packageRootPrefix.count)" in hash_body
    assert 'replacingOccurrences(of: packageURL.path + "/", with: "")' not in hash_body


def test_bridge_cli_redacts_user_arguments_from_logged_command():
    module = _fresh_bridge_import("ts_horos_bridge.cli")

    safe_command = module.redacted_command_for_log(
        [
            "/usr/bin/python3",
            "-m",
            "totalsegmentator.bin.TotalSegmentator",
            "-i",
            "/tmp/dicom",
            "-o",
            "/tmp/output",
        ],
        ["--ml", "--device", "mps", "--license_number", "aca-secret", "--api-token=sk-secret", "--task", "total"],
    )

    rendered = " ".join(safe_command)
    assert "--ml" in safe_command
    assert "--device mps" in rendered
    assert "--license_number" in safe_command
    assert "--api-token=[redacted]" in safe_command
    assert "[argument]" in safe_command
    assert "aca-secret" not in rendered
    assert "sk-secret" not in rendered
    assert "--task total" not in rendered


def test_bridge_cli_uses_process_group_and_signal_forwarding():
    cli_source = _read(PACKAGE_ROOT / "cli.py")

    assert "subprocess.run(" not in cli_source
    assert "subprocess.Popen(command, start_new_session=True)" in cli_source
    assert "os.killpg(process.pid, signum)" in cli_source
    assert "signal.signal(signal.SIGTERM" in cli_source
    assert "signal.signal(signal.SIGINT" in cli_source


def test_nifti_conversion_imports_rtstruct_dependency_lazily():
    """
    Verify that heavy RTSTRUCT dependencies in nifti_conversion are imported lazily.

    Confirms that rt_utils and totalsegmentator.dicom_io are not loaded when the module
    is imported, ensuring dependencies are only loaded when explicitly needed.
    """
    sys.modules.pop("rt_utils", None)
    sys.modules.pop("totalsegmentator.dicom_io", None)

    module = _fresh_bridge_import("ts_horos_bridge.nifti_conversion")
    assert hasattr(module, "load_rtstruct_writer")
    assert "rt_utils" not in sys.modules
    assert "totalsegmentator.dicom_io" not in sys.modules


def test_volumetric_projection_manifest_is_written_atomically():
    source = _read(PACKAGE_ROOT / "volumetric_projection.py")
    manifest_block = source[source.find('manifest_path = roi_root / "manifest.json"'):source.find("return str(manifest_path)")]

    assert "atomic_write_json(manifest_path, manifest)" in manifest_block
    assert "json.dump(manifest" not in manifest_block
