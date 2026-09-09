"""Audit the plugin's pinned backend without importing torch or downloading weights.

The default checks the reviewed release contract against the bundled manifests.
--installed additionally inspects distribution metadata and source identities in
an isolated interpreter. It is a packaging check, not an inference/geometry test.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = Path("tests/fixtures/totalsegmentator-2.18.0-contract.json")
PLUGIN_PATH = Path("MyOsiriXPluginFolder-Swift")


def canonicalize_name(name):
    return "-".join(filter(None, re.split(r"[-_.]+", name.lower())))


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
    locked_required = {canonicalize_name(name) for name, package in packages.items() if package["required"]}
    declared_runtime = {canonicalize_name(name) for name in contract["runtimeDependencies"]}
    require(declared_runtime <= locked_required, "TotalSegmentator runtime dependency is missing from the lock.")

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


def parse_hash_locked_requirements(content):
    """Return canonical distribution names, exact versions, and artifact hashes."""
    resolved = {}
    current = None
    for line_number, line in enumerate(content.splitlines(), start=1):
        if not line.strip():
            continue
        if not line[0].isspace():
            require(line.endswith("\\"), f"Requirement on line {line_number} has no hashes.")
            requirement = line[:-1].strip()
            match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^ ;]+)", requirement)
            require(match is not None, f"Requirement on line {line_number} is not an exact pin.")
            name, version = match.groups()
            current = canonicalize_name(name)
            require(current not in resolved, f"Duplicate resolver distribution: {name}.")
            resolved[current] = {"name": name, "version": version, "hashes": []}
            continue

        require(current is not None, f"Orphaned hash on line {line_number}.")
        hash_match = re.fullmatch(r"\s+--hash=sha256:([0-9a-f]{64})(?: \\)?", line)
        require(hash_match is not None, f"Invalid resolver hash on line {line_number}.")
        resolved[current]["hashes"].append(hash_match.group(1))

    require(resolved, "Resolver is empty.")
    require(all(item["hashes"] for item in resolved.values()), "Every resolver pin must have a SHA-256 hash.")
    return resolved


def validate_resolver(root, lock, contract):
    """Validate the separately bundled, hash-locked transitive dependency graph."""
    resolver = lock["resolver"]
    requirement_name = resolver["requirementsFileName"]
    require(Path(requirement_name).name == requirement_name, "Resolver requirement filename must be a basename.")
    requirement_path = Path(root) / PLUGIN_PATH / requirement_name
    content_bytes = requirement_path.read_bytes()
    actual_sha256 = hashlib.sha256(content_bytes).hexdigest()
    require(actual_sha256 == resolver["requirementsSHA256"], "Resolver requirements checksum mismatch.")
    resolved = parse_hash_locked_requirements(content_bytes.decode("utf-8"))
    require(len(resolved) == resolver["distributionCount"], "Resolver distribution count mismatch.")

    for dependency in contract["runtimeDependencies"]:
        require(canonicalize_name(dependency) in resolved,
                f"Declared TotalSegmentator dependency missing from resolver: {dependency}.")
    for package in lock["packages"]:
        if not package["required"]:
            continue
        item = resolved.get(canonicalize_name(package["distributionName"]))
        require(item is not None, f'Locked package missing from resolver: {package["distributionName"]}.')
        require(item["version"] == package["exactVersion"],
                f'Resolver version differs from lock: {package["distributionName"]}.')
    return resolved


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
        validate_resolver(args.root, lock, contract)
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
