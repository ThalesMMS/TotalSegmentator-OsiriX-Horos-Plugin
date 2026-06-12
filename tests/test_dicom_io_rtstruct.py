#
# test_dicom_io_rtstruct.py
# TotalSegmentator
#
# Tests RT Struct mask formatting for DICOM export.
#

"""Test RT Struct masks passed to rt_utils."""

import sys
import types
import unittest
from unittest.mock import patch

import nibabel as nib
import numpy as np

from totalsegmentator import dicom_io


class FakeRTStruct:
    def __init__(self):
        self.rois = []
        self.saved_path = None

    def add_roi(self, mask, name, color=None):
        self.rois.append((mask, name, color))

    def save(self, path):
        self.saved_path = path


class FakeRTStructBuilder:
    created = None
    dicom_series_path = None

    @classmethod
    def create_new(cls, dicom_series_path):
        cls.dicom_series_path = dicom_series_path
        cls.created = FakeRTStruct()
        return cls.created


class SaveMaskAsRTStructTests(unittest.TestCase):
    def setUp(self):
        FakeRTStructBuilder.created = None
        FakeRTStructBuilder.dicom_series_path = None

    def test_passes_boolean_row_column_slice_mask_to_rt_utils(self):
        lps_volume = np.zeros((2, 3, 4), dtype=np.uint8)
        lps_volume[1, 2, 3] = 1
        expected_mask = np.ascontiguousarray(np.transpose(lps_volume == 1, (1, 0, 2)))
        fake_rt_utils = types.SimpleNamespace(RTStructBuilder=FakeRTStructBuilder)
        segmentation_img = nib.Nifti1Image(np.zeros((1, 1, 1), dtype=np.uint8), np.eye(4))

        with patch.dict(sys.modules, {"rt_utils": fake_rt_utils}), patch.object(
            dicom_io, "_reorient_to_lps", return_value=lps_volume
        ):
            dicom_io.save_mask_as_rtstruct(
                segmentation_img,
                {1: "sample_organ"},
                "/tmp/reference-dicom",
                "/tmp/output.dcm",
            )

        self.assertEqual(FakeRTStructBuilder.dicom_series_path, "/tmp/reference-dicom")
        self.assertEqual(FakeRTStructBuilder.created.saved_path, "/tmp/output.dcm")
        self.assertEqual(len(FakeRTStructBuilder.created.rois), 1)

        mask, name, color = FakeRTStructBuilder.created.rois[0]
        self.assertEqual(name, "sample_organ")
        self.assertEqual(color, [230, 25, 75])
        self.assertEqual(mask.dtype, np.bool_)
        self.assertEqual(mask.shape, (3, 2, 4))
        self.assertTrue(mask.flags["C_CONTIGUOUS"])
        np.testing.assert_array_equal(mask, expected_mask)

    def test_normalizes_string_class_indices_before_building_rtstruct_mask(self):
        lps_volume = np.zeros((2, 3, 4), dtype=np.uint8)
        lps_volume[1, 2, 3] = 1
        expected_mask = np.ascontiguousarray(np.transpose(lps_volume == 1, (1, 0, 2)))
        fake_rt_utils = types.SimpleNamespace(RTStructBuilder=FakeRTStructBuilder)
        segmentation_img = nib.Nifti1Image(np.zeros((1, 1, 1), dtype=np.uint8), np.eye(4))

        with patch.dict(sys.modules, {"rt_utils": fake_rt_utils}), patch.object(
            dicom_io, "_reorient_to_lps", return_value=lps_volume
        ):
            dicom_io.save_mask_as_rtstruct(
                segmentation_img,
                {"1": "sample_organ"},
                "/tmp/reference-dicom",
                "/tmp/output.dcm",
            )

        self.assertEqual(len(FakeRTStructBuilder.created.rois), 1)
        mask, name, color = FakeRTStructBuilder.created.rois[0]
        self.assertEqual(name, "sample_organ")
        self.assertEqual(color, [230, 25, 75])
        np.testing.assert_array_equal(mask, expected_mask)

    def test_raises_clear_error_before_rt_utils_when_mask_is_not_three_dimensional(self):
        lps_volume = np.zeros((2, 3), dtype=np.uint8)
        fake_rt_utils = types.SimpleNamespace(RTStructBuilder=FakeRTStructBuilder)
        segmentation_img = nib.Nifti1Image(np.zeros((1, 1, 1), dtype=np.uint8), np.eye(4))

        with patch.dict(sys.modules, {"rt_utils": fake_rt_utils}), patch.object(
            dicom_io, "_reorient_to_lps", return_value=lps_volume
        ):
            with self.assertRaisesRegex(ValueError, "must be a 3D numpy array"):
                dicom_io.save_mask_as_rtstruct(
                    segmentation_img,
                    {1: "sample_organ"},
                    "/tmp/reference-dicom",
                    "/tmp/output.dcm",
                )


if __name__ == "__main__":
    unittest.main()
