#
# map_to_binary.py
# TotalSegmentator
#
# Compatibility exports for label maps from multi-class IDs to binary subsets.
#
# Thales Matheus Mendonca Santos - November 2025
#

"""Compatibility exports for TotalSegmentator label maps."""

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

__all__ = [
    "class_map",
    "class_map_5_parts",
    "class_map_parts_headneck_muscles",
    "class_map_parts_mr",
    "commercial_models",
    "map_taskid_to_partname_ct",
    "map_taskid_to_partname_headneck_muscles",
    "map_taskid_to_partname_mr",
]
