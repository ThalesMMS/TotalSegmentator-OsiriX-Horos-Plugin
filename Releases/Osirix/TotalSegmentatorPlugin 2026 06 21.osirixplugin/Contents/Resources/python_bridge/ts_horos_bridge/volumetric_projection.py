import argparse
import json
import sys
from pathlib import Path

PACKAGE_PARENT = Path(__file__).resolve().parents[1]
if str(PACKAGE_PARENT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_PARENT))

from ts_horos_bridge.schemas import atomic_write_json, error_result, success_result, validate_request_schema

nib = None
np = None


def load_image_dependencies():
    """
    Load and make available the nibabel and numpy libraries required for image operations.

    Sets global variables nib and np for use by other functions in this module. Loading is cached to avoid redundant imports.
    """
    global nib, np
    if nib is None or np is None:
        import nibabel as _nib
        import numpy as _np

        nib = _nib
        np = _np


def load_volumetric_roi_manifest(manifest_path):
    """
    Load a volumetric ROI manifest from a JSON file.

    Returns:
        dict: The parsed manifest object.
    """
    with open(manifest_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def segmentation_data_as_uint16(segmentation_img):
    """
    Extract segmentation voxel data as a 3D uint16 volume.

    Extracts voxel data from the nibabel image object and converts it to uint16 format, validating that the result is a 3D volume.

    Returns:
        A 3D numpy array of uint16 values.

    Raises:
        RuntimeError: If the segmentation data is not a 3D volume.
    """
    load_image_dependencies()
    data = np.asanyarray(segmentation_img.dataobj)
    if data.ndim > 3:
        data = np.squeeze(data)
    if data.ndim != 3:
        raise RuntimeError("The segmentation image must be a 3D volume.")
    return np.rint(data).astype(np.uint16)


def sanitize_path_component(value):
    """
    Sanitize a value for use as a path component.

    Allows only alphanumeric characters, underscores, periods, and hyphens.
    Replaces other characters with underscores and strips leading/trailing
    dots and underscores. Returns "roi" if the result is empty.

    Parameters:
        value: The value to sanitize. If None, treated as an empty string.

    Returns:
        str: Sanitized string safe for use in filesystem paths.
    """
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    text = str(value) if value is not None else ""
    cleaned = "".join(ch if ch in allowed else "_" for ch in text).strip("._")
    return cleaned or "roi"


def vector_from_plane(plane, key):
    """
    Extract a 3-element vector from plane configuration.

    Reads the specified field from the plane dict, converts it to a numpy float64 array, and validates that it contains exactly 3 values.

    Parameters:
    	plane: A dict-like object containing viewer geometry configuration.
    	key: The name of the field to extract from the plane.

    Returns:
    	A numpy array of float64 values containing 3 elements.

    Raises:
    	RuntimeError: If the extracted field does not contain exactly 3 values.
    """
    load_image_dependencies()
    vector = np.array(plane[key], dtype=np.float64)
    if vector.size != 3:
        raise RuntimeError("Viewer geometry field '{}' must contain 3 values.".format(key))
    return vector


def sample_plane_labels(data, inverse_affine, plane):
    """
    Sample segmentation labels from a 3D volume onto a 2D viewing plane.

    Parameters:
        plane: Dictionary containing viewing plane geometry with required keys: rows,
            columns, image_position, row_cosine, column_cosine. Optional keys:
            row_spacing, column_spacing (default 1.0).

    Returns:
        2D numpy array of uint16 containing sampled segmentation labels. Out-of-bounds
        positions are filled with zero.
    """
    load_image_dependencies()
    rows = int(plane["rows"])
    columns = int(plane["columns"])
    if rows <= 0 or columns <= 0:
        raise RuntimeError("Viewer geometry rows and columns must be positive.")

    row_spacing = float(plane.get("row_spacing", 1.0))
    column_spacing = float(plane.get("column_spacing", 1.0))
    image_position = vector_from_plane(plane, "image_position")
    row_cosine = vector_from_plane(plane, "row_cosine")
    column_cosine = vector_from_plane(plane, "column_cosine")

    row_indices = np.arange(rows, dtype=np.float64)
    column_indices = np.arange(columns, dtype=np.float64)
    column_grid, row_grid = np.meshgrid(column_indices, row_indices)

    row_offsets = row_grid * row_spacing
    column_offsets = column_grid * column_spacing
    lps_x = image_position[0] + row_cosine[0] * column_offsets + column_cosine[0] * row_offsets
    lps_y = image_position[1] + row_cosine[1] * column_offsets + column_cosine[1] * row_offsets
    lps_z = image_position[2] + row_cosine[2] * column_offsets + column_cosine[2] * row_offsets

    ras_x = -lps_x
    ras_y = -lps_y
    ras_z = lps_z

    voxel_i = inverse_affine[0, 0] * ras_x + inverse_affine[0, 1] * ras_y + inverse_affine[0, 2] * ras_z + inverse_affine[0, 3]
    voxel_j = inverse_affine[1, 0] * ras_x + inverse_affine[1, 1] * ras_y + inverse_affine[1, 2] * ras_z + inverse_affine[1, 3]
    voxel_k = inverse_affine[2, 0] * ras_x + inverse_affine[2, 1] * ras_y + inverse_affine[2, 2] * ras_z + inverse_affine[2, 3]

    index_i = np.rint(voxel_i).astype(np.int64)
    index_j = np.rint(voxel_j).astype(np.int64)
    index_k = np.rint(voxel_k).astype(np.int64)

    valid = (
        (index_i >= 0) & (index_i < data.shape[0]) &
        (index_j >= 0) & (index_j < data.shape[1]) &
        (index_k >= 0) & (index_k < data.shape[2])
    )

    sampled = np.zeros((rows, columns), dtype=np.uint16)
    sampled[valid] = data[index_i[valid], index_j[valid], index_k[valid]]
    return sampled


def generate_projected_volumetric_roi_manifest(
    segmentation_img,
    mapping,
    planes,
    output_dir,
    source_segmentation_path=None,
    reference_dicom_dir=None,
    job_metadata=None,
):
    """
    Project a 3D segmentation volume's labels onto viewer-geometry planes and generate a manifest.

    Creates per-label per-slice raw mask files in the output directory and writes a manifest.json
    describing the projected ROIs.

    Parameters:
        segmentation_img: A nibabel image containing segmentation label data with affine matrix.
        mapping: Dictionary mapping label indices to either label names (strings) or metadata dicts.
        planes: List of plane definitions describing viewer geometry. Must contain at least one plane.
        output_dir: Root directory where output label subdirectories and manifest.json are written.
        source_segmentation_path: Optional path to the source segmentation file for provenance.
        reference_dicom_dir: Optional path to reference DICOM directory for provenance.
        job_metadata: Optional dict with provenance metadata (e.g., job_uuid, source_identity).

    Returns:
        str: Path to the generated manifest.json file, or None if no labels with slices are produced.
    """
    load_image_dependencies()
    if not planes:
        raise RuntimeError("At least one viewer geometry plane is required.")

    data = segmentation_data_as_uint16(segmentation_img)
    inverse_affine = np.linalg.inv(segmentation_img.affine)
    roi_root = Path(output_dir)
    roi_root.mkdir(parents=True, exist_ok=True)
    job_metadata = job_metadata or {}
    source_identity = job_metadata.get("source_identity") or {}

    label_records = {}
    for raw_label_index in sorted(mapping.keys(), key=lambda value: int(value)):
        label_index = int(raw_label_index)
        label_value = mapping[raw_label_index]
        if isinstance(label_value, dict):
            source_record = dict(label_value)
            label_name = str(source_record.get("name") or source_record.get("display_name") or source_record.get("backend_name") or label_index)
            backend_name = str(source_record.get("backend_name") or label_name)
            safe_name = sanitize_path_component(label_name)
        else:
            source_record = {}
            label_name = str(label_value)
            backend_name = label_name
            safe_name = sanitize_path_component(label_name)
        label_records[label_index] = {
            "index": label_index,
            "name": label_name,
            "backend_name": backend_name,
            "safe_name": safe_name,
            "canonical_key": source_record.get("canonical_key"),
            "stable_label_id": source_record.get("stable_label_id"),
            "display_name": source_record.get("display_name") or label_name,
            "display_color": source_record.get("display_color"),
            "aliases": list(source_record.get("aliases") or [backend_name]),
            "laterality": source_record.get("laterality"),
            "anatomic_region": source_record.get("anatomic_region"),
            "coded_concepts": source_record.get("coded_concepts") or {},
            "terminology_source": source_record.get("terminology_source"),
            "slices": [],
            "voxel_count": 0,
        }
        if source_record.get("missing_mapping"):
            label_records[label_index]["missing_mapping"] = True
            label_records[label_index]["diagnostic"] = source_record.get("diagnostic")

    rows = int(planes[0]["rows"])
    columns = int(planes[0]["columns"])

    for slice_index, plane in enumerate(planes):
        sampled = sample_plane_labels(data, inverse_affine, plane)
        present_labels = [
            int(value)
            for value in np.unique(sampled)
            if int(value) in label_records and int(value) != 0
        ]

        for label_index in present_labels:
            mask = sampled == label_index
            voxel_count = int(mask.sum())
            if voxel_count == 0:
                continue

            record = label_records[label_index]
            label_dir = roi_root / "{:03d}_{}".format(label_index, record["safe_name"])
            label_dir.mkdir(parents=True, exist_ok=True)
            uid = str(plane.get("sop_instance_uid") or plane.get("identifier") or slice_index)
            uid_safe = sanitize_path_component(uid)
            raw_path = label_dir / "slice_{:04d}_{}.raw".format(slice_index, uid_safe)
            (mask.astype(np.uint8) * 255).tofile(str(raw_path))

            record["voxel_count"] += voxel_count
            record["slices"].append({
                "slice_index": int(plane.get("slice_index", slice_index)),
                "sop_instance_uid": uid,
                "raw_path": str(raw_path),
                "rows": int(plane["rows"]),
                "columns": int(plane["columns"]),
                "voxel_count": voxel_count,
            })

    labels = [record for record in label_records.values() if record["slices"]]
    if not labels:
        return None

    manifest = {
        "version": 1,
        "format": "horos_tplain_roi_manifest",
        "viewer_geometry_projection": True,
        "rows": rows,
        "columns": columns,
        "reference_dicom_dir": str(reference_dicom_dir or ""),
        "source_segmentation_path": str(source_segmentation_path or ""),
        "job_uuid": str(job_metadata.get("job_uuid") or ""),
        "source_identity_hash": str(job_metadata.get("source_identity_hash") or ""),
        "roi_provenance_comment": str(job_metadata.get("roi_provenance_comment") or ""),
        "source_identity": {
            "study_instance_uid": source_identity.get("study_instance_uid"),
            "series_instance_uid": source_identity.get("series_instance_uid"),
            "frame_of_reference_uid": source_identity.get("frame_of_reference_uid"),
            "ordered_sop_instance_uids": list(source_identity.get("ordered_sop_instance_uids") or []),
        },
        "label_count": len(labels),
        "roi_slice_count": int(sum(len(record["slices"]) for record in labels)),
        "labels": labels,
    }

    manifest_path = roi_root / "manifest.json"
    atomic_write_json(manifest_path, manifest)

    return str(manifest_path)


def main():
    """
    Project volumetric ROI labels from a segmentation image onto viewer-geometry planes and write the resulting manifest.

    Loads a JSON configuration file, extracts the source segmentation image path and label mappings from a volumetric ROI manifest, projects the labeled voxels onto each viewer-geometry plane, and writes the resulting manifest as JSON.

    Raises:
        RuntimeError: If the source segmentation file is missing, the manifest contains no labels, or the projection yields no ROIs.

    Returns:
        int: Exit status 0.
    """
    parser = argparse.ArgumentParser(description="Project TotalSegmentator volumetric ROIs onto viewer geometry")
    parser.add_argument("--config", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    result_path = Path(args.result).expanduser()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)
    validate_request_schema(config)

    original_manifest = load_volumetric_roi_manifest(config["manifest_path"])
    source_path = original_manifest.get("source_segmentation_path")
    if not source_path:
        raise RuntimeError("The volumetric ROI manifest does not contain source_segmentation_path.")
    if not Path(source_path).exists():
        raise RuntimeError("The source segmentation volume is missing: {}".format(source_path))

    labels = original_manifest.get("labels", [])
    mapping = {int(label["index"]): dict(label) for label in labels if "index" in label and "name" in label}
    if not mapping:
        raise RuntimeError("The volumetric ROI manifest does not contain labels.")

    output_dir = Path(config["output_dir"]).expanduser()
    planes = config.get("planes", [])
    job_metadata = {
        "job_uuid": original_manifest.get("job_uuid", ""),
        "source_identity_hash": original_manifest.get("source_identity_hash", ""),
        "roi_provenance_comment": original_manifest.get("roi_provenance_comment", ""),
        "source_identity": original_manifest.get("source_identity", {}),
    }
    load_image_dependencies()
    segmentation_img = nib.load(source_path)
    projected_manifest = generate_projected_volumetric_roi_manifest(
        segmentation_img=segmentation_img,
        mapping=mapping,
        planes=planes,
        output_dir=output_dir,
        source_segmentation_path=source_path,
        reference_dicom_dir=original_manifest.get("reference_dicom_dir", ""),
        job_metadata=job_metadata,
    )
    if not projected_manifest:
        raise RuntimeError("No projected volumetric ROIs were generated for the current viewer geometry.")

    atomic_write_json(
        result_path,
        success_result("volumetric_projection", manifest_path=projected_manifest),
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("[TotalSegmentatorVolumetricProjection] {}".format(exc), file=sys.stderr, flush=True)
        result_path = None
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--result")
        try:
            parsed, _ = parser.parse_known_args()
            if parsed.result:
                result_path = Path(parsed.result).expanduser()
        except Exception:
            result_path = None
        if result_path is not None:
            atomic_write_json(
                result_path,
                error_result("volumetric_projection", "volumetric_projection_failed", str(exc)),
            )
        sys.exit(1)
