import argparse
import json
import sys
from pathlib import Path

PACKAGE_PARENT = Path(__file__).resolve().parents[1]
if str(PACKAGE_PARENT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_PARENT))

from ts_horos_bridge.schemas import atomic_write_json, error_result, success_result, validate_request_schema
from ts_horos_bridge.terminology import label_map_record, load_terminology_resource, resolve_label_metadata

try:
    import pydicom
except Exception:
    pydicom = None

nib = None
np = None


def load_image_dependencies():
    """
    Lazily load nibabel and numpy as module globals if not already loaded.
    """
    global nib, np
    if nib is None or np is None:
        import nibabel as _nib
        import numpy as _np

        nib = _nib
        np = _np


def log(message):
    """
    Write a message to standard error.
    """
    print(message, file=sys.stderr, flush=True)


def load_rtstruct_writer():
    """
    Import and return the RTSTRUCT writer from TotalSegmentator.

    Returns:
        callable: The save_mask_as_rtstruct function from totalsegmentator.dicom_io.
    """
    from totalsegmentator.dicom_io import save_mask_as_rtstruct

    return save_mask_as_rtstruct


def normalize_rtstruct_mode(value):
    """
    Normalize and validate an RTSTRUCT generation mode value.

    Converts input to string, lowercases, strips whitespace, and replaces underscores with hyphens. Maps common aliases (off/false/none to disabled, on/true to optional) and validates against the set of allowed modes.

    Parameters:
        value: The mode value to normalize. Can be a string, None, or any value convertible to string.

    Returns:
        str: One of 'disabled', 'optional', or 'required'. Returns 'disabled' if the normalized value is not one of the three valid modes.
    """
    normalized = str(value or "disabled").strip().lower().replace("_", "-")
    aliases = {
        "off": "disabled",
        "false": "disabled",
        "none": "disabled",
        "on": "optional",
        "true": "optional",
    }
    normalized = aliases.get(normalized, normalized)
    if normalized not in {"disabled", "optional", "required"}:
        return "disabled"
    return normalized


def generate_rtstruct_artifact(
    rtstruct_mode,
    segmentation_img,
    mapping,
    label_metadata,
    task_name,
    reference_dir,
    rtstruct_path,
    volumetric_roi_manifest_path,
):
    """
    Generate an RTSTRUCT DICOM artifact from a segmentation image.

    If rtstruct_mode is "disabled", returns immediately with empty paths. Otherwise, attempts generation.
    On success, returns the generated file path. On failure, behavior depends on mode: if "required",
    raises RuntimeError; if "optional" and volumetric_roi_manifest_path is provided, logs the error and
    continues with empty paths; otherwise re-raises the exception.

    Parameters:
        label_metadata: Per-label metadata for artifact generation.
        volumetric_roi_manifest_path: If provided, enables graceful failure in optional mode.

    Returns:
        Tuple of (paths, status, error) where paths is a list of generated file paths (empty if disabled
        or optional failure), status is "disabled", "succeeded", or "failed", and error is the exception
        message or None.
    """
    rtstruct_mode = normalize_rtstruct_mode(rtstruct_mode)
    if rtstruct_mode == "disabled":
        if not volumetric_roi_manifest_path:
            return [], "failed", "No importable volumetric ROI manifest was generated and RT Struct generation is disabled."
        return [], "disabled", None

    try:
        save_mask_as_rtstruct = load_rtstruct_writer()
        rtstruct_mapping = {
            index: metadata_for_label(index, name, task_name=task_name, metadata=label_metadata)
            for index, name in mapping.items()
        }
        save_mask_as_rtstruct(segmentation_img, rtstruct_mapping, str(reference_dir), str(rtstruct_path))
        return [str(rtstruct_path)], "succeeded", None
    except Exception as exc:
        message = str(exc)
        if rtstruct_mode == "required":
            raise RuntimeError("Required RT Struct generation failed: {}".format(message)) from exc

        if volumetric_roi_manifest_path:
            log(
                "[TotalSegmentatorNiftiConversion] Optional RT Struct generation failed; "
                "continuing with volumetric ROI manifest: {}".format(message)
            )
            return [], "failed", message

        raise


def normalize_name(value):
    """
    Normalize a name by converting to lowercase, trimming whitespace, and replacing spaces with underscores.

    Parameters:
        value (str): The name to normalize

    Returns:
        str: The normalized name
    """
    return value.strip().lower().replace(" ", "_")


def sanitize_path_component(value):
    """
    Sanitize a string for use as a file or directory path component.

    Parameters:
        value: The string to sanitize.

    Returns:
        str: The sanitized path component, or "roi" if empty.
    """
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    text = str(value) if value is not None else ""
    cleaned = "".join(ch if ch in allowed else "_" for ch in text).strip("._")
    return cleaned or "roi"


def strip_extension(path):
    """
    Remove `.nii.gz` or `.nii` extension from a filename.

    Returns:
        str: The filename without `.nii.gz` or `.nii` extension.
    """
    name = path.name
    if name.lower().endswith(".nii.gz"):
        return name[:-7]
    if name.lower().endswith(".nii"):
        return name[:-4]
    return name


def load_normalized_label_records(base):
    """
    Load label mappings and metadata from a label-map.json file.

    Parameters:
        base (Path): Directory containing the label-map.json file.

    Returns:
        tuple: A tuple of (mapping, metadata). mapping is a dict from label index
            to label name; metadata is a dict from label index to the full label record.

    Raises:
        RuntimeError: If label-map.json is not found or contains no valid labels.
    """
    label_map_path = base / "label-map.json"
    if not label_map_path.exists():
        raise RuntimeError("Canonical label-map.json was not found.")
    with open(label_map_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    labels = payload.get("labels", [])
    mapping = {}
    metadata = {}
    for record in labels:
        try:
            index = int(record["index"])
            name = str(record["name"])
        except Exception:
            continue
        mapping[index] = name
        metadata[index] = dict(record)
    if not mapping:
        raise RuntimeError("Canonical label-map.json does not contain labels.")
    return mapping, metadata


def load_normalized_label_map(base):
    """
    Load the label index to name mapping from the label map file.

    Parameters:
        base (Path or str): Directory containing label-map.json.

    Returns:
        dict: Mapping of label indices (int) to label names (str).
    """
    mapping, _ = load_normalized_label_records(base)
    return mapping


def gather_binary_masks(base):
    """
    Gather NIfTI mask files from a directory and its segmentations subdirectory.

    Searches for candidate NIfTI files (`.nii` and `.nii.gz`) in `base/segmentations/` (if it exists)
    and in `base/` itself. Filters out duplicates and applies naming conventions to exclude certain files.
    Specifically skips files that contain "image" in the filename but do not contain "seg".

    Parameters:
        base (Path): Directory to search for NIfTI files.

    Returns:
        list[Path]: List of paths to NIfTI files matching the criteria, sorted.
    """
    mask_dir = base / "segmentations"
    candidates = []
    if mask_dir.is_dir():
        candidates.extend(sorted(mask_dir.glob("*.nii")))
        candidates.extend(sorted(mask_dir.glob("*.nii.gz")))
    candidates.extend(sorted(base.glob("*.nii")))
    candidates.extend(sorted(base.glob("*.nii.gz")))

    masks = []
    seen = set()
    for path in candidates:
        name = path.name.lower()
        if path in seen:
            continue
        if name in {"segmentations.nii", "segmentations.nii.gz"} and path.parent == base:
            continue
        if name.endswith(".nii") or name.endswith(".nii.gz"):
            if "image" in name and "seg" not in name:
                continue
            masks.append(path)
            seen.add(path)
    return masks


def build_multilabel_from_masks(paths, task_name=None):
    """
    Combine binary segmentation masks into a single multilabel NIfTI image.

    Parameters:
        paths (list): Paths to binary mask NIfTI files to combine.
        task_name (str, optional): Task identifier for label metadata. Defaults to "total".

    Returns:
        tuple: A tuple of (nifti_image, mapping, metadata) where nifti_image is the combined multilabel segmentation, mapping is a dictionary of label indices to names, and metadata contains label metadata records. Returns None if paths is empty or no input masks contain nonzero voxels.
    """
    load_image_dependencies()
    if not paths:
        return None
    terminology_resource = load_terminology_resource()
    first_img = nib.load(str(paths[0]))
    data = np.zeros(first_img.shape, dtype=np.uint16)
    mapping = {}
    metadata = {}
    index = 1
    for path in paths:
        img = nib.load(str(path))
        arr = np.asanyarray(img.dataobj)
        if np.any(arr):
            backend_name = strip_extension(path)
            mapping[index] = backend_name
            metadata[index] = label_map_record(
                index,
                backend_name,
                task_name or "total",
                {index},
                resource=terminology_resource,
            )
            data[arr > 0.5] = index
            index += 1
    if not mapping:
        return None
    new_header = first_img.header.copy()
    new_header.set_data_dtype(np.uint16)
    nifti_img = nib.Nifti1Image(data.astype(np.uint16), first_img.affine, new_header)
    return nifti_img, mapping, metadata


def load_segmentation(base, task_name, allow_binary_mask_compatibility=False):
    """
    Load a segmentation with its label mappings, optionally from binary masks.

    Attempts to load segmentation.nii.gz from the specified directory and validates
    that all non-zero labels in the segmentation are defined in label-map.json. If
    the canonical segmentation is not found and binary mask compatibility is enabled,
    attempts to build the segmentation from binary mask files instead.

    Parameters:
        base (Path): Directory containing segmentation files and label-map.json
        task_name (str): Task name, passed when building segmentation from binary masks
        allow_binary_mask_compatibility (bool): If True, fall back to building
            segmentation from binary masks when canonical segmentation is absent

    Returns:
        tuple: (segmentation_image, label_mapping, metadata) where segmentation_image
            is a nibabel Nifti1Image with uint16 data, label_mapping maps label indices
            to names, and metadata contains label metadata records

    Raises:
        RuntimeError: If canonical segmentation contains undefined labels, or if no
            valid segmentation source is available
    """
    load_image_dependencies()
    canonical_path = base / "segmentation.nii.gz"
    if canonical_path.exists():
        img = nib.load(str(canonical_path))
        data = segmentation_data_as_uint16(img)
        mapping, metadata = load_normalized_label_records(base)
        present_labels = [int(v) for v in np.unique(data) if int(v) != 0]
        missing = [value for value in present_labels if value not in mapping]
        if missing:
            raise RuntimeError("Canonical segmentation contains labels missing from label-map.json: {}".format(missing))
        header = img.header.copy()
        header.set_data_dtype(np.uint16)
        nifti_img = nib.Nifti1Image(data.astype(np.uint16), img.affine, header)
        return nifti_img, mapping, metadata

    if allow_binary_mask_compatibility:
        compatibility_masks = gather_binary_masks(base)
        mask_result = build_multilabel_from_masks(compatibility_masks, task_name=task_name)
        if mask_result:
            return mask_result

    raise RuntimeError("Canonical segmentation.nii.gz was not found for conversion.")


def filter_selection(segmentation_img, mapping, selected, metadata=None):
    """
    Filter a segmentation image to keep only selected labels.

    Labels are matched by name or alias from the provided metadata. If no labels
    match the selection, the original image and mappings are returned.

    Parameters:
        selected: Set of normalized label names or aliases to retain.

    Returns:
        A tuple of (filtered_img, new_mapping, new_metadata) containing the
        filtered segmentation image, the updated label index-to-name mapping,
        and the updated label metadata.
    """
    load_image_dependencies()
    if not selected:
        return segmentation_img, mapping, metadata or {}

    metadata = metadata or {}
    selected_indices = []
    for idx, name in mapping.items():
        record = metadata.get(int(idx), {})
        aliases = set(record.get("aliases") or [])
        aliases.add(name)
        if any(normalize_name(alias) in selected for alias in aliases):
            selected_indices.append(idx)
    if not selected_indices:
        raise RuntimeError("Selected class names did not match any segmentation labels.")

    selected_indices.sort()
    data = segmentation_data_as_uint16(segmentation_img)
    new_data = np.zeros_like(data, dtype=np.uint16)
    new_mapping = {}
    new_metadata = {}
    for idx in selected_indices:
        new_data[data == idx] = idx
        new_mapping[idx] = mapping[idx]
        if int(idx) in metadata:
            new_metadata[int(idx)] = metadata[int(idx)]

    header = segmentation_img.header.copy()
    header.set_data_dtype(np.uint16)
    filtered_img = nib.Nifti1Image(new_data.astype(np.uint16), segmentation_img.affine, header)
    return filtered_img, new_mapping, new_metadata


def save_source_segmentation(segmentation_img, output_dir):
    """
    Saves a segmentation NIfTI image to the volumetric ROIs output directory.

    Parameters:
        segmentation_img: A nibabel Nifti1Image object.
        output_dir (Path): The root output directory.

    Returns:
        Path: The path to the saved source_segmentation.nii.gz file.
    """
    load_image_dependencies()
    roi_root = output_dir / "volumetric_rois"
    roi_root.mkdir(parents=True, exist_ok=True)
    source_path = roi_root / "source_segmentation.nii.gz"
    nib.save(segmentation_img, str(source_path))
    return source_path


def load_reference_slices(reference_dir):
    """
    Load DICOM slices and their geometric information from a directory.

    Recursively scans the reference directory for DICOM files, extracts geometry
    metadata (dimensions, spacing, orientation, position), and validates that all
    slices have uniform image dimensions. Returns slices sorted by anatomical position.

    Parameters:
        reference_dir (Path): Directory to recursively search for DICOM files.

    Returns:
        list: Ordered list of slice dictionaries, each containing DICOM geometry fields
        including path, dimensions, spacing, orientation vectors, position, and metadata.

    Raises:
        RuntimeError: If no valid DICOM slices with geometry are found, or if the
        reference series has non-uniform image dimensions.
    """
    load_image_dependencies()
    if pydicom is None:
        raise RuntimeError("pydicom is required to generate volumetric Horos ROIs.")

    slices = []
    for path in sorted(reference_dir.rglob("*")):
        if not path.is_file():
            continue
        try:
            ds = pydicom.dcmread(str(path), stop_before_pixels=True, force=True)
        except Exception:
            continue

        try:
            rows = int(ds.Rows)
            columns = int(ds.Columns)
            pixel_spacing = [float(value) for value in ds.PixelSpacing]
            image_orientation = np.array([float(value) for value in ds.ImageOrientationPatient], dtype=np.float64)
            image_position = np.array([float(value) for value in ds.ImagePositionPatient], dtype=np.float64)
        except Exception:
            continue

        if image_orientation.size != 6 or len(pixel_spacing) != 2:
            continue

        row_cosine = image_orientation[:3]
        column_cosine = image_orientation[3:]
        normal = np.cross(row_cosine, column_cosine)
        norm = np.linalg.norm(normal)
        if norm == 0:
            continue
        normal = normal / norm

        instance_number = getattr(ds, "InstanceNumber", None)
        try:
            instance_number = int(instance_number)
        except Exception:
            instance_number = 0

        slices.append({
            "path": str(path),
            "rows": rows,
            "columns": columns,
            "row_spacing": float(pixel_spacing[0]),
            "column_spacing": float(pixel_spacing[1]),
            "row_cosine": row_cosine,
            "column_cosine": column_cosine,
            "normal": normal,
            "image_position": image_position,
            "slice_position": float(np.dot(image_position, normal)),
            "sop_instance_uid": str(getattr(ds, "SOPInstanceUID", "")),
            "instance_number": instance_number,
        })

    if not slices:
        raise RuntimeError("No reference DICOM slices with geometry were found for volumetric ROI generation.")

    slices.sort(key=lambda item: (item["slice_position"], item["instance_number"], item["path"]))
    first = slices[0]
    for item in slices:
        if item["rows"] != first["rows"] or item["columns"] != first["columns"]:
            raise RuntimeError("The reference DICOM series has non-uniform image dimensions.")

    return slices


def segmentation_data_as_uint16(segmentation_img):
    """
    Extract 3D segmentation data from a NIfTI image as a uint16 array.

    Returns:
        A 3D numpy array of uint16 dtype containing the segmentation data
    """
    load_image_dependencies()
    data = np.asanyarray(segmentation_img.dataobj)
    if data.ndim > 3:
        data = np.squeeze(data)
    if data.ndim != 3:
        raise RuntimeError("The segmentation NIfTI is not a 3D volume.")
    if not np.all(np.isfinite(data)):
        raise RuntimeError("The segmentation NIfTI contains non-finite label values.")
    if np.any(data < 0):
        raise RuntimeError("The segmentation NIfTI contains negative label values.")
    rounded = np.rint(data)
    if not np.all(data == rounded):
        raise RuntimeError("The segmentation NIfTI contains non-integer label values.")
    if rounded.size and np.max(rounded) > np.iinfo(np.uint16).max:
        raise RuntimeError("The segmentation NIfTI contains label values outside the uint16 range.")
    return rounded.astype(np.uint16)


def sample_slice_labels(data, inverse_affine, reference_slice):
    """
    Extract a 2D label image from a 3D segmentation volume using DICOM slice geometry.

    Parameters:
        inverse_affine: 4x4 inverse affine matrix from world coordinates to voxel indices
        reference_slice: Dictionary containing DICOM slice geometry including image dimensions, position, orientation cosines, and pixel spacing

    Returns:
        2D numpy array (uint16) of shape (rows, columns) containing the sampled label values
    """
    load_image_dependencies()
    rows = reference_slice["rows"]
    columns = reference_slice["columns"]
    row_indices = np.arange(rows, dtype=np.float64)
    column_indices = np.arange(columns, dtype=np.float64)
    column_grid, row_grid = np.meshgrid(column_indices, row_indices)

    image_position = reference_slice["image_position"]
    row_cosine = reference_slice["row_cosine"]
    column_cosine = reference_slice["column_cosine"]
    row_offsets = row_grid * reference_slice["row_spacing"]
    column_offsets = column_grid * reference_slice["column_spacing"]

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


def metadata_for_label(label_index, label_name, task_name=None, metadata=None):
    """
    Retrieve or resolve metadata for a label.

    Uses existing metadata from the provided dictionary if available; otherwise resolves metadata based on the label index, name, and task.

    Parameters:
        task_name (str, optional): Task name for metadata resolution. Defaults to "total".
        metadata (dict, optional): Existing label metadata indexed by label index.

    Returns:
        dict: The metadata record for the label.
    """
    metadata = metadata or {}
    record = dict(metadata.get(int(label_index)) or {})
    if not record:
        record = resolve_label_metadata(task_name or "total", int(label_index), label_name)
    return record


def roi_manifest_label_record(label_index, label_name, task_name=None, metadata=None):
    """
    Constructs a label record for the volumetric ROI manifest with resolved terminology metadata.

    Returns:
        A dictionary containing the label's index, display names, resolved metadata, terminology fields, and initialized slice and voxel tracking fields.
    """
    record = metadata_for_label(label_index, label_name, task_name=task_name, metadata=metadata)
    display_name = str(record.get("display_name") or label_name)
    output = {
        "index": int(label_index),
        "name": display_name,
        "backend_name": str(record.get("backend_name") or label_name),
        "safe_name": sanitize_path_component(display_name),
        "canonical_key": record.get("canonical_key"),
        "stable_label_id": record.get("stable_label_id"),
        "display_name": display_name,
        "display_color": record.get("display_color"),
        "aliases": list(record.get("aliases") or [label_name]),
        "laterality": record.get("laterality"),
        "anatomic_region": record.get("anatomic_region"),
        "coded_concepts": record.get("coded_concepts") or {},
        "terminology_source": record.get("terminology_source"),
        "slices": [],
        "voxel_count": 0,
    }
    if record.get("missing_mapping"):
        output["missing_mapping"] = True
        output["diagnostic"] = record.get("diagnostic")
    return output


def generate_volumetric_roi_manifest(segmentation_img, mapping, reference_dir, output_dir, source_segmentation_path=None, job_metadata=None, label_metadata=None, task_name=None):
    """
    Generate a manifest file describing volumetric ROIs sampled from a segmentation onto DICOM reference slices.

    Samples each label in the segmentation onto the 2D geometry of reference DICOM slices, writes per-label and per-slice raw mask files, and produces a manifest JSON containing label metadata, voxel counts, and slice provenance.

    Parameters:
        segmentation_img: A nibabel Nifti1Image with segmentation label data.
        mapping: Dictionary mapping label indices (int) to label names (str).
        reference_dir: Directory containing DICOM reference files.
        output_dir: Directory where volumetric_rois subdirectory and manifest will be created.
        source_segmentation_path: Optional path to the source segmentation file to include in manifest.
        job_metadata: Optional dictionary with job UUID, identity hash, provenance comment, and source identity info.
        label_metadata: Optional dictionary with per-label metadata records.
        task_name: Optional task name for label record resolution.

    Returns:
        Path to the generated manifest.json file (as a string), or None if no labels have slices.
    """
    load_image_dependencies()
    reference_slices = load_reference_slices(reference_dir)
    data = segmentation_data_as_uint16(segmentation_img)
    inverse_affine = np.linalg.inv(segmentation_img.affine)
    job_metadata = job_metadata or {}
    source_identity = job_metadata.get("source_identity") or {}

    rows = reference_slices[0]["rows"]
    columns = reference_slices[0]["columns"]
    roi_root = output_dir / "volumetric_rois"
    roi_root.mkdir(parents=True, exist_ok=True)

    label_records = {}
    for label_index in sorted(mapping.keys()):
        label_name = str(mapping[label_index])
        label_records[int(label_index)] = roi_manifest_label_record(
            label_index,
            label_name,
            task_name=task_name,
            metadata=label_metadata,
        )

    for slice_index, reference_slice in enumerate(reference_slices):
        sampled = sample_slice_labels(data, inverse_affine, reference_slice)
        present_labels = [int(value) for value in np.unique(sampled) if int(value) in label_records and int(value) != 0]

        for label_index in present_labels:
            mask = sampled == label_index
            voxel_count = int(mask.sum())
            if voxel_count == 0:
                continue

            record = label_records[label_index]
            label_dir = roi_root / "{:03d}_{}".format(label_index, record["safe_name"])
            label_dir.mkdir(parents=True, exist_ok=True)
            uid_safe = sanitize_path_component(reference_slice["sop_instance_uid"] or str(slice_index))
            raw_path = label_dir / "slice_{:04d}_{}.raw".format(slice_index, uid_safe)
            (mask.astype(np.uint8) * 255).tofile(str(raw_path))

            record["voxel_count"] += voxel_count
            record["slices"].append({
                "slice_index": int(slice_index),
                "sop_instance_uid": reference_slice["sop_instance_uid"],
                "source_dicom_path": reference_slice["path"],
                "raw_path": str(raw_path),
                "rows": int(rows),
                "columns": int(columns),
                "voxel_count": voxel_count,
            })

    labels = [record for record in label_records.values() if record["slices"]]
    if not labels:
        return None

    manifest = {
        "version": 1,
        "format": "horos_tplain_roi_manifest",
        "rows": int(rows),
        "columns": int(columns),
        "reference_dicom_dir": str(reference_dir),
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
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)

    return str(manifest_path)


def main():
    parser = argparse.ArgumentParser(description="Convert TotalSegmentator NIfTI outputs to DICOM artifacts")
    parser.add_argument("--config", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    result_path = Path(args.result).expanduser()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)
    validate_request_schema(config)

    nifti_dir = Path(config["nifti_dir"]).expanduser()
    reference_dir = Path(config["reference_dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    selected = {normalize_name(name) for name in config.get("selected_classes", []) if isinstance(name, str)}
    task_name = config.get("task")
    allow_binary_mask_compatibility = bool(config.get("allow_binary_mask_compatibility", False))
    job_metadata = config.get("job") or {}

    segmentation_img, mapping, label_metadata = load_segmentation(nifti_dir, task_name, allow_binary_mask_compatibility)
    if not mapping:
        raise RuntimeError("No segmentation labels available for conversion.")

    segmentation_img, mapping, label_metadata = filter_selection(segmentation_img, mapping, selected, label_metadata)
    if not mapping:
        raise RuntimeError("No segmentation labels remain after applying the class filter.")

    source_segmentation_path = save_source_segmentation(segmentation_img, output_dir)

    volumetric_roi_manifest_path = None
    try:
        volumetric_roi_manifest_path = generate_volumetric_roi_manifest(
            segmentation_img,
            mapping,
            reference_dir,
            output_dir,
            source_segmentation_path,
            job_metadata,
            label_metadata,
            task_name,
        )
        if volumetric_roi_manifest_path:
            log("[TotalSegmentatorNiftiConversion] Generated volumetric ROI manifest at {}".format(volumetric_roi_manifest_path))
        else:
            log("[TotalSegmentatorNiftiConversion] No non-empty volumetric ROI masks were generated.")
    except Exception as exc:
        log("[TotalSegmentatorNiftiConversion] Volumetric ROI manifest generation failed: {}".format(exc))

    rtstruct_mode = normalize_rtstruct_mode(config.get("rtstruct_mode", "disabled"))
    rtstruct_name = config.get("rtstruct_name", "segmentations_rtstruct.dcm")
    rtstruct_path = output_dir / rtstruct_name
    rtstruct_paths, rtstruct_status, rtstruct_error = generate_rtstruct_artifact(
        rtstruct_mode=rtstruct_mode,
        segmentation_img=segmentation_img,
        mapping=mapping,
        label_metadata=label_metadata,
        task_name=task_name,
        reference_dir=reference_dir,
        rtstruct_path=rtstruct_path,
        volumetric_roi_manifest_path=volumetric_roi_manifest_path,
    )
    if rtstruct_status == "disabled":
        log("[TotalSegmentatorNiftiConversion] RT Struct generation disabled.")
    elif rtstruct_status == "succeeded":
        log("[TotalSegmentatorNiftiConversion] Generated RT Struct artifact at {}".format(rtstruct_path))

    if volumetric_roi_manifest_path is None and not rtstruct_paths:
        message = "No importable artifact was generated for Horos ROI import."
        if rtstruct_error:
            message = "{} {}".format(message, rtstruct_error)
        atomic_write_json(
            result_path,
            error_result("nifti_conversion", "no_importable_artifacts", message),
        )
        return 2

    atomic_write_json(
        result_path,
        success_result(
            "nifti_conversion",
            rtstruct_paths=rtstruct_paths,
            rtstruct_mode=rtstruct_mode,
            rtstruct_status=rtstruct_status,
            rtstruct_error=rtstruct_error,
            dicom_series_directories=[],
            volumetric_roi_manifest_path=volumetric_roi_manifest_path,
            source_segmentation_path=str(source_segmentation_path),
            job_uuid=str(job_metadata.get("job_uuid") or ""),
            source_identity_hash=str(job_metadata.get("source_identity_hash") or ""),
        ),
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log("[TotalSegmentatorNiftiConversion] {}".format(exc))
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
                error_result("nifti_conversion", "nifti_conversion_failed", str(exc)),
            )
        sys.exit(1)
