#
# test_dicom_io_volumetric_roi_projection.py
# TotalSegmentator
#
# Tests volumetric ROI mask projection for live Horos/OsiriX reslice views.
#

"""Test projected volumetric ROI manifests."""

import tempfile
import unittest
from pathlib import Path

import nibabel as nib
import numpy as np

from totalsegmentator import dicom_io


class VolumetricROIProjectionTests(unittest.TestCase):
    def test_generates_axial_sagittal_and_coronal_projected_masks(self):
        data = np.zeros((4, 5, 6), dtype=np.uint16)
        data[1, 2, 3] = 1
        segmentation_img = nib.Nifti1Image(data, np.eye(4))
        planes = [
            self._plane(
                identifier="axial",
                slice_index=0,
                rows=5,
                columns=4,
                image_position=[0, 0, 3],
                row_cosine=[-1, 0, 0],
                column_cosine=[0, -1, 0],
            ),
            self._plane(
                identifier="sagittal",
                slice_index=1,
                rows=5,
                columns=6,
                image_position=[-1, 0, 0],
                row_cosine=[0, 0, 1],
                column_cosine=[0, -1, 0],
            ),
            self._plane(
                identifier="coronal",
                slice_index=2,
                rows=6,
                columns=4,
                image_position=[0, -2, 0],
                row_cosine=[-1, 0, 0],
                column_cosine=[0, 0, 1],
            ),
        ]

        with tempfile.TemporaryDirectory() as tmp_dir:
            manifest_path = dicom_io.generate_projected_volumetric_roi_manifest(
                segmentation_img=segmentation_img,
                mapping={1: "sample_organ"},
                planes=planes,
                output_dir=Path(tmp_dir),
                source_segmentation_path="/tmp/source_segmentation.nii.gz",
            )

            manifest = dicom_io.load_volumetric_roi_manifest(manifest_path)

            self.assertEqual(manifest["source_segmentation_path"], "/tmp/source_segmentation.nii.gz")
            self.assertEqual(manifest["label_count"], 1)
            self.assert_manifest_has_unique_label_slices(manifest)
            slices = manifest["labels"][0]["slices"]
            self.assertEqual([item["sop_instance_uid"] for item in slices], ["axial", "sagittal", "coronal"])

            axial = self._read_mask(slices[0])
            sagittal = self._read_mask(slices[1])
            coronal = self._read_mask(slices[2])

            self.assertEqual(int(axial.sum()), 255)
            self.assertEqual(int(sagittal.sum()), 255)
            self.assertEqual(int(coronal.sum()), 255)
            self.assertEqual(axial[2, 1], 255)
            self.assertEqual(sagittal[2, 3], 255)
            self.assertEqual(coronal[3, 1], 255)

    def test_rejects_duplicate_viewer_slice_indexes(self):
        data = np.zeros((4, 5, 6), dtype=np.uint16)
        segmentation_img = nib.Nifti1Image(data, np.eye(4))
        planes = [
            self._plane(
                identifier="first",
                slice_index=0,
                rows=5,
                columns=4,
                image_position=[0, 0, 0],
                row_cosine=[-1, 0, 0],
                column_cosine=[0, -1, 0],
            ),
            self._plane(
                identifier="second",
                slice_index=0,
                rows=5,
                columns=4,
                image_position=[0, 0, 1],
                row_cosine=[-1, 0, 0],
                column_cosine=[0, -1, 0],
            ),
        ]

        with tempfile.TemporaryDirectory() as tmp_dir:
            with self.assertRaisesRegex(ValueError, "unique slice_index"):
                dicom_io.generate_projected_volumetric_roi_manifest(
                    segmentation_img=segmentation_img,
                    mapping={1: "sample_organ"},
                    planes=planes,
                    output_dir=Path(tmp_dir),
                )

    def _plane(self, identifier, slice_index, rows, columns, image_position, row_cosine, column_cosine):
        return {
            "slice_index": slice_index,
            "sop_instance_uid": identifier,
            "rows": rows,
            "columns": columns,
            "row_spacing": 1.0,
            "column_spacing": 1.0,
            "image_position": image_position,
            "row_cosine": row_cosine,
            "column_cosine": column_cosine,
        }

    def _read_mask(self, slice_record):
        rows = slice_record["rows"]
        columns = slice_record["columns"]
        return np.fromfile(slice_record["raw_path"], dtype=np.uint8).reshape((rows, columns))

    def assert_manifest_has_unique_label_slices(self, manifest):
        seen = set()
        for label in manifest["labels"]:
            for slice_record in label["slices"]:
                key = (label["name"], slice_record["slice_index"])
                self.assertNotIn(key, seen)
                seen.add(key)


if __name__ == "__main__":
    unittest.main()
