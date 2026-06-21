import ast
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorEnvironmentLock.json"
ENVIRONMENT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Environment.swift"
AUDIT_TYPES_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorPluginTypes.swift"
AUDIT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Audit.swift"
SETUP_PY = ROOT / "setup.py"
README = ROOT / "README.md"


def _lock() -> dict:
    """
    Load the TotalSegmentator environment lock manifest.

    Returns:
        dict: The environment lock manifest containing version constraints and package specifications.
    """
    return json.loads(LOCK_PATH.read_text(encoding="utf-8"))


def _setup_version() -> str:
    """
    Extract the version string from the setup() call in setup.py.

    Returns:
        The version string specified in the setup() call.

    Raises:
        AssertionError: If the version keyword is not found in setup.py.
    """
    tree = ast.parse(SETUP_PY.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "setup":
            for keyword in node.keywords:
                if keyword.arg == "version" and isinstance(keyword.value, ast.Constant):
                    return keyword.value.value
    raise AssertionError("setup.py version not found")


def _setup_requirements() -> set[str]:
    """
    Retrieve package names declared in setup.py's install_requires.

    Returns:
        set[str]: Package names stripped of version specifiers.

    Raises:
        AssertionError: If install_requires is not found in setup().
    """
    tree = ast.parse(SETUP_PY.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "setup":
            for keyword in node.keywords:
                if keyword.arg == "install_requires" and isinstance(keyword.value, ast.List):
                    return {
                        re.split(r"[<>=!~]", item.value, maxsplit=1)[0]
                        for item in keyword.value.elts
                        if isinstance(item, ast.Constant)
                    }
    raise AssertionError("setup.py install_requires not found")


def _package(lock: dict, distribution_name: str) -> dict:
    """
    Retrieve a package entry from the lock by distribution name.

    Parameters:
        lock (dict): The lock dictionary containing package definitions.
        distribution_name (str): The distribution name to search for.

    Returns:
        dict: The package entry for the specified distribution.

    Raises:
        AssertionError: If the distribution is not present in the lock.
    """
    for package in lock["packages"]:
        if package["distributionName"] == distribution_name:
            return package
    raise AssertionError(f"{distribution_name} not present in lock")


def _version_tuple(value: str) -> tuple[int, ...]:
    """
    Extract numeric version components from a version string.

    Returns:
    	A tuple of integers representing the version components in order.
    """
    parts = []
    for token in re.split(r"[.+-]", value):
        if token.isdigit():
            parts.append(int(token))
        else:
            match = re.match(r"(\d+)", token)
            if match:
                parts.append(int(match.group(1)))
    return tuple(parts)


def _validate_fixture(lock: dict, resolved: dict) -> list[str]:
    """
    Validate that a resolved environment conforms to constraints in a lock manifest.

    Parameters:
    	lock (dict): The lock manifest containing Python version bounds, supported architectures, and required packages with version constraints.
    	resolved (dict): The resolved environment to validate, including lock identifier, Python version, architecture, and installed packages with versions.

    Returns:
    	list[str]: A list of error strings for each constraint violation; empty if the environment is valid.
    """
    errors = []
    if resolved.get("lockIdentifier") != lock["lockIdentifier"]:
        errors.append("lock identifier mismatch")

    python_version = _version_tuple(resolved["pythonVersion"])
    if python_version < _version_tuple(lock["python"]["minimumVersion"]):
        errors.append("python version below minimum")
    if python_version >= _version_tuple(lock["python"]["maximumExclusiveVersion"]):
        errors.append("python version above maximum")

    if resolved["architecture"] not in lock["python"]["supportedArchitectures"]:
        errors.append("unsupported architecture")

    resolved_packages = resolved.get("packages", {})
    for package in lock["packages"]:
        if not package["required"]:
            continue
        resolved_package = resolved_packages.get(package["distributionName"])
        if not resolved_package or not resolved_package.get("version"):
            errors.append(f"missing package {package['distributionName']}")
            continue

        version = _version_tuple(resolved_package["version"])
        if package.get("exactVersion") and version != _version_tuple(package["exactVersion"]):
            errors.append(f"version drift {package['distributionName']}")
        if package.get("minimumVersion") and version < _version_tuple(package["minimumVersion"]):
            errors.append(f"version below minimum {package['distributionName']}")
        if package.get("maximumExclusiveVersion") and version >= _version_tuple(package["maximumExclusiveVersion"]):
            errors.append(f"version above maximum {package['distributionName']}")
    return errors


def test_lock_pins_checked_in_totalsegmentator_version():
    lock = _lock()
    package = _package(lock, "TotalSegmentator")

    assert lock["backend"]["version"] == _setup_version()
    assert package["exactVersion"] == _setup_version()
    assert package["requirement"] == f"TotalSegmentator=={_setup_version()}"


def test_lock_declares_core_runtime_dependencies_and_dcm2niix():
    lock = _lock()
    required = {package["distributionName"]: package for package in lock["packages"] if package["required"]}

    declared_dependencies = _setup_requirements()
    for name in declared_dependencies | {"TotalSegmentator", "pydicom"}:
        assert name in required
        assert required[name]["exactVersion"]
        assert required[name]["requirement"] == f"{name}=={required[name]['exactVersion']}"

    rt_utils = _package(lock, "rt-utils")
    assert rt_utils["required"] is False
    assert rt_utils["exactVersion"]
    assert rt_utils["requirement"] == f"rt-utils=={rt_utils['exactVersion']}"

    assert lock["dcm2niix"]["version"] == "v1.0.20250506"
    assert len(lock["dcm2niix"]["archiveSHA256"]) == 64
    assert len(lock["dcm2niix"]["binarySHA256"]) == 64


def test_lock_pins_torch_with_mps_convtranspose3d_support():
    lock = _lock()
    torch_package = _package(lock, "torch")
    torchvision_package = _package(lock, "torchvision")

    assert _version_tuple(torch_package["exactVersion"]) >= (2, 8, 0)
    assert torchvision_package["exactVersion"] == "0.23.0"


def test_lock_python_minimum_matches_pinned_package_python_requirements():
    lock = _lock()

    package_python_minimums = {
        "nnunetv2": "3.10",
        "numpy": "3.11",
        "requests": "3.10",
    }
    required_minimum = max(
        (_version_tuple(version) for version in package_python_minimums.values()),
        default=(),
    )

    assert _version_tuple(lock["python"]["minimumVersion"]) >= required_minimum


def test_swift_installs_only_pinned_lock_requirements():
    source = ENVIRONMENT_SWIFT.read_text(encoding="utf-8")

    assert "TotalSegmentatorEnvironmentLock" in source
    assert "installPinnedPythonPackages" in source
    assert '["-m", "pip", "install", "--upgrade", "TotalSegmentator"]' not in source
    assert 'subprocess.check_call([sys.executable, "-m", "pip", "install", package_name])' not in source
    assert '["-m", "pip", "install", module]' not in source


def test_swift_repairs_managed_environment_with_lock_compatible_python():
    source = ENVIRONMENT_SWIFT.read_text(encoding="utf-8")

    assert "rebuildManagedPythonEnvironment" in source
    assert "managedEnvironmentBaseResolution" in source
    assert "pythonResolutionMatchesEnvironmentLock" in source
    assert "homeDirectoryForCurrentUser" in source
    assert ".local/bin/python3.11" in source
    for python_name in ["python3.12", "python3.11", "python3.10", "python3.9"]:
        assert python_name in source
    assert "isExecutableFile(atPath: url.path)" in source


def test_setup_probe_treats_rt_utils_as_optional():
    source = ENVIRONMENT_SWIFT.read_text(encoding="utf-8")

    assert "mandatory_requirements" in source
    assert '"pydicom": "pydicom"' in source
    assert '"dicom2nifti": "dicom2nifti"' in source
    assert "optional_requirements" in source
    assert '"rt_utils": "rt-utils"' in source
    assert '"optional_missing"' in source
    assert 'sys.exit(2)' in source[source.find("if missing_mandatory:"):source.find('print("__RESULT__" + json.dumps({"status": "ok"')]


def test_swift_persists_and_audits_environment_manifest_identifier():
    environment_source = ENVIRONMENT_SWIFT.read_text(encoding="utf-8")
    audit_types_source = AUDIT_TYPES_SWIFT.read_text(encoding="utf-8")
    audit_source = AUDIT_SWIFT.read_text(encoding="utf-8")

    assert "environment-manifest.json" in environment_source
    assert "installedDistributions" in environment_source
    assert "validatePinnedPythonEnvironment" in environment_source
    assert "environmentManifestIdentifier" in audit_types_source
    assert "environmentManifestPath" in audit_types_source
    assert "currentEnvironmentManifestIdentifier" in audit_source


def test_environment_manifest_validation_fixtures_cover_expected_failures():
    lock = _lock()
    resolved = {
        "lockIdentifier": lock["lockIdentifier"],
        "pythonVersion": "3.11.9",
        "architecture": lock["python"]["supportedArchitectures"][0],
        "packages": {
            package["distributionName"]: {"version": package.get("exactVersion") or package.get("minimumVersion")}
            for package in lock["packages"]
            if package["required"]
        },
    }

    assert _validate_fixture(lock, resolved) == []

    drifted = json.loads(json.dumps(resolved))
    drifted["packages"]["TotalSegmentator"]["version"] = "99.0.0"
    assert "version drift TotalSegmentator" in _validate_fixture(lock, drifted)

    missing = json.loads(json.dumps(resolved))
    del missing["packages"]["nibabel"]
    assert "missing package nibabel" in _validate_fixture(lock, missing)

    wrong_arch = json.loads(json.dumps(resolved))
    wrong_arch["architecture"] = "ppc64"
    assert "unsupported architecture" in _validate_fixture(lock, wrong_arch)

    corrupt = json.loads(json.dumps(resolved))
    corrupt["lockIdentifier"] = "different-lock"
    assert "lock identifier mismatch" in _validate_fixture(lock, corrupt)


def test_readme_documents_repair_and_offline_install_paths():
    readme = README.read_text(encoding="utf-8")

    assert "TotalSegmentatorEnvironmentLock.json" in readme
    assert "environment-manifest.json" in readme
    assert "offline" in readme.lower()
    assert "repair" in readme.lower()
