import ast
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorTaskCapabilities.json"
PLUGIN_SWIFT_PATH = ROOT / "MyOsiriXPluginFolder-Swift" / "Plugin.swift"
CLI_PATH = ROOT / "totalsegmentator" / "bin" / "TotalSegmentator.py"
CLASS_MAP_PATH = ROOT / "totalsegmentator" / "label_maps" / "class_map.py"
COMMERCIAL_MAP_PATH = ROOT / "totalsegmentator" / "label_maps" / "commercial.py"
PYTHON_API_PATH = ROOT / "totalsegmentator" / "python_api.py"


def _cli_task_choices() -> set[str]:
    """
    Extract the set of task identifiers from the CLI's --task argument choices.

    Returns:
    	set[str]: Task identifiers accepted by the --task CLI argument.

    Raises:
    	AssertionError: If the --task argument definition cannot be found in the CLI source.
    """
    module = ast.parse(CLI_PATH.read_text(encoding="utf-8"))
    for node in ast.walk(module):
        if not isinstance(node, ast.Call) or getattr(node.func, "attr", "") != "add_argument":
            continue
        names = [arg.value for arg in node.args if isinstance(arg, ast.Constant) and isinstance(arg.value, str)]
        if "--task" not in names:
            continue
        for keyword in node.keywords:
            if keyword.arg == "choices" and isinstance(keyword.value, ast.List):
                return {
                    element.value
                    for element in keyword.value.elts
                    if isinstance(element, ast.Constant) and isinstance(element.value, str)
                }
    raise AssertionError("Could not find --task choices in TotalSegmentator CLI")


def _class_map_task_keys() -> set[str]:
    """
    Extract string keys from the backend class map dictionary.

    Returns:
    	A set of string identifiers from the class map.

    Raises:
    	AssertionError: If the class_map assignment cannot be found or if its value
    		is not a literal dictionary.
    """
    source = CLASS_MAP_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "class_map" for target in node.targets):
            if not isinstance(node.value, ast.Dict):
                raise AssertionError("class_map is not a literal dictionary")
            return {
                key.value
                for key in node.value.keys
                if isinstance(key, ast.Constant) and isinstance(key.value, str)
            }
    raise AssertionError("Could not find class_map dictionary")


def _commercial_model_keys() -> set[str]:
    """
    Extract the set of string keys from the backend commercial models dictionary.

    Returns:
    	A set of string keys from the commercial_models dictionary assignment.

    Raises:
    	AssertionError: If the commercial_models assignment is not found or is not a literal dictionary.
    """
    source = COMMERCIAL_MAP_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "commercial_models" for target in node.targets):
            if not isinstance(node.value, ast.Dict):
                raise AssertionError("commercial_models is not a literal dictionary")
            return {
                key.value
                for key in node.value.keys
                if isinstance(key, ast.Constant) and isinstance(key.value, str)
            }
    raise AssertionError("Could not find commercial_models dictionary")


def _tasks_with_explicit_fast_rejection() -> set[str]:
    """
    Extract task identifiers that do not support the --fast option.

    Returns:
        set[str]: Task identifiers that explicitly reject the --fast option.
    """
    source = PYTHON_API_PATH.read_text(encoding="utf-8")
    return set(re.findall(r'task ([a-z0-9_]+) does not work with option --fast', source))


def _manifest() -> dict:
    """
    Load the task capability manifest.

    Returns:
        dict: The parsed capability manifest dictionary.
    """
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def test_manifest_tasks_are_accepted_by_pinned_cli_choices():
    cli_choices = _cli_task_choices()
    manifest_tasks = {task["identifier"] for task in _manifest()["tasks"]}

    assert manifest_tasks
    assert manifest_tasks <= cli_choices


def test_manifest_roi_subset_tasks_exist_in_backend_class_map():
    class_map_keys = _class_map_task_keys()
    for task in _manifest()["tasks"]:
        if task.get("supportsRoiSubset"):
            assert task["identifier"] in class_map_keys


def test_manifest_license_requirements_match_backend_commercial_models():
    commercial_tasks = _commercial_model_keys()
    manifest_commercial_tasks = {task["identifier"] for task in _manifest()["tasks"] if task["requiresLicense"]}

    assert manifest_commercial_tasks == commercial_tasks


def test_manifest_fast_modes_do_not_conflict_with_backend_rejections():
    rejected_fast_tasks = _tasks_with_explicit_fast_rejection()

    for task in _manifest()["tasks"]:
        if "fast" in task["qualityModes"]:
            assert task["identifier"] not in rejected_fast_tasks


def test_manifest_non_multilabel_tasks_are_documented_backend_exceptions():
    non_multilabel_tasks = {task["identifier"] for task in _manifest()["tasks"] if not task["supportsMultilabel"]}

    assert non_multilabel_tasks == {"lung_vessels"}


def test_manifest_contains_no_anatomy_aliases_as_task_identifiers():
    invalid_aliases = {
        "lung",
        "heart",
        "kidney",
        "liver",
        "pelvis",
        "prostate",
        "spleen",
        "pancreas",
        "headneck",
        "femur",
        "hip",
        "vertebrae",
    }
    manifest_tasks = {task["identifier"] for task in _manifest()["tasks"]}

    assert manifest_tasks.isdisjoint(invalid_aliases)


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
        "lung",
        "heart",
        "kidney",
        "liver",
        "pelvis",
        "prostate",
        "spleen",
        "pancreas",
        "headneck",
        "femur",
        "hip",
        "vertebrae",
    ]

    for alias in invalid_aliases:
        assert not re.search(rf'value:\s*"{re.escape(alias)}"', source)
