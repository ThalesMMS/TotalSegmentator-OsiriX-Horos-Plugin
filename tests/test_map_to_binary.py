#
# test_map_to_binary.py
# TotalSegmentator
#
# Regression tests for label-map compatibility exports.
#

"""Tests for TotalSegmentator label map compatibility exports."""

import hashlib
import json
from pathlib import Path
import unittest

from totalsegmentator import map_to_binary


EXPECTED_EXPORTS = [
    "class_map",
    "class_map_5_parts",
    "class_map_parts_headneck_muscles",
    "class_map_parts_mr",
    "commercial_models",
    "map_taskid_to_partname_ct",
    "map_taskid_to_partname_headneck_muscles",
    "map_taskid_to_partname_mr",
]

EXPECTED_HASHES = {
    "class_map": "98d64763078fbfe8e99c60934657e6e82934f41514218b4adcbb76b56d75e530",
    "commercial_models": "950aa01faa6f8b74a156d4a6c509992a40a6df0ab663513dc9b407f57e200f03",
    "class_map_5_parts": "81b3d64574cb8f0608a07690f7cacb2522bcdda0fbe0c69b408eb72a20a31fa6",
    "class_map_parts_mr": "7203de47f084b56bd9231e846be28d0e30ae50fb3bed2f733b19714991386fa3",
    "class_map_parts_headneck_muscles": "09fec0b6ca595735f53de0971b154507bd100eea77d7499575c8584cfc9be6c1",
    "map_taskid_to_partname_ct": "b4a40a1557220492f0434de07be22ed867e826c638d773bba86748e27fd52697",
    "map_taskid_to_partname_mr": "681f7a5dcf83eed9d8a805f5ada3b3c8e7a81c80fa4fe111d2850e5ee2aebb07",
    "map_taskid_to_partname_headneck_muscles": "81721a0e8b42183ce6be57ef630d1d58c66f79b696735b072f75a126ddc10491",
}

EXPECTED_CLASS_MAP_COUNTS = {
    "total_v1": 104,
    "total": 117,
    "total_mr": 50,
    "teeth": 77,
    "test": 1,
}

EXPECTED_PART_COUNTS = {
    "class_map_part_organs": 24,
    "class_map_part_vertebrae": 26,
    "class_map_part_cardiac": 18,
    "class_map_part_muscles": 23,
    "class_map_part_ribs": 26,
    "test": 1,
}


def export_hash(value):
    """Return a SHA-256 hex digest of a key-type-preserving representation."""
    payload = json.dumps(_normalize_for_hash(value), separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def _normalize_for_hash(value):
    if isinstance(value, dict):
        return [
            "dict",
            [
                [*_normalize_key(key), _normalize_for_hash(item)]
                for key, item in sorted(value.items(), key=lambda entry: _sort_key(entry[0]))
            ],
        ]
    if isinstance(value, list):
        return ["list", [_normalize_for_hash(item) for item in value]]
    if isinstance(value, tuple):
        return ["tuple", [_normalize_for_hash(item) for item in value]]
    return [type(value).__name__, value]


def _normalize_key(key):
    if isinstance(key, (str, int, float, bool)) or key is None:
        return [type(key).__name__, key]
    return [type(key).__name__, repr(key)]


def _sort_key(key):
    key_type, key_value = _normalize_key(key)
    return (key_type, key_value)


class TestMapToBinaryCompatibility(unittest.TestCase):
    def test_public_exports_are_available(self):
        self.assertEqual(sorted(map_to_binary.__all__), sorted(EXPECTED_EXPORTS))
        for export_name in EXPECTED_EXPORTS:
            self.assertTrue(hasattr(map_to_binary, export_name), export_name)

    def test_exported_data_is_unchanged(self):
        for export_name, expected_hash in EXPECTED_HASHES.items():
            self.assertEqual(export_hash(getattr(map_to_binary, export_name)), expected_hash, export_name)

    def test_key_label_counts_are_stable(self):
        self.assertEqual(len(map_to_binary.class_map), 45)
        self.assertEqual(len(map_to_binary.commercial_models), 14)
        self.assertEqual(len(map_to_binary.class_map_5_parts), 6)
        self.assertEqual(len(map_to_binary.class_map_parts_mr), 2)
        self.assertEqual(len(map_to_binary.class_map_parts_headneck_muscles), 2)

        for class_map_name, expected_count in EXPECTED_CLASS_MAP_COUNTS.items():
            self.assertEqual(len(map_to_binary.class_map[class_map_name]), expected_count, class_map_name)

        for part_name, expected_count in EXPECTED_PART_COUNTS.items():
            self.assertEqual(len(map_to_binary.class_map_5_parts[part_name]), expected_count, part_name)

    def test_sentinel_labels_resolve(self):
        self.assertEqual(map_to_binary.class_map["total"][5], "liver")
        self.assertEqual(map_to_binary.class_map["total"][90], "brain")
        self.assertEqual(map_to_binary.class_map["total_mr"][5], "liver")
        self.assertEqual(map_to_binary.class_map["teeth"][77], "lower_right_third_molar_pulp_fdi148")
        self.assertEqual(map_to_binary.class_map_5_parts["class_map_part_organs"][5], "liver")
        self.assertEqual(map_to_binary.class_map_parts_mr["class_map_part_muscles"][21], "brain")
        self.assertEqual(map_to_binary.class_map_parts_headneck_muscles["class_map_part_muscles_2"][12], "prevertebral_left")
        self.assertEqual(map_to_binary.map_taskid_to_partname_ct[291], "class_map_part_organs")
        self.assertEqual(map_to_binary.map_taskid_to_partname_mr[850], "class_map_part_organs")
        self.assertEqual(map_to_binary.map_taskid_to_partname_headneck_muscles[779], "class_map_part_muscles_2")

    def test_test_part_map_reuses_class_map_entry(self):
        self.assertIs(map_to_binary.class_map_5_parts["test"], map_to_binary.class_map["test"])


class TestSourceLineCounts(unittest.TestCase):
    def test_project_source_files_are_at_most_1000_lines(self):
        repo_root = Path(__file__).resolve().parents[1]
        source_roots = [
            repo_root / "totalsegmentator",
            repo_root / "tests",
            repo_root / "resources",
            repo_root / "MyOsiriXPluginFolder-Swift",
        ]
        source_suffixes = {".py", ".swift", ".h", ".m", ".sh"}
        skipped_parts = {"build", "__pycache__", ".pytest_cache"}

        oversized_files = []
        for source_root in source_roots:
            for path in source_root.rglob("*"):
                if not path.is_file() or path.suffix not in source_suffixes:
                    continue
                if skipped_parts.intersection(path.parts):
                    continue
                if any(part.endswith(".framework") for part in path.parts):
                    continue

                with path.open() as source_file:
                    line_count = sum(1 for _ in source_file)

                if line_count > 1000:
                    oversized_files.append((line_count, path.relative_to(repo_root).as_posix()))

        self.assertEqual(oversized_files, [])


if __name__ == "__main__":
    unittest.main()
