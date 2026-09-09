"""Regression tests for the runtime upgrade's packaging contract (no inference)."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("validate_backend_upgrade", ROOT / "tools" / "validate_backend_upgrade.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


@pytest.fixture
def inputs():
    return validator.load_inputs(ROOT)


def valid_report(lock, contract):
    return {
        "pythonVersion": [3, 12],
        "packages": {package["distributionName"]: package["exactVersion"] for package in lock["packages"]},
        "sourceFiles": dict(contract["sourceFiles"]),
        "importMatchesDistribution": True,
    }


def test_reviewed_contract_is_consistent(inputs):
    validator.validate_contract(*inputs)
    lock, _, contract = inputs
    resolved = validator.validate_resolver(ROOT, lock, contract)
    assert len(resolved) == 118


@pytest.mark.parametrize("dependency", ["scipy", "scikit-image", "pandas", "xmltodict", "blosc", "fury"])
def test_runtime_dependency_closure_is_locked(inputs, dependency):
    lock, _, contract = inputs
    packages = {validator.canonicalize_name(package["distributionName"]): package for package in lock["packages"]}
    resolved = validator.validate_resolver(ROOT, lock, contract)
    assert packages[dependency]["required"] is True
    assert resolved[dependency]["version"] == packages[dependency]["exactVersion"]
    assert resolved[dependency]["hashes"]


def test_missing_declared_runtime_dependency_is_rejected(inputs):
    lock, manifest, contract = copy.deepcopy(inputs)
    lock["packages"] = [package for package in lock["packages"] if package["distributionName"] != "scipy"]
    with pytest.raises(ValueError, match="runtime dependency"):
        validator.validate_contract(lock, manifest, contract)


def test_resolver_rejects_unhashed_requirement():
    with pytest.raises(ValueError, match="no hashes"):
        validator.parse_hash_locked_requirements("scipy==1.17.1")


def test_swift_installer_enforces_and_validates_hash_locked_resolver():
    source = (ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Environment.swift").read_text()
    assert '"--require-hashes", "-r", requirementsURL.path' in source
    assert 'manifest["resolvedDistributions"]' in source
    assert "missing resolved distribution" in source

    project_directory = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin.xcodeproj"
    for project in project_directory.glob("project*.pbxproj"):
        assert "TotalSegmentatorRequirements.txt in Resources" in project.read_text()


@pytest.mark.parametrize("field", ["lock", "manifest", "package", "requirement", "identifier"])
def test_stale_version_fields_are_rejected(inputs, field):
    lock, manifest, contract = copy.deepcopy(inputs)
    if field == "lock":
        lock["backend"]["version"] = "2.11.0"
    elif field == "manifest":
        manifest["backendVersion"] = "2.11.0"
    elif field == "package":
        lock["packages"][0]["exactVersion"] = "2.11.0"
    elif field == "requirement":
        lock["packages"][0]["requirement"] = "TotalSegmentator>=2.18.0"
    else:
        lock["lockIdentifier"] = "totalsegmentator-env-2026-06-21-ts-2.11.0-torch-2.8.0"
    with pytest.raises(ValueError):
        validator.validate_contract(lock, manifest, contract)


@pytest.mark.parametrize("field,value", [
    ("qualityModes", ["normal", "fast"]),
    ("requiresLicense", True),
    ("supportedModalities", ["CT"]),
    ("supportsRoiSubset", True),
    ("supportsMultilabel", False),
    ("experimental", True),
    ("deprecated", True),
])
def test_invalid_task_capabilities_are_rejected(inputs, field, value):
    lock, manifest, contract = copy.deepcopy(inputs)
    task = next(task for task in manifest["tasks"] if task["identifier"] == "brain_aneurysm")
    task[field] = value
    with pytest.raises(ValueError):
        validator.validate_contract(lock, manifest, contract)


@pytest.mark.parametrize("change", ["duplicate", "missing", "prerelease", "cropped_only"])
def test_task_set_regressions_are_rejected(inputs, change):
    lock, manifest, contract = copy.deepcopy(inputs)
    if change == "duplicate":
        manifest["tasks"].append(copy.deepcopy(manifest["tasks"][0]))
    elif change == "missing":
        manifest["tasks"].pop()
    else:
        task = copy.deepcopy(manifest["tasks"][0])
        task["identifier"] = "total_v3" if change == "prerelease" else "aorta_annulus"
        manifest["tasks"].append(task)
    with pytest.raises(ValueError):
        validator.validate_contract(lock, manifest, contract)


def test_installed_report_validates_without_importing_engine(inputs):
    lock, _, contract = inputs
    validator.validate_installed(valid_report(lock, contract), lock, contract)


@pytest.mark.parametrize("change", ["missing_backend", "old_backend", "torch_drift", "source_drift", "shadowed", "python", "probe_error"])
def test_installed_drift_is_rejected(inputs, change):
    lock, _, contract = inputs
    report = valid_report(lock, contract)
    if change == "missing_backend":
        report["packages"]["TotalSegmentator"] = None
    elif change == "old_backend":
        report["packages"]["TotalSegmentator"] = "2.11.0"
    elif change == "torch_drift":
        report["packages"]["torch"] = "0.0.0"
    elif change == "source_drift":
        report["sourceFiles"]["registry.py"] = "0" * 40
    elif change == "shadowed":
        report["importMatchesDistribution"] = False
    elif change == "python":
        report["pythonVersion"] = [3, 13]
    else:
        report["error"] = "No package metadata was found for TotalSegmentator"
    with pytest.raises(ValueError):
        validator.validate_installed(report, lock, contract)


def test_optional_rt_utils_can_be_absent_but_not_drift(inputs):
    lock, _, contract = inputs
    report = valid_report(lock, contract)
    report["packages"]["rt-utils"] = None
    validator.validate_installed(report, lock, contract)
    report["packages"]["rt-utils"] = "0.0.0"
    with pytest.raises(ValueError, match="rt-utils"):
        validator.validate_installed(report, lock, contract)


def test_probe_runs_isolated_and_outside_checkout(inputs, monkeypatch):
    lock, _, contract = inputs
    expected = valid_report(lock, contract)

    def fake_run(command, **kwargs):
        assert command[:3] == [sys.executable, "-I", "-c"]
        assert Path(kwargs["cwd"]).resolve() != ROOT
        assert Path(kwargs["cwd"]).is_dir()
        request = json.loads(kwargs["input"])
        assert "registry.py" in request["sourceFiles"]
        assert "TotalSegmentator" in request["packages"]
        return subprocess.CompletedProcess(command, 0, json.dumps(expected), "")

    monkeypatch.setattr(validator.subprocess, "run", fake_run)
    assert validator.probe_installed(lock, contract) == expected


def test_cli_distinguishes_contract_from_inference_validation(capsys):
    assert validator.main(["--root", str(ROOT)]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["manifestContractValidated"] is True
    assert report["installedDistributionValidated"] is False
    assert report["inferenceValidated"] is False


def test_cli_missing_inputs_fails_clearly(tmp_path, capsys):
    assert validator.main(["--root", str(tmp_path)]) == 1
    assert "validation failed" in capsys.readouterr().err


def test_isolated_probe_does_not_import_runtime():
    assert "import torch" not in validator.INSTALLED_PROBE
    assert "from totalsegmentator" not in validator.INSTALLED_PROBE
    assert "metadata.distribution" in validator.INSTALLED_PROBE
