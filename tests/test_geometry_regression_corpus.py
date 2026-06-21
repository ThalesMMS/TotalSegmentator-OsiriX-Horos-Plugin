import json
import sys
import tempfile
from pathlib import Path

import nibabel as nib
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PARENT = ROOT / "MyOsiriXPluginFolder-Swift" / "python_bridge"
if str(BRIDGE_PARENT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_PARENT))

from ts_horos_bridge.volumetric_projection import generate_projected_volumetric_roi_manifest


CORPUS_PATH = ROOT / "tests" / "fixtures" / "geometry_corpus" / "v1" / "geometry-corpus.json"


def _load_corpus() -> dict:
    """
    Load the geometry corpus fixture from the JSON file.
    
    Returns:
    	dict: The parsed geometry corpus data.
    """
    with CORPUS_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def test_geometry_corpus_is_versioned_privacy_safe_and_covers_required_cases():
    corpus = _load_corpus()

    assert corpus["schema_version"] == 1
    assert corpus["corpus_version"] == "2026.06.geometry-v1"
    assert corpus["privacy"] == "synthetic-no-phi"
    assert corpus["coordinate_system"] == "DICOM_LPS_with_NIfTI_RAS_affines"

    fixture_ids = {fixture["id"] for fixture in corpus["fixtures"]}
    required_fixture_ids = {
        "axial_identity",
        "reversed_slice_order",
        "non_square_spacing",
        "oblique_acquisition",
        "negative_large_origin",
        "missing_sop_uid",
        "duplicate_sop_uid",
        "duplicate_slice_position_localizer",
        "mixed_orientation",
        "mixed_frame_of_reference",
        "same_dimensions_unrelated_series",
        "enhanced_multiframe",
        "mpr_derived_viewer",
        "boundary_touching_mask",
        "small_disconnected_components",
    }
    assert required_fixture_ids <= fixture_ids

    expected_failures = {
        fixture["id"]: fixture["expected_diagnostic"]
        for fixture in corpus["fixtures"]
        if fixture["expected_result"] == "reject"
    }
    assert expected_failures["same_dimensions_unrelated_series"] == "source_identity_mismatch"
    assert expected_failures["missing_sop_uid"] == "missing_sop_instance_uid"
    assert expected_failures["mpr_derived_viewer"] == "unsupported_derived_viewer_contract"


def test_golden_axial_round_trip_reconstructs_canonical_nifti_voxels_exactly():
    """
    Validate that axial volumetric ROI projection and reconstruction preserve voxel labels exactly.
    
    Tests the end-to-end workflow: constructs a labeled NIfTI volume from golden corpus data, generates a projected ROI manifest, reconstructs the volume from the manifest's per-slice raw files, and asserts voxel-wise equality with the original. Also verifies manifest metadata consistency (SOP instance UID ordering and slice count).
    """
    corpus = _load_corpus()
    golden = corpus["golden_round_trip"]
    shape = tuple(golden["shape"])
    data = np.zeros(shape, dtype=np.uint16)
    for voxel in golden["labeled_voxels"]:
        i, j, k = voxel["ijk"]
        data[i, j, k] = voxel["label"]

    segmentation_img = nib.Nifti1Image(data, np.eye(4))
    planes = [
        {
            "slice_index": k,
            "sop_instance_uid": f"golden-slice-{k:03d}",
            "rows": shape[1],
            "columns": shape[0],
            "row_spacing": 1.0,
            "column_spacing": 1.0,
            "image_position": [0.0, 0.0, float(k)],
            "row_cosine": [-1.0, 0.0, 0.0],
            "column_cosine": [0.0, -1.0, 0.0],
        }
        for k in range(shape[2])
    ]
    mapping = {int(label["index"]): label for label in golden["labels"]}

    with tempfile.TemporaryDirectory() as tmp_dir:
        manifest_path = generate_projected_volumetric_roi_manifest(
            segmentation_img=segmentation_img,
            mapping=mapping,
            planes=planes,
            output_dir=Path(tmp_dir),
            source_segmentation_path="/synthetic/golden_segmentation.nii.gz",
            job_metadata={
                "job_uuid": "golden-geometry-v1",
                "source_identity_hash": "synthetic-source-hash",
                "roi_provenance_comment": "TotalSegmentator job golden-geometry-v1",
                "source_identity": {
                    "study_instance_uid": "1.2.826.0.1.3680043.10.1000.1",
                    "series_instance_uid": "1.2.826.0.1.3680043.10.1000.2",
                    "frame_of_reference_uid": "1.2.826.0.1.3680043.10.1000.3",
                    "ordered_sop_instance_uids": [plane["sop_instance_uid"] for plane in planes],
                },
            },
        )

        assert manifest_path is not None
        with Path(manifest_path).open("r", encoding="utf-8") as handle:
            manifest = json.load(handle)

        reconstructed = np.zeros_like(data)
        for label in manifest["labels"]:
            label_index = int(label["index"])
            for slice_record in label["slices"]:
                raw = np.fromfile(slice_record["raw_path"], dtype=np.uint8).reshape(
                    (slice_record["rows"], slice_record["columns"])
                )
                k = int(slice_record["slice_index"])
                reconstructed[:, :, k][raw.T > 0] = label_index

        assert reconstructed.tolist() == data.tolist()
        assert manifest["source_identity"]["ordered_sop_instance_uids"] == [
            plane["sop_instance_uid"] for plane in planes
        ]
        assert manifest["roi_slice_count"] == sum(
            1 for label in manifest["labels"] for _slice in label["slices"]
        )
