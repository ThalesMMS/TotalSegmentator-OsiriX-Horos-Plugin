"""Tabelas que mapeiam subconjuntos binarios e partes de modelos."""

from totalsegmentator.label_maps.class_map import class_map


def _select_labels(source_map, first_label, last_label):
    if first_label > last_label:
        raise ValueError(f"Invalid label range: first_label ({first_label}) is greater than last_label ({last_label})")

    expected_labels = range(first_label, last_label + 1)
    missing_labels = [label for label in expected_labels if label not in source_map]
    if missing_labels:
        raise ValueError(f"Source label map is missing expected label(s): {missing_labels}")

    return {
        output_label: source_map[source_label]
        for output_label, source_label in enumerate(expected_labels, start=1)
    }


class_map_5_parts = {
    "class_map_part_organs": _select_labels(class_map["total"], 1, 24),
    "class_map_part_vertebrae": _select_labels(class_map["total"], 25, 50),
    "class_map_part_cardiac": _select_labels(class_map["total"], 51, 68),
    "class_map_part_muscles": _select_labels(class_map["total"], 69, 91),
    "class_map_part_ribs": _select_labels(class_map["total"], 92, 117),
    "test": class_map["test"],
}


class_map_parts_mr = {
    "class_map_part_organs": _select_labels(class_map["total_mr"], 1, 29),
    "class_map_part_muscles": _select_labels(class_map["total_mr"], 30, 50),
}


class_map_parts_headneck_muscles = {
    "class_map_part_muscles_1": _select_labels(class_map["headneck_muscles"], 1, 11),
    "class_map_part_muscles_2": _select_labels(class_map["headneck_muscles"], 12, 23),
}


map_taskid_to_partname_ct = {
    291: "class_map_part_organs",
    292: "class_map_part_vertebrae",
    293: "class_map_part_cardiac",
    294: "class_map_part_muscles",
    295: "class_map_part_ribs",

    517: "test",
}

map_taskid_to_partname_mr = {
    850: "class_map_part_organs",
    851: "class_map_part_muscles"
}

map_taskid_to_partname_headneck_muscles = {
    778: "class_map_part_muscles_1",
    779: "class_map_part_muscles_2"
}
