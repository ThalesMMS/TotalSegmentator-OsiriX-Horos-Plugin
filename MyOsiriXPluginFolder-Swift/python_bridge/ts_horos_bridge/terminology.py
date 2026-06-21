import colorsys
import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path


RESOURCE_NAME = "TotalSegmentatorTerminology.json"


def normalize_label_identity(value):
    """
    Normalize a label string to a canonical identifier format.

    Converts to lowercase, replaces runs of non-alphanumeric characters with underscores, and removes leading and trailing underscores. Returns "label" if normalization results in an empty string.

    Returns:
        str: A normalized identifier
    """
    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "_", text)
    return text.strip("_") or "label"


def _coded_concept_identity(record):
    """
    Extract a canonical identity tuple from a record's coded concepts.

    For each concept category (category, type, type_modifier, region,
    region_modifier), includes the key name, scheme, and code_value.

    Parameters:
        record (dict): A terminology record.

    Returns:
        tuple: Coded concept identity parts.
    """
    concepts = record.get("coded_concepts") or {}
    parts = []
    for key in ("category", "type", "type_modifier", "region", "region_modifier"):
        concept = concepts.get(key) or {}
        parts.extend([
            key,
            str(concept.get("scheme") or ""),
            str(concept.get("code_value") or ""),
        ])
    return tuple(parts)


def _resource_path():
    """
    Build the filesystem path to the terminology resource file.

    Returns:
        Path: The path to the terminology resource in the same directory as this module.
    """
    return Path(__file__).with_name(RESOURCE_NAME)


@lru_cache(maxsize=1)
def load_terminology_resource():
    """
    Load and validate the bundled terminology resource.

    Returns:
        dict: The validated terminology resource payload.

    Raises:
        ValueError: If the resource is invalid or malformed.
    """
    with _resource_path().open(encoding="utf-8") as handle:
        payload = json.load(handle)
    validate_terminology_resource(payload)
    return payload


def terminology_summary(resource=None):
    """
    Retrieve summary metadata from a terminology resource.

    Parameters:
        resource (dict, optional): A terminology resource dictionary. If not provided,
            loads the default terminology resource.

    Returns:
        dict: A dictionary with keys mapping_version, upstream, license, and source_files.
    """
    resource = resource or load_terminology_resource()
    upstream = resource.get("upstream") or {}
    return {
        "mapping_version": resource.get("mapping_version"),
        "upstream": upstream.get("name"),
        "license": upstream.get("license"),
        "source_files": list(upstream.get("source_files") or []),
    }


def validate_terminology_resource(payload, strict_coded_concepts=False):
    """
    Validates a terminology resource payload against schema and uniqueness constraints.

    Checks that the payload has the expected schema version and format, then validates each label record for:
    - Unique canonical keys and (task, label_id) pairs
    - Valid display_color structure (list of 3 integers in [0, 255])
    - Required backend_name and display_name fields
    - Required category and type coded concepts

    If strict_coded_concepts is True, also ensures coded concept identities are not duplicated across records (or map to the same canonical key).

    Parameters:
    	payload (dict): The terminology resource dictionary to validate.
    	strict_coded_concepts (bool): If True, enforce uniqueness of coded concept identities. Defaults to False.

    Returns:
    	bool: True if validation succeeds.

    Raises:
    	ValueError: If schema_version is not 1, format is not "totalsegmentator-slicer-terminology", canonical_key is missing or duplicated, (task, label_id) pair is duplicated, display_color is invalid, required label names are missing, required coded concepts are missing, or (if strict_coded_concepts is True) a coded concept identity is duplicated.
    """
    if payload.get("schema_version") != 1:
        raise ValueError("unsupported terminology schema_version")
    if payload.get("format") != "totalsegmentator-slicer-terminology":
        raise ValueError("unsupported terminology format")

    seen_canonical = set()
    seen_task_label = set()
    seen_coded = {}
    for record in payload.get("labels") or []:
        canonical_key = record.get("canonical_key")
        if not canonical_key or canonical_key in seen_canonical:
            raise ValueError("duplicate canonical terminology key")
        seen_canonical.add(canonical_key)

        task_label = (record.get("task"), int(record.get("label_id")))
        if task_label in seen_task_label:
            raise ValueError("duplicate task label terminology identity")
        seen_task_label.add(task_label)

        color = record.get("display_color")
        if (
            not isinstance(color, list)
            or len(color) != 3
            or any(not isinstance(value, int) or value < 0 or value > 255 for value in color)
        ):
            raise ValueError("invalid display_color")

        if not record.get("backend_name") or not record.get("display_name"):
            raise ValueError("missing terminology label names")
        concepts = record.get("coded_concepts") or {}
        if not (concepts.get("category") or {}).get("code_value"):
            raise ValueError("missing category coded concept")
        if not (concepts.get("type") or {}).get("code_value"):
            raise ValueError("missing type coded concept")

        if strict_coded_concepts:
            coded_identity = _coded_concept_identity(record)
            previous = seen_coded.get(coded_identity)
            if previous is not None and previous != canonical_key:
                raise ValueError("duplicate coded concept")
            seen_coded[coded_identity] = canonical_key

    return True


def _records_by_identity(resource):
    """
    Create lookup dictionaries for resolving terminology records by different identity keys.

    Parameters:
    	resource (dict): Terminology resource with a "labels" key containing record list

    Returns:
    	tuple: Three dictionaries (by_exact, by_task_label, by_alias) for looking up records by (task, label_id, backend_name), (task, label_id), or (task, normalized_alias) respectively
    """
    by_exact = {}
    by_task_label = {}
    by_alias = {}
    for record in resource.get("labels") or []:
        task = str(record["task"])
        label_id = int(record["label_id"])
        backend_name = str(record["backend_name"])
        by_exact[(task, label_id, backend_name)] = record
        by_task_label[(task, label_id)] = record
        for alias in record.get("aliases") or []:
            by_alias[(task, normalize_label_identity(alias))] = record
    return by_exact, by_task_label, by_alias


def fallback_display_color(task, label_id, backend_name):
    """
    Generates a stable display color for a label based on its identity components.

    Parameters:
    	task (str): Task name or identifier.
    	label_id (int): Label identifier number.
    	backend_name (str): Backend name of the label.

    Returns:
    	list: A list of three integers [R, G, B], each in the range [0, 255].
    """
    seed = f"{task}:{int(label_id)}:{backend_name}".encode("utf-8")
    digest = hashlib.sha256(seed).digest()
    hue = int.from_bytes(digest[:2], "big") / 65535.0
    saturation = 0.65 + (digest[2] / 255.0) * 0.25
    value = 0.82 + (digest[3] / 255.0) * 0.15
    red, green, blue = colorsys.hsv_to_rgb(hue, saturation, value)
    return [round(red * 255), round(green * 255), round(blue * 255)]


def resolve_label_metadata(task, label_id, backend_name, resource=None):
    """
    Resolve label metadata from the terminology resource.

    Searches for a matching record by attempting matches in order of decreasing
    specificity: exact match (task, label_id, backend_name), then task and
    label_id only, then task and normalized backend_name as an alias. If no
    match is found, returns a fallback entry.

    Parameters:
        resource: Optional terminology resource. If not provided, loads the
                  cached terminology resource.

    Returns:
        A dictionary containing label metadata. Includes missing_mapping: True
        if no match was found in the terminology.
    """
    resource = resource or load_terminology_resource()
    task = str(task or "total")
    label_id = int(label_id)
    backend_name = str(backend_name)
    by_exact, by_task_label, by_alias = _records_by_identity(resource)

    record = (
        by_exact.get((task, label_id, backend_name))
        or by_task_label.get((task, label_id))
        or by_alias.get((task, normalize_label_identity(backend_name)))
    )
    if record is not None:
        return dict(record)

    normalized_backend = normalize_label_identity(backend_name)
    return {
        "canonical_key": f"{task}:{label_id}:{normalized_backend}",
        "stable_label_id": f"{task}:{label_id}",
        "task": task,
        "label_id": label_id,
        "backend_name": backend_name,
        "display_name": backend_name,
        "display_color": fallback_display_color(task, label_id, backend_name),
        "aliases": [backend_name],
        "laterality": "unknown",
        "anatomic_region": backend_name,
        "coded_concepts": {},
        "terminology_source": "fallback",
        "missing_mapping": True,
        "diagnostic": "missing_slicer_terminology_mapping",
    }


def label_map_record(label_id, backend_name, task, present, resource=None):
    """
    Create a label mapping record with resolved terminology metadata.

    Parameters:
    	present: Collection of present label IDs; determines the "present" field in the record.

    Returns:
    	dict: A mapping record with label index, name, presence status, and terminology metadata.
    """
    metadata = resolve_label_metadata(task, label_id, backend_name, resource=resource)
    record = {
        "index": int(label_id),
        "name": str(backend_name),
        "present": int(label_id) in set(int(value) for value in present),
    }
    for key in (
        "canonical_key",
        "stable_label_id",
        "backend_name",
        "display_name",
        "display_color",
        "aliases",
        "laterality",
        "anatomic_region",
        "coded_concepts",
        "terminology_source",
        "missing_mapping",
        "diagnostic",
    ):
        if key in metadata:
            record[key] = metadata[key]
    return record
