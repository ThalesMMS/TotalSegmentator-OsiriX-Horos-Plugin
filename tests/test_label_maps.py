"""Tests for the totalsegmentator.label_maps subpackage."""

import unittest

from totalsegmentator.label_maps import class_map as class_map_module
from totalsegmentator.label_maps import commercial as commercial_module
from totalsegmentator.label_maps import parts as parts_module
from totalsegmentator.label_maps.class_map import class_map
from totalsegmentator.label_maps.commercial import commercial_models
from totalsegmentator.label_maps.parts import (
    class_map_5_parts,
    class_map_parts_headneck_muscles,
    class_map_parts_mr,
    map_taskid_to_partname_ct,
    map_taskid_to_partname_headneck_muscles,
    map_taskid_to_partname_mr,
)


# Maps whose integer keys do NOT start at 1 (auxiliary or commented-out entries).
_NON_STANDARD_START_MAPS = {
    "pleural_pericard_effusion",
    "appendicular_bones_auxiliary",
    "face_mr_auxiliary",
    "kidney_cysts_auxiliary",
}


class TestLabelMapsPackage(unittest.TestCase):
    """Verify that the label_maps package and its sub-modules are importable."""

    def test_class_map_module_is_importable(self):
        self.assertIsNotNone(class_map_module)

    def test_commercial_module_is_importable(self):
        self.assertIsNotNone(commercial_module)

    def test_parts_module_is_importable(self):
        self.assertIsNotNone(parts_module)

    def test_init_has_docstring(self):
        import totalsegmentator.label_maps as pkg
        self.assertIsNotNone(pkg.__doc__)
        self.assertGreater(len(pkg.__doc__.strip()), 0)


class TestClassMapStructure(unittest.TestCase):
    """Structural integrity tests for label_maps/class_map.py."""

    def test_class_map_is_dict(self):
        self.assertIsInstance(class_map, dict)

    def test_class_map_total_entry_count(self):
        self.assertEqual(len(class_map), 45)

    def test_all_top_level_keys_are_strings(self):
        for key in class_map:
            self.assertIsInstance(key, str, f"Top-level key {key!r} is not a str")

    def test_all_entries_are_dicts(self):
        for name, entry in class_map.items():
            self.assertIsInstance(entry, dict, f"class_map[{name!r}] is not a dict")

    def test_all_label_keys_are_integers(self):
        for name, entry in class_map.items():
            for k in entry:
                self.assertIsInstance(k, int, f"class_map[{name!r}] has non-int key {k!r}")

    def test_all_label_values_are_strings(self):
        for name, entry in class_map.items():
            for k, v in entry.items():
                self.assertIsInstance(v, str, f"class_map[{name!r}][{k}] value {v!r} is not a str")

    def test_no_empty_label_strings(self):
        for name, entry in class_map.items():
            for k, v in entry.items():
                self.assertTrue(v.strip(), f"class_map[{name!r}][{k}] is blank or whitespace-only")

    def test_no_duplicate_labels_within_entry(self):
        for name, entry in class_map.items():
            values = list(entry.values())
            self.assertEqual(len(values), len(set(values)), f"class_map[{name!r}] has duplicate label values")

    def test_standard_entries_start_at_key_1(self):
        for name, entry in class_map.items():
            if name in _NON_STANDARD_START_MAPS:
                continue
            self.assertEqual(min(entry.keys()), 1, f"class_map[{name!r}] min key is not 1")

    def test_standard_entries_have_contiguous_keys(self):
        for name, entry in class_map.items():
            if name in _NON_STANDARD_START_MAPS:
                continue
            keys = sorted(entry.keys())
            expected = list(range(1, len(keys) + 1))
            self.assertEqual(keys, expected, f"class_map[{name!r}] has non-contiguous integer keys")

    def test_total_v1_boundaries(self):
        m = class_map["total_v1"]
        self.assertEqual(m[1], "spleen")
        self.assertEqual(m[104], "urinary_bladder")
        self.assertEqual(len(m), 104)

    def test_total_boundaries(self):
        m = class_map["total"]
        self.assertEqual(m[1], "spleen")
        self.assertEqual(m[117], "costal_cartilages")
        self.assertEqual(len(m), 117)

    def test_total_mr_boundaries(self):
        m = class_map["total_mr"]
        self.assertEqual(m[1], "spleen")
        self.assertEqual(m[50], "brain")
        self.assertEqual(len(m), 50)

    def test_teeth_boundaries(self):
        m = class_map["teeth"]
        self.assertEqual(m[1], "lower_jawbone")
        self.assertEqual(m[77], "lower_right_third_molar_pulp_fdi148")
        self.assertEqual(len(m), 77)

    def test_test_entry_is_single_carpal(self):
        self.assertEqual(class_map["test"], {1: "carpal"})

    def test_pleural_pericard_effusion_has_keys_2_and_3(self):
        m = class_map["pleural_pericard_effusion"]
        self.assertNotIn(1, m)
        self.assertIn(2, m)
        self.assertIn(3, m)
        self.assertEqual(m[2], "pleural_effusion")
        self.assertEqual(m[3], "pericardial_effusion")

    def test_appendicular_bones_mr_stops_at_key_8(self):
        m = class_map["appendicular_bones_mr"]
        self.assertEqual(len(m), 8)
        self.assertNotIn(9, m)

    def test_total_v1_does_not_contain_vertebrae_s1(self):
        # total_v1 goes L5..C1 without vertebrae_S1
        self.assertNotIn("vertebrae_S1", class_map["total_v1"].values())

    def test_total_contains_vertebrae_s1(self):
        self.assertIn("vertebrae_S1", class_map["total"].values())

    def test_specific_class_map_lookups(self):
        self.assertEqual(class_map["total"][7], "pancreas")
        self.assertEqual(class_map["total"][52], "aorta")
        self.assertEqual(class_map["total_mr"][22], "heart")
        self.assertEqual(class_map["total_v1"][7], "aorta")
        self.assertEqual(class_map["oculomotor_muscles"][1], "skull")
        self.assertEqual(class_map["heartchambers_highres"][1], "heart_myocardium")
        self.assertEqual(class_map["body"][1], "body_trunc")
        self.assertEqual(class_map["body"][2], "body_extremities")


class TestCommercialModels(unittest.TestCase):
    """Tests for label_maps/commercial.py."""

    def test_commercial_models_is_dict(self):
        self.assertIsInstance(commercial_models, dict)

    def test_commercial_models_count(self):
        self.assertEqual(len(commercial_models), 14)

    def test_all_keys_are_strings(self):
        for k in commercial_models:
            self.assertIsInstance(k, str, f"Key {k!r} is not a str")

    def test_all_values_are_integers(self):
        for k, v in commercial_models.items():
            self.assertIsInstance(v, int, f"commercial_models[{k!r}] = {v!r} is not an int")

    def test_all_task_ids_are_positive(self):
        for k, v in commercial_models.items():
            self.assertGreater(v, 0, f"commercial_models[{k!r}] = {v} is not positive")

    def test_specific_entries(self):
        self.assertEqual(commercial_models["heartchambers_highres"], 301)
        self.assertEqual(commercial_models["appendicular_bones"], 304)
        self.assertEqual(commercial_models["appendicular_bones_mr"], 855)
        self.assertEqual(commercial_models["tissue_types"], 481)
        self.assertEqual(commercial_models["tissue_types_mr"], 925)
        self.assertEqual(commercial_models["tissue_4_types"], 485)
        self.assertEqual(commercial_models["vertebrae_body"], 305)
        self.assertEqual(commercial_models["face"], 303)
        self.assertEqual(commercial_models["face_mr"], 856)
        self.assertEqual(commercial_models["brain_structures"], 409)
        self.assertEqual(commercial_models["coronary_arteries"], 507)
        self.assertEqual(commercial_models["aortic_sinuses"], 920)

    def test_thigh_shoulder_muscles_share_task_id(self):
        self.assertEqual(
            commercial_models["thigh_shoulder_muscles"],
            commercial_models["thigh_shoulder_muscles_mr"],
        )

    def test_no_zero_task_id(self):
        for k, v in commercial_models.items():
            self.assertNotEqual(v, 0, f"commercial_models[{k!r}] is 0")


class TestClassMap5Parts(unittest.TestCase):
    """Structural tests for class_map_5_parts in label_maps/parts.py."""

    def test_class_map_5_parts_is_dict(self):
        self.assertIsInstance(class_map_5_parts, dict)

    def test_class_map_5_parts_has_exactly_six_keys(self):
        expected_keys = {
            "class_map_part_organs",
            "class_map_part_vertebrae",
            "class_map_part_cardiac",
            "class_map_part_muscles",
            "class_map_part_ribs",
            "test",
        }
        self.assertEqual(set(class_map_5_parts.keys()), expected_keys)

    def test_organs_count(self):
        self.assertEqual(len(class_map_5_parts["class_map_part_organs"]), 24)

    def test_vertebrae_count(self):
        self.assertEqual(len(class_map_5_parts["class_map_part_vertebrae"]), 26)

    def test_cardiac_count(self):
        self.assertEqual(len(class_map_5_parts["class_map_part_cardiac"]), 18)

    def test_muscles_count(self):
        self.assertEqual(len(class_map_5_parts["class_map_part_muscles"]), 23)

    def test_ribs_count(self):
        self.assertEqual(len(class_map_5_parts["class_map_part_ribs"]), 26)

    def test_test_part_count(self):
        self.assertEqual(len(class_map_5_parts["test"]), 1)

    def test_all_named_parts_have_contiguous_keys_from_1(self):
        named_parts = [k for k in class_map_5_parts if k != "test"]
        for part_name in named_parts:
            entry = class_map_5_parts[part_name]
            keys = sorted(entry.keys())
            self.assertEqual(keys, list(range(1, len(keys) + 1)), f"{part_name} keys are not contiguous from 1")

    def test_no_duplicate_labels_within_any_part(self):
        for part_name, entry in class_map_5_parts.items():
            values = list(entry.values())
            self.assertEqual(len(values), len(set(values)), f"{part_name} has duplicate labels")

    def test_test_entry_is_same_object_as_class_map_test(self):
        self.assertIs(class_map_5_parts["test"], class_map["test"])

    def test_organs_specific_lookups(self):
        m = class_map_5_parts["class_map_part_organs"]
        self.assertEqual(m[1], "spleen")
        self.assertEqual(m[5], "liver")
        self.assertEqual(m[24], "kidney_cyst_right")

    def test_vertebrae_specific_lookups(self):
        m = class_map_5_parts["class_map_part_vertebrae"]
        self.assertEqual(m[1], "sacrum")
        self.assertEqual(m[2], "vertebrae_S1")
        self.assertEqual(m[26], "vertebrae_C1")

    def test_cardiac_specific_lookups(self):
        m = class_map_5_parts["class_map_part_cardiac"]
        self.assertEqual(m[1], "heart")
        self.assertEqual(m[2], "aorta")
        self.assertEqual(m[18], "iliac_vena_right")

    def test_muscles_specific_lookups(self):
        m = class_map_5_parts["class_map_part_muscles"]
        self.assertEqual(m[1], "humerus_left")
        self.assertEqual(m[22], "brain")
        self.assertEqual(m[23], "skull")

    def test_ribs_specific_lookups(self):
        m = class_map_5_parts["class_map_part_ribs"]
        self.assertEqual(m[1], "rib_left_1")
        self.assertEqual(m[12], "rib_left_12")
        self.assertEqual(m[13], "rib_right_1")
        self.assertEqual(m[25], "sternum")
        self.assertEqual(m[26], "costal_cartilages")

    def test_ribs_left_and_right_each_have_12_entries(self):
        m = class_map_5_parts["class_map_part_ribs"]
        left_ribs = [v for v in m.values() if v.startswith("rib_left_")]
        right_ribs = [v for v in m.values() if v.startswith("rib_right_")]
        self.assertEqual(len(left_ribs), 12)
        self.assertEqual(len(right_ribs), 12)


class TestClassMapPartsMr(unittest.TestCase):
    """Structural tests for class_map_parts_mr in label_maps/parts.py."""

    def test_class_map_parts_mr_is_dict(self):
        self.assertIsInstance(class_map_parts_mr, dict)

    def test_class_map_parts_mr_has_exactly_two_keys(self):
        self.assertEqual(set(class_map_parts_mr.keys()), {"class_map_part_organs", "class_map_part_muscles"})

    def test_mr_organs_count(self):
        self.assertEqual(len(class_map_parts_mr["class_map_part_organs"]), 29)

    def test_mr_muscles_count(self):
        self.assertEqual(len(class_map_parts_mr["class_map_part_muscles"]), 21)

    def test_mr_organs_contiguous_keys_from_1(self):
        keys = sorted(class_map_parts_mr["class_map_part_organs"].keys())
        self.assertEqual(keys, list(range(1, 30)))

    def test_mr_muscles_contiguous_keys_from_1(self):
        keys = sorted(class_map_parts_mr["class_map_part_muscles"].keys())
        self.assertEqual(keys, list(range(1, 22)))

    def test_mr_organs_specific_lookups(self):
        m = class_map_parts_mr["class_map_part_organs"]
        self.assertEqual(m[1], "spleen")
        self.assertEqual(m[5], "liver")
        self.assertEqual(m[29], "iliac_vena_right")

    def test_mr_muscles_specific_lookups(self):
        m = class_map_parts_mr["class_map_part_muscles"]
        self.assertEqual(m[1], "humerus_left")
        self.assertEqual(m[21], "brain")

    def test_mr_organs_no_duplicate_labels(self):
        values = list(class_map_parts_mr["class_map_part_organs"].values())
        self.assertEqual(len(values), len(set(values)))

    def test_mr_muscles_no_duplicate_labels(self):
        values = list(class_map_parts_mr["class_map_part_muscles"].values())
        self.assertEqual(len(values), len(set(values)))

    def test_mr_muscles_does_not_have_spinal_cord(self):
        # Unlike CT muscles, MR muscles part has no spinal_cord
        self.assertNotIn("spinal_cord", class_map_parts_mr["class_map_part_muscles"].values())

    def test_mr_organs_has_intervertebral_discs(self):
        # MR organs has vertebrae-related entries not present in CT organs
        self.assertIn("intervertebral_discs", class_map_parts_mr["class_map_part_organs"].values())


class TestClassMapPartsHeadneckMuscles(unittest.TestCase):
    """Structural tests for class_map_parts_headneck_muscles in label_maps/parts.py."""

    def test_class_map_parts_headneck_muscles_is_dict(self):
        self.assertIsInstance(class_map_parts_headneck_muscles, dict)

    def test_class_map_parts_headneck_muscles_has_exactly_two_keys(self):
        self.assertEqual(
            set(class_map_parts_headneck_muscles.keys()),
            {"class_map_part_muscles_1", "class_map_part_muscles_2"},
        )

    def test_muscles_1_count(self):
        self.assertEqual(len(class_map_parts_headneck_muscles["class_map_part_muscles_1"]), 11)

    def test_muscles_2_count(self):
        self.assertEqual(len(class_map_parts_headneck_muscles["class_map_part_muscles_2"]), 12)

    def test_muscles_1_contiguous_keys_from_1(self):
        keys = sorted(class_map_parts_headneck_muscles["class_map_part_muscles_1"].keys())
        self.assertEqual(keys, list(range(1, 12)))

    def test_muscles_2_contiguous_keys_from_1(self):
        keys = sorted(class_map_parts_headneck_muscles["class_map_part_muscles_2"].keys())
        self.assertEqual(keys, list(range(1, 13)))

    def test_muscles_1_specific_lookups(self):
        m = class_map_parts_headneck_muscles["class_map_part_muscles_1"]
        self.assertEqual(m[1], "sternocleidomastoid_right")
        self.assertEqual(m[2], "sternocleidomastoid_left")
        self.assertEqual(m[11], "levator_scapulae_left")

    def test_muscles_2_specific_lookups(self):
        m = class_map_parts_headneck_muscles["class_map_part_muscles_2"]
        self.assertEqual(m[1], "anterior_scalene_right")
        self.assertEqual(m[11], "prevertebral_right")
        self.assertEqual(m[12], "prevertebral_left")

    def test_muscles_1_no_duplicate_labels(self):
        values = list(class_map_parts_headneck_muscles["class_map_part_muscles_1"].values())
        self.assertEqual(len(values), len(set(values)))

    def test_muscles_2_no_duplicate_labels(self):
        values = list(class_map_parts_headneck_muscles["class_map_part_muscles_2"].values())
        self.assertEqual(len(values), len(set(values)))

    def test_muscles_1_and_2_have_no_overlapping_labels(self):
        labels_1 = set(class_map_parts_headneck_muscles["class_map_part_muscles_1"].values())
        labels_2 = set(class_map_parts_headneck_muscles["class_map_part_muscles_2"].values())
        self.assertEqual(labels_1 & labels_2, set(), "muscles_1 and muscles_2 share label(s)")


class TestTaskIdToPartnameMappings(unittest.TestCase):
    """Tests for task-ID to part-name mappings in label_maps/parts.py."""

    def test_map_taskid_to_partname_ct_has_six_entries(self):
        self.assertEqual(len(map_taskid_to_partname_ct), 6)

    def test_map_taskid_to_partname_mr_has_two_entries(self):
        self.assertEqual(len(map_taskid_to_partname_mr), 2)

    def test_map_taskid_to_partname_headneck_muscles_has_two_entries(self):
        self.assertEqual(len(map_taskid_to_partname_headneck_muscles), 2)

    def test_map_taskid_to_partname_ct_all_keys_are_ints(self):
        for k in map_taskid_to_partname_ct:
            self.assertIsInstance(k, int, f"CT task ID {k!r} is not an int")

    def test_map_taskid_to_partname_ct_all_values_are_strings(self):
        for v in map_taskid_to_partname_ct.values():
            self.assertIsInstance(v, str)

    def test_ct_task_ids_reference_valid_parts_in_class_map_5_parts(self):
        for task_id, part_name in map_taskid_to_partname_ct.items():
            self.assertIn(
                part_name,
                class_map_5_parts,
                f"CT task ID {task_id} maps to {part_name!r} which is not a key in class_map_5_parts",
            )

    def test_mr_task_ids_reference_valid_parts_in_class_map_parts_mr(self):
        for task_id, part_name in map_taskid_to_partname_mr.items():
            self.assertIn(
                part_name,
                class_map_parts_mr,
                f"MR task ID {task_id} maps to {part_name!r} which is not a key in class_map_parts_mr",
            )

    def test_headneck_task_ids_reference_valid_parts(self):
        for task_id, part_name in map_taskid_to_partname_headneck_muscles.items():
            self.assertIn(
                part_name,
                class_map_parts_headneck_muscles,
                f"Headneck task ID {task_id} maps to {part_name!r} which is not a key in class_map_parts_headneck_muscles",
            )

    def test_ct_exact_mappings(self):
        self.assertEqual(map_taskid_to_partname_ct[291], "class_map_part_organs")
        self.assertEqual(map_taskid_to_partname_ct[292], "class_map_part_vertebrae")
        self.assertEqual(map_taskid_to_partname_ct[293], "class_map_part_cardiac")
        self.assertEqual(map_taskid_to_partname_ct[294], "class_map_part_muscles")
        self.assertEqual(map_taskid_to_partname_ct[295], "class_map_part_ribs")
        self.assertEqual(map_taskid_to_partname_ct[517], "test")

    def test_mr_exact_mappings(self):
        self.assertEqual(map_taskid_to_partname_mr[850], "class_map_part_organs")
        self.assertEqual(map_taskid_to_partname_mr[851], "class_map_part_muscles")

    def test_headneck_exact_mappings(self):
        self.assertEqual(map_taskid_to_partname_headneck_muscles[778], "class_map_part_muscles_1")
        self.assertEqual(map_taskid_to_partname_headneck_muscles[779], "class_map_part_muscles_2")

    def test_ct_task_ids_are_positive_integers(self):
        for k in map_taskid_to_partname_ct:
            self.assertGreater(k, 0)

    def test_mr_task_ids_are_positive_integers(self):
        for k in map_taskid_to_partname_mr:
            self.assertGreater(k, 0)

    def test_headneck_task_ids_are_positive_integers(self):
        for k in map_taskid_to_partname_headneck_muscles:
            self.assertGreater(k, 0)


class TestMapToBinaryReExports(unittest.TestCase):
    """Verify that map_to_binary re-exports are the exact same objects as their sources."""

    def setUp(self):
        from totalsegmentator import map_to_binary as _mtb
        self.map_to_binary = _mtb

    def test_class_map_is_same_object(self):
        self.assertIs(self.map_to_binary.class_map, class_map)

    def test_commercial_models_is_same_object(self):
        self.assertIs(self.map_to_binary.commercial_models, commercial_models)

    def test_class_map_5_parts_is_same_object(self):
        self.assertIs(self.map_to_binary.class_map_5_parts, class_map_5_parts)

    def test_class_map_parts_mr_is_same_object(self):
        self.assertIs(self.map_to_binary.class_map_parts_mr, class_map_parts_mr)

    def test_class_map_parts_headneck_muscles_is_same_object(self):
        self.assertIs(self.map_to_binary.class_map_parts_headneck_muscles, class_map_parts_headneck_muscles)

    def test_map_taskid_to_partname_ct_is_same_object(self):
        self.assertIs(self.map_to_binary.map_taskid_to_partname_ct, map_taskid_to_partname_ct)

    def test_map_taskid_to_partname_mr_is_same_object(self):
        self.assertIs(self.map_to_binary.map_taskid_to_partname_mr, map_taskid_to_partname_mr)

    def test_map_taskid_to_partname_headneck_muscles_is_same_object(self):
        self.assertIs(self.map_to_binary.map_taskid_to_partname_headneck_muscles, map_taskid_to_partname_headneck_muscles)

    def test_all_exports_are_listed_in_dunder_all(self):
        expected = [
            "class_map",
            "class_map_5_parts",
            "class_map_parts_headneck_muscles",
            "class_map_parts_mr",
            "commercial_models",
            "map_taskid_to_partname_ct",
            "map_taskid_to_partname_headneck_muscles",
            "map_taskid_to_partname_mr",
        ]
        self.assertEqual(self.map_to_binary.__all__, expected)

    def test_no_unexpected_public_names_in_dunder_all(self):
        self.assertEqual(len(self.map_to_binary.__all__), 8)


if __name__ == "__main__":
    unittest.main()
