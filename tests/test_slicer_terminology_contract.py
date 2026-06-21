import json
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PARENT = ROOT / "MyOsiriXPluginFolder-Swift" / "python_bridge"
RESOURCE_PATH = BRIDGE_PARENT / "ts_horos_bridge" / "TotalSegmentatorTerminology.json"
TERMINOLOGY_SOURCE = BRIDGE_PARENT / "ts_horos_bridge" / "terminology.py"
if str(BRIDGE_PARENT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_PARENT))

from totalsegmentator.label_maps.class_map import class_map


def _resource():
    """
    Load the TotalSegmentator terminology JSON resource.

    Returns:
    	dict: The parsed terminology resource.
    """
    with RESOURCE_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


def test_terminology_resource_declares_slicer_provenance_and_covers_backend_labels():
    payload = _resource()

    assert payload["schema_version"] == 1
    assert payload["format"] == "totalsegmentator-slicer-terminology"
    assert payload["mapping_version"]
    assert payload["upstream"]["name"] == "SlicerTotalSegmentator"
    assert payload["upstream"]["license"] == "Apache-2.0"
    source_files = payload["upstream"]["source_files"]
    assert any(path.endswith("totalsegmentator_snomed_mapping.csv") for path in source_files)
    assert any(path.endswith("SegmentationCategoryTypeModifier-TotalSegmentator.term.json") for path in source_files)

    records = {
        (record["task"], int(record["label_id"]), record["backend_name"]): record
        for record in payload["labels"]
    }
    for task, mapping in class_map.items():
        for label_id, backend_name in mapping.items():
            record = records[(task, int(label_id), backend_name)]
            assert record["canonical_key"] == f"{task}:{int(label_id)}:{backend_name}"
            assert record["stable_label_id"] == f"{task}:{int(label_id)}"
            assert record["display_name"]
            assert record["aliases"][0] == backend_name
            assert record["terminology_source"] == "slicer"
            assert record["coded_concepts"]["category"]["code_value"]
            assert record["coded_concepts"]["type"]["code_value"]
            assert len(record["display_color"]) == 3
            assert all(isinstance(value, int) and 0 <= value <= 255 for value in record["display_color"])


def test_terminology_resource_has_stable_unique_keys_and_valid_colors():
    payload = _resource()

    canonical_keys = [record["canonical_key"] for record in payload["labels"]]
    task_label_ids = [(record["task"], int(record["label_id"])) for record in payload["labels"]]
    assert len(canonical_keys) == len(set(canonical_keys))
    assert len(task_label_ids) == len(set(task_label_ids))

    for record in payload["labels"]:
        assert record["backend_name"] != record["display_name"] or "_" not in record["backend_name"]
        assert record["display_name"].strip() == record["display_name"]
        assert all(isinstance(value, int) and 0 <= value <= 255 for value in record["display_color"])


def test_terminology_loader_resolves_by_backend_identity_and_falls_back_explicitly():
    from ts_horos_bridge.terminology import (
        load_terminology_resource,
        resolve_label_metadata,
    )

    resource = load_terminology_resource()
    liver = resolve_label_metadata("total", 5, "liver", resource=resource)
    assert liver["canonical_key"] == "total:5:liver"
    assert liver["backend_name"] == "liver"
    assert liver["display_name"] == "Liver"
    assert liver["display_color"] == [221, 130, 101]
    assert liver["terminology_source"] == "slicer"

    fallback = resolve_label_metadata("unknown_task", 99, "Localized Liver", resource=resource)
    assert fallback["canonical_key"] == "unknown_task:99:localized_liver"
    assert fallback["backend_name"] == "Localized Liver"
    assert fallback["terminology_source"] == "fallback"
    assert fallback["missing_mapping"] is True
    assert fallback["diagnostic"] == "missing_slicer_terminology_mapping"
    assert len(fallback["display_color"]) == 3


def test_fallback_color_generation_avoids_redundant_int_round_wrappers():
    source = TERMINOLOGY_SOURCE.read_text(encoding="utf-8")

    assert "int(round(" not in source
    assert "round(red * 255)" in source
    assert "round(green * 255)" in source
    assert "round(blue * 255)" in source


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        ("duplicate_key", "duplicate canonical"),
        ("duplicate_code", "duplicate coded concept"),
        ("invalid_color", "invalid display_color"),
    ],
)
def test_terminology_validator_detects_duplicate_codes_keys_and_invalid_colors(mutation, message):
    from ts_horos_bridge.terminology import validate_terminology_resource

    payload = {
        "schema_version": 1,
        "format": "totalsegmentator-slicer-terminology",
        "mapping_version": "test",
        "upstream": {"license": "Apache-2.0"},
        "labels": [
            {
                "canonical_key": "total:1:spleen",
                "stable_label_id": "total:1",
                "task": "total",
                "label_id": 1,
                "backend_name": "spleen",
                "display_name": "Spleen",
                "display_color": [1, 2, 3],
                "aliases": ["spleen"],
                "terminology_source": "slicer",
                "coded_concepts": {
                    "category": {"scheme": "SCT", "code_value": "123", "meaning": "Anatomical Structure"},
                    "type": {"scheme": "SCT", "code_value": "456", "meaning": "Spleen"},
                },
            },
            {
                "canonical_key": "total:2:liver",
                "stable_label_id": "total:2",
                "task": "total",
                "label_id": 2,
                "backend_name": "liver",
                "display_name": "Liver",
                "display_color": [4, 5, 6],
                "aliases": ["liver"],
                "terminology_source": "slicer",
                "coded_concepts": {
                    "category": {"scheme": "SCT", "code_value": "123", "meaning": "Anatomical Structure"},
                    "type": {"scheme": "SCT", "code_value": "789", "meaning": "Liver"},
                },
            },
        ],
    }

    if mutation == "duplicate_key":
        payload["labels"][1]["canonical_key"] = payload["labels"][0]["canonical_key"]
    elif mutation == "duplicate_code":
        payload["labels"][1]["coded_concepts"] = payload["labels"][0]["coded_concepts"]
    elif mutation == "invalid_color":
        payload["labels"][1]["display_color"] = [256, 0, 0]

    with pytest.raises(ValueError, match=message):
        validate_terminology_resource(payload, strict_coded_concepts=True)


def test_canonical_label_map_exports_resolved_terminology(tmp_path):
    from ts_horos_bridge.cli import persist_canonical_label_map

    persist_canonical_label_map(tmp_path, "total", {5: "liver"}, {5})

    payload = json.loads((tmp_path / "label-map.json").read_text(encoding="utf-8"))
    assert payload["terminology"]["mapping_version"]
    assert payload["terminology"]["upstream"] == "SlicerTotalSegmentator"

    label = payload["labels"][0]
    assert label["name"] == "liver"
    assert label["canonical_key"] == "total:5:liver"
    assert label["display_name"] == "Liver"
    assert label["display_color"] == [221, 130, 101]
    assert label["terminology_source"] == "slicer"
    assert label["coded_concepts"]["type"]["code_value"] == "10200004"
