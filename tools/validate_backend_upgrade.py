"""Audit the plugin's pinned backend without importing torch or downloading weights.

The default checks the reviewed release contract against the bundled manifests.
--installed additionally inspects distribution metadata and source identities in
an isolated interpreter. It is a packaging check, not an inference/geometry test.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = Path("tests/fixtures/totalsegmentator-2.18.0-contract.json")
PLUGIN_PATH = Path("MyOsiriXPluginFolder-Swift")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_inputs(root):
    """Read the actual bundle inputs, not the reference backend's setup.py."""
    paths = (
        PLUGIN_PATH / "TotalSegmentatorEnvironmentLock.json",
        PLUGIN_PATH / "TotalSegmentatorTaskCapabilities.json",
        CONTRACT_PATH,
    )
    documents = [json.loads((Path(root) / path).read_text(encoding="utf-8")) for path in paths]
    require(all(isinstance(document, dict) for document in documents), "Expected JSON objects.")
    return tuple(documents)


def validate_contract(lock, manifest, contract):
    """Fail closed on version drift, unsupported modes, or task/license drift."""
    version = contract["engineVersion"]
    require(lock["schemaVersion"] == manifest["schemaVersion"] == contract["schemaVersion"] == 1,
            "Unsupported manifest/contract schema.")
    require(lock["backend"]["version"] == version, "Backend lock does not match release contract.")
    require(manifest.get("backendVersion") == version, "Task manifest does not match backend version.")
    require(f"ts-{version}" in lock["lockIdentifier"], "Environment lock identifier is stale.")
    package_names = [package["distributionName"] for package in lock["packages"]]
    require(len(package_names) == len(set(package_names)), "Duplicate locked distribution.")
    packages = {package["distributionName"]: package for package in lock["packages"]}
    backend = packages.get("TotalSegmentator", {})
    require(backend.get("required") is True and backend.get("exactVersion") == version,
            "Installed TotalSegmentator pin is missing or stale.")
    for package in packages.values():
        require(package["requirement"] == f'{package["distributionName"]}=={package["exactVersion"]}',
                f'Non-exact or inconsistent package requirement: {package["distributionName"]}.')

    registered = set(contract["tasks"])
    excluded = set(contract["excludedTasks"])
    require(len(registered) == len(contract["tasks"]), "Duplicate upstream task.")
    require(excluded <= registered, "Exclusion refers to an unknown upstream task.")
    require(all(contract["excludedTasks"].values()), "Every exclusion needs a reason.")
    identifiers = [task["identifier"] for task in manifest["tasks"]]
    require(len(identifiers) == len(set(identifiers)), "Duplicate plugin task.")
    require(set(identifiers) == registered - excluded,
            "Plugin tasks differ from the reviewed supported/excluded upstream task set.")
    require(manifest["defaultTask"] == "total", "Stable total must remain the default task.")
    for task in manifest["tasks"]:
        identifier = task["identifier"]
        modality = "MR" if identifier.endswith("_mr") or identifier in contract["mrTasksWithoutSuffix"] else "CT"
        require(task["supportedModalities"] == [modality], f"Incorrect modality: {identifier}.")
        require(task["requiresLicense"] == (identifier in contract["commercialTasks"]),
                f"Incorrect license requirement: {identifier}.")
        require(task["qualityModes"] == contract["qualityModes"].get(identifier, ["normal"]),
                f"Unsupported quality mode: {identifier}.")
        require(task["supportsRoiSubset"] == (identifier in contract["roiSubsetTasks"]),
                f"Unsupported ROI subset: {identifier}.")
        # The former lung-vessels exception applied to the old model. The 2.18
        # tasks exposed here use the normal nnUNet multilabel NIfTI output path.
        require(task["supportsMultilabel"] is True, f"Canonical multilabel output disabled: {identifier}.")
        require(task["experimental"] is False and task["deprecated"] is False,
                f"Experimental/deprecated task exposed: {identifier}.")


# -I plus an empty working directory prevents the checkout's reference-only
# totalsegmentator/ from satisfying the audit in place of the installed package.
# Read distribution files; do not import the engine, torch, or the model registry.
INSTALLED_PROBE = r'''
import hashlib
import importlib.metadata as metadata
import importlib.util
import json
from pathlib import Path
import sys

request = json.load(sys.stdin)
result = {"pythonVersion": list(sys.version_info[:2]), "packages": {}, "sourceFiles": {}}
for name in request["packages"]:
    try:
        result["packages"][name] = metadata.version(name)
    except metadata.PackageNotFoundError:
        result["packages"][name] = None
try:
    dist = metadata.distribution("TotalSegmentator")
    package_root = Path(dist.locate_file("totalsegmentator")).resolve()
    spec = importlib.util.find_spec("totalsegmentator")
    result["importMatchesDistribution"] = bool(
        spec and spec.origin and Path(spec.origin).resolve() == package_root / "__init__.py"
    )
    for relative_path in request["sourceFiles"]:
        path = (package_root / relative_path).resolve()
        if not path.is_relative_to(package_root):
            raise ValueError("Source path is outside the installed distribution.")
        content = path.read_bytes()
        git_object = b"blob " + str(len(content)).encode("ascii") + b"\0" + content
        result["sourceFiles"][relative_path] = hashlib.sha1(git_object).hexdigest()
except (metadata.PackageNotFoundError, OSError, ValueError) as exc:
    result["error"] = str(exc)
print(json.dumps(result))
'''


def probe_installed(lock, contract):
    request = {
        "packages": [package["distributionName"] for package in lock["packages"]],
        "sourceFiles": list(contract["sourceFiles"]),
    }
    with tempfile.TemporaryDirectory(prefix="totalseg-contract-") as directory:
        result = subprocess.run(
            [sys.executable, "-I", "-c", INSTALLED_PROBE],
            input=json.dumps(request), capture_output=True, text=True,
            cwd=directory, timeout=60, check=False,
        )
    require(result.returncode == 0, "Isolated installed-distribution probe failed: " + result.stderr.strip())
    return json.loads(result.stdout)


def validate_installed(report, lock, contract):
    """Check exact locked packages and reviewed upstream source-file identities."""
    require(not report.get("error"), "Installed backend unavailable: " + str(report.get("error")))
    version = tuple(report["pythonVersion"])
    minimum = tuple(int(part) for part in lock["python"]["minimumVersion"].split("."))
    maximum = tuple(int(part) for part in lock["python"]["maximumExclusiveVersion"].split("."))
    require(minimum <= version < maximum, "Python version is outside the plugin's locked range.")
    require(report.get("importMatchesDistribution") is True,
            "Module resolution does not match the installed TotalSegmentator distribution.")
    for package in lock["packages"]:
        name = package["distributionName"]
        installed = report["packages"].get(name)
        if installed is None and not package["required"]:
            continue
        require(installed == package["exactVersion"], f"Locked package missing or mismatched: {name}.")
    for path, expected in contract["sourceFiles"].items():
        require(report["sourceFiles"].get(path) == expected,
                f"Installed upstream source differs from the reviewed release: {path}.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="Plugin repository root")
    parser.add_argument("--installed", action="store_true", help="Also audit this interpreter's installed distribution")
    args = parser.parse_args(argv)
    try:
        lock, manifest, contract = load_inputs(args.root)
        validate_contract(lock, manifest, contract)
        if args.installed:
            validate_installed(probe_installed(lock, contract), lock, contract)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(f"Backend contract validation failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({
        "engineVersion": contract["engineVersion"],
        "pluginTasks": len(manifest["tasks"]),
        "excludedTasks": sorted(contract["excludedTasks"]),
        "manifestContractValidated": True,
        "installedDistributionValidated": args.installed,
        "inferenceValidated": False,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
