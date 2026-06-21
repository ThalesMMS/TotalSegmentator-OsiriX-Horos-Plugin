#!/usr/bin/env python3
"""Generate the plugin terminology resource from Slicer and TotalSegmentator labels."""

from __future__ import annotations

import csv
import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from totalsegmentator.label_maps.class_map import class_map

SLICER_RESOURCE_DIR = ROOT / "reference" / "SlicerTotalSegmentator-main" / "TotalSegmentator" / "Resources"
SLICER_CSV = SLICER_RESOURCE_DIR / "totalsegmentator_snomed_mapping.csv"
SLICER_TERM_JSON = SLICER_RESOURCE_DIR / "SegmentationCategoryTypeModifier-TotalSegmentator.term.json"
OUTPUT = ROOT / "MyOsiriXPluginFolder-Swift" / "python_bridge" / "ts_horos_bridge" / "TotalSegmentatorTerminology.json"


def file_sha256(path: Path) -> str:
    """
    Compute the SHA-256 hash of a file.
    
    Returns:
    	digest (str): Hexadecimal digest of the file's SHA-256 hash.
    """
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize(value: str) -> str:
    """
    Normalize a string to lowercase with underscores as word separators.
    
    Strips whitespace, converts to lowercase, replaces consecutive non-alphanumeric characters with a single underscore, and removes trailing underscores.
    
    Returns:
    	str: The normalized string
    """
    output = []
    previous_was_separator = False
    for character in value.strip().lower():
        if character.isalnum():
            output.append(character)
            previous_was_separator = False
        elif not previous_was_separator:
            output.append("_")
            previous_was_separator = True
    return "".join(output).strip("_")


def code_record(row: dict[str, str], prefix: str) -> dict[str, str] | None:
    """
    Extract coding terminology fields from a row with a given prefix.
    
    Returns:
        A dict with 'scheme', 'code_value', and 'meaning' if the code value is non-empty, `None` otherwise.
    """
    scheme = row.get(f"{prefix}_CodingScheme", "").strip()
    value = row.get(f"{prefix}_CodeValue", "").strip()
    meaning = row.get(f"{prefix}_CodeMeaning", "").strip()
    if not value:
        return None
    return {
        "scheme": scheme,
        "code_value": value,
        "meaning": meaning,
    }


def laterality(row: dict[str, str], backend_name: str) -> str:
    """
    Determine the anatomical laterality of a label.
    
    Returns:
        One of 'left', 'right', 'bilateral', or 'unpaired'.
    """
    modifier = row.get("TypeModifier_CodeMeaning", "").strip().lower()
    if modifier == "right":
        return "right"
    if modifier == "left":
        return "left"
    normalized = normalize(backend_name)
    if normalized.endswith("_right") or "_right_" in normalized or normalized.startswith("right_"):
        return "right"
    if normalized.endswith("_left") or "_left_" in normalized or normalized.startswith("left_"):
        return "left"
    if "right_and_left" in modifier:
        return "bilateral"
    return "unpaired"


def display_name(row: dict[str, str], backend_name: str) -> str:
    """
    Construct a human-readable display name from DICOM coding fields.
    
    Uses Type_CodeMeaning as the primary display name. If TypeModifier_CodeMeaning is
    "Right" or "Left" and is not already present in the Type_CodeMeaning, it is prepended.
    Falls back to a formatted version of backend_name (underscores replaced with spaces,
    title-cased) if Type_CodeMeaning is absent.
    
    Parameters:
        row (dict[str, str]): Dictionary containing Type_CodeMeaning and TypeModifier_CodeMeaning fields.
        backend_name (str): Fallback identifier if terminology fields are absent.
    
    Returns:
        str: The formatted display name.
    """
    type_meaning = row.get("Type_CodeMeaning", "").strip()
    modifier = row.get("TypeModifier_CodeMeaning", "").strip()
    if modifier in {"Right", "Left"} and type_meaning and modifier.lower() not in type_meaning.lower():
        return f"{modifier} {type_meaning}"
    if type_meaning:
        return type_meaning
    return backend_name.replace("_", " ").title()


def display_color(row: dict[str, str]) -> list[int]:
    """
    Extract RGB color values from a row's color fields.
    
    Returns:
    	A list containing red, green, and blue color values as integers.
    """
    return [
        int(row.get("Color_R", "0") or 0),
        int(row.get("Color_G", "0") or 0),
        int(row.get("Color_B", "0") or 0),
    ]


def build_records() -> list[dict[str, object]]:
    """
    Build terminology label records by matching class_map definitions to Slicer CSV entries.
    
    Returns:
        list[dict[str, object]]: A list of label records, each containing identification,
            presentation, semantic, and terminology content.
    
    Raises:
        SystemExit: If any expected Slicer CSV row is missing.
    """
    with SLICER_CSV.open(encoding="utf-8", newline="") as handle:
        slicer_rows = {
            row["Name"].strip(): row
            for row in csv.DictReader(handle)
            if row.get("Name", "").strip()
        }

    records: list[dict[str, object]] = []
    missing: list[str] = []
    for task in sorted(class_map):
        for raw_label_id, backend_name in sorted(class_map[task].items(), key=lambda item: int(item[0])):
            label_id = int(raw_label_id)
            row = slicer_rows.get(str(backend_name))
            if row is None:
                missing.append(f"{task}:{label_id}:{backend_name}")
                continue

            coded_concepts = {
                "category": code_record(row, "Category"),
                "type": code_record(row, "Type"),
                "type_modifier": code_record(row, "TypeModifier"),
                "region": code_record(row, "Region"),
                "region_modifier": code_record(row, "RegionModifier"),
            }
            coded_concepts = {key: value for key, value in coded_concepts.items() if value is not None}
            record = {
                "canonical_key": f"{task}:{label_id}:{backend_name}",
                "stable_label_id": f"{task}:{label_id}",
                "task": task,
                "label_id": label_id,
                "backend_name": backend_name,
                "display_name": display_name(row, str(backend_name)),
                "display_color": display_color(row),
                "aliases": [backend_name],
                "laterality": laterality(row, str(backend_name)),
                "anatomic_region": (
                    row.get("Region_CodeMeaning", "").strip()
                    or row.get("Type_CodeMeaning", "").strip()
                    or str(backend_name)
                ),
                "coded_concepts": coded_concepts,
                "terminology_source": "slicer",
                "source_record_name": row["Name"].strip(),
            }
            records.append(record)

    if missing:
        raise SystemExit("Missing Slicer terminology rows: " + ", ".join(missing[:20]))

    return records


def main() -> int:
    """
    Generates a terminology resource JSON file containing label records and upstream metadata.
    
    Returns:
        0 on successful completion.
    """
    payload = {
        "schema_version": 1,
        "format": "totalsegmentator-slicer-terminology",
        "mapping_version": "2026-06-20.slicer-reference",
        "upstream": {
            "name": "SlicerTotalSegmentator",
            "license": "Apache-2.0",
            "source_files": [
                str(SLICER_CSV.relative_to(ROOT)),
                str(SLICER_TERM_JSON.relative_to(ROOT)),
            ],
            "source_sha256": {
                str(SLICER_CSV.relative_to(ROOT)): file_sha256(SLICER_CSV),
                str(SLICER_TERM_JSON.relative_to(ROOT)): file_sha256(SLICER_TERM_JSON),
            },
            "notice": "Adapted from SlicerTotalSegmentator terminology resources under Apache-2.0.",
        },
        "update_command": "python tools/generate_terminology_resource.py",
        "labels": build_records(),
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
