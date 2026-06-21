#
# dicom_io.py
# TotalSegmentator
#
# Provides DICOM I/O helpers and conversions to and from NIfTI plus RT Struct export utilities.
#
# Thales Matheus Mendonça Santos - November 2025
#

"""Operacoes de leitura e escrita de DICOM, alem de conversoes para NIfTI."""

import os
import sys
import time
import shutil
import zipfile
import colorsys
import hashlib
import json
from pathlib import Path
import subprocess
import platform

from tqdm import tqdm
import numpy as np
import nibabel as nib
import dicom2nifti

from totalsegmentator.config import get_weights_dir
from nibabel.orientations import (
    axcodes2ornt,
    io_orientation,
    ornt_transform,
    apply_orientation,
)


_RTSTRUCT_COLOR_PALETTE = [
    [230, 25, 75],
    [60, 180, 75],
    [255, 225, 25],
    [67, 99, 216],
    [245, 130, 49],
    [145, 30, 180],
    [70, 240, 240],
    [240, 50, 230],
    [188, 246, 12],
    [250, 190, 212],
    [0, 128, 128],
    [220, 190, 255],
    [154, 99, 36],
    [255, 250, 200],
    [128, 0, 0],
    [170, 255, 195],
    [128, 128, 0],
    [255, 216, 177],
    [0, 0, 117],
    [128, 128, 128],
]


def command_exists(command):
    return shutil.which(command) is not None


def download_dcm2niix():
    import urllib.request
    print("  Downloading dcm2niix...")

    if platform.system() == "Windows":
        # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/dcm2niix_win.zip"
        url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_win.zip"
    elif platform.system() == "Darwin":  # Mac
        # raise ValueError("For MacOS automatic installation of dcm2niix not possible. Install it manually.")
        if platform.machine().startswith("arm") or platform.machine().startswith("aarch"):  # arm
            # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/macos_dcm2niix.pkg"
            url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_macos.zip"
        else:  # intel
            # unclear if this is the right link (is the same as for arm)
            # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/macos_dcm2niix.pkg"
            url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_macos.zip"
    elif platform.system() == "Linux":
        # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/dcm2niix_lnx.zip"
        url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_lnx.zip"
    else:
        raise ValueError("Unknown operating system. Can not download the right version of dcm2niix.")

    config_dir = get_weights_dir()

    urllib.request.urlretrieve(url, config_dir / "dcm2niix.zip")
    with zipfile.ZipFile(config_dir / "dcm2niix.zip", 'r') as zip_ref:
        zip_ref.extractall(config_dir)

    # Give execution permission to the script
    if platform.system() == "Windows":
        os.chmod(config_dir / "dcm2niix.exe", 0o755)
    else:
        os.chmod(config_dir / "dcm2niix", 0o755)

    # Clean up
    if (config_dir / "dcm2niix.zip").exists():
        os.remove(config_dir / "dcm2niix.zip")
    if (config_dir / "dcm2niibatch").exists():
        os.remove(config_dir / "dcm2niibatch")


def dcm_to_nifti_LEGACY(input_path, output_path, verbose=False):
    """
    Uses dcm2niix (does not properly work on windows)

    input_path: a directory of dicom slices
    output_path: a nifti file path
    """
    verbose_str = "" if verbose else "> /dev/null"

    config_dir = get_weights_dir()

    if command_exists("dcm2niix"):
        dcm2niix = "dcm2niix"
    else:
        if platform.system() == "Windows":
            dcm2niix = config_dir / "dcm2niix.exe"
        else:
            dcm2niix = config_dir / "dcm2niix"
        if not dcm2niix.exists():
            download_dcm2niix()

    subprocess.call(f"\"{dcm2niix}\" -o {output_path.parent} -z y -f {output_path.name[:-7]} {input_path} {verbose_str}", shell=True)

    if not output_path.exists():
        print(f"Content of dcm2niix output folder ({output_path.parent}):")
        print(list(output_path.parent.glob("*")))
        raise ValueError("dcm2niix failed to convert dicom to nifti.")

    nii_files = list(output_path.parent.glob("*.nii.gz"))

    if len(nii_files) > 1:
        print("WARNING: Dicom to nifti resulted in several nifti files. Skipping files which contain ROI in filename.")
        for nii_file in nii_files:
            # output file name is "converted_dcm.nii.gz" so if ROI in name, then this can be deleted
            if "ROI" in nii_file.name:
                os.remove(nii_file)
                print(f"Skipped: {nii_file.name}")

    nii_files = list(output_path.parent.glob("*.nii.gz"))

    if len(nii_files) > 1:
        print("WARNING: Dicom to nifti resulted in several nifti files. Only using first one.")
        print([f.name for f in nii_files])
        for nii_file in nii_files[1:]:
            os.remove(nii_file)
        # todo: have to rename first file to not contain any counter which is automatically added by dcm2niix

    os.remove(str(output_path)[:-7] + ".json")


def dcm_to_nifti(input_path, output_path, tmp_dir=None, verbose=False):
    """
    Uses dicom2nifti package (also works on windows)

    input_path: a directory of dicom slices or a zip file of dicom slices or a bytes object of zip file
    output_path: a nifti file path
    tmp_dir: extract zip file to this directory, else to the same directory as the zip file. Needs to be set if input is a zip file.
    """
    # Check if input_path is a zip file and extract it
    if zipfile.is_zipfile(input_path):
        if tmp_dir is None:
            raise ValueError("tmp_dir must be set when input_path is a zip file or bytes object of zip file")
        if verbose: print(f"Extracting zip file: {input_path}")
        extract_dir = os.path.splitext(input_path)[0] if tmp_dir is None else tmp_dir / "extracted_dcm"
        with zipfile.ZipFile(input_path, 'r') as zip_ref:
            zip_ref.extractall(extract_dir)
            input_path = extract_dir

    # Convert to nifti
    dicom2nifti.dicom_series_to_nifti(input_path, output_path, reorient_nifti=True)


def _reorient_to_lps(segmentation_img):
    """Return segmentation data aligned to LPS axis codes."""

    current_ornt = io_orientation(segmentation_img.affine)
    target_ornt = axcodes2ornt(("L", "P", "S"))
    transform = ornt_transform(current_ornt, target_ornt)
    data = segmentation_img.get_fdata()
    if data.ndim != 3:
        raise ValueError("Segmentation image must be 3D to convert to RT Struct.")
    reoriented = apply_orientation(data, transform)
    return np.asarray(reoriented)


def _rtstruct_color_for_label(label_index, label_name):
    if 1 <= label_index <= len(_RTSTRUCT_COLOR_PALETTE):
        return _RTSTRUCT_COLOR_PALETTE[label_index - 1]

    digest = hashlib.sha256(f"{label_index}:{label_name}".encode("utf-8")).digest()
    hue = int.from_bytes(digest[:2], "big") / 65535.0
    saturation = 0.65 + (digest[2] / 255.0) * 0.25
    value = 0.82 + (digest[3] / 255.0) * 0.15
    red, green, blue = colorsys.hsv_to_rgb(hue, saturation, value)
    return [int(round(red * 255)), int(round(green * 255)), int(round(blue * 255))]


def _rtstruct_label_name(label_index, label_value):
    if isinstance(label_value, dict):
        return str(
            label_value.get("display_name")
            or label_value.get("name")
            or label_value.get("backend_name")
            or str(label_index)
        )

    return str(label_value)


def _rtstruct_label_metadata(label_index, label_value):
    label_name = _rtstruct_label_name(label_index, label_value)
    if isinstance(label_value, dict):
        color = label_value.get("display_color")
        if (
            isinstance(color, list)
            and len(color) == 3
            and all(isinstance(value, int) and 0 <= value <= 255 for value in color)
        ):
            return label_name, color
        return label_name, _rtstruct_color_for_label(label_index, label_name)

    return label_name, _rtstruct_color_for_label(label_index, label_name)


def _normalize_rtstruct_label_index(label_index, label_name):
    """
    Convert a label index to an integer.

    Parameters:
    	label_index: The value to convert to an integer.
    	label_name (str): The label name, included in error messages for context.

    Returns:
    	int: The label index as an integer.

    Raises:
    	ValueError: If label_index cannot be converted to an integer.
    """
    try:
        return int(label_index)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"RT Struct label index for '{label_name}' must be an integer. Got {label_index!r}.") from exc


def _validate_rtstruct_mask(mask, label_name, expected_slice_count):
    if not isinstance(mask, np.ndarray):
        raise ValueError(f"RT Struct ROI mask for '{label_name}' must be a numpy array.")
    if mask.dtype != np.bool_:
        raise ValueError(f"RT Struct ROI mask for '{label_name}' must be boolean. Got {mask.dtype}.")
    if mask.ndim != 3:
        raise ValueError(f"RT Struct ROI mask for '{label_name}' must be a 3D numpy array. Got {mask.ndim} dimensions.")
    if mask.shape[2] != expected_slice_count:
        raise ValueError(
            f"RT Struct ROI mask for '{label_name}' must have {expected_slice_count} slices. Got {mask.shape[2]}."
        )


def _segmentation_data_as_uint16(segmentation_img):
    data = np.asanyarray(segmentation_img.dataobj)
    if data.ndim > 3:
        data = np.squeeze(data)
    if data.ndim != 3:
        raise ValueError("The segmentation image must be a 3D volume.")
    return np.rint(data).astype(np.uint16)


def _sanitize_path_component(value):
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    text = str(value) if value is not None else ""
    cleaned = "".join(ch if ch in allowed else "_" for ch in text).strip("._")
    return cleaned or "roi"


def _vector_from_plane(plane, key):
    vector = np.array(plane[key], dtype=np.float64)
    if vector.size != 3:
        raise ValueError(f"Viewer geometry field '{key}' must contain 3 values.")
    return vector


def _sample_plane_labels(data, inverse_affine, plane):
    rows = int(plane["rows"])
    columns = int(plane["columns"])
    if rows <= 0 or columns <= 0:
        raise ValueError("Viewer geometry rows and columns must be positive.")

    row_spacing = float(plane.get("row_spacing", 1.0))
    column_spacing = float(plane.get("column_spacing", 1.0))
    image_position = _vector_from_plane(plane, "image_position")
    row_cosine = _vector_from_plane(plane, "row_cosine")
    column_cosine = _vector_from_plane(plane, "column_cosine")

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


def load_volumetric_roi_manifest(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def generate_projected_volumetric_roi_manifest(
    segmentation_img,
    mapping,
    planes,
    output_dir,
    source_segmentation_path=None,
    reference_dicom_dir=None,
):
    """Project a segmentation volume onto viewer planes and write a brush ROI manifest."""

    if not isinstance(segmentation_img, nib.Nifti1Image):
        raise TypeError("segmentation_img must be a nibabel.Nifti1Image instance")
    if not planes:
        raise ValueError("At least one viewer geometry plane is required.")

    data = _segmentation_data_as_uint16(segmentation_img)
    inverse_affine = np.linalg.inv(segmentation_img.affine)
    roi_root = Path(output_dir)
    roi_root.mkdir(parents=True, exist_ok=True)

    label_records = {}
    for raw_label_index in sorted(mapping.keys(), key=lambda value: int(value)):
        label_index = int(raw_label_index)
        label_name = str(mapping[raw_label_index])
        label_records[label_index] = {
            "index": label_index,
            "name": label_name,
            "safe_name": _sanitize_path_component(label_name),
            "slices": [],
            "voxel_count": 0,
        }

    rows = int(planes[0]["rows"])
    columns = int(planes[0]["columns"])

    for slice_index, plane in enumerate(planes):
        sampled = _sample_plane_labels(data, inverse_affine, plane)
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
            label_dir = roi_root / f"{label_index:03d}_{record['safe_name']}"
            label_dir.mkdir(parents=True, exist_ok=True)
            uid = str(plane.get("sop_instance_uid") or plane.get("identifier") or slice_index)
            uid_safe = _sanitize_path_component(uid)
            raw_path = label_dir / f"slice_{slice_index:04d}_{uid_safe}.raw"
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
        "label_count": len(labels),
        "roi_slice_count": int(sum(len(record["slices"]) for record in labels)),
        "labels": labels,
    }

    manifest_path = roi_root / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)

    return str(manifest_path)


def save_mask_as_rtstruct(segmentation_img, selected_classes, dcm_reference_file, output_path):
    """
    Create an RT Struct file from a segmentation volume with multiple ROI classes.

    Parameters:
        segmentation_img (nibabel.Nifti1Image): The 3D NIfTI segmentation volume.
        selected_classes (dict): Mapping of class indices to class values. Values may be
            dicts containing `display_name`, `name`, `backend_name`, and/or `display_color`,
            or plain values that will be stringified as the ROI name.
        dcm_reference_file (str or Path): Path to a DICOM series directory serving as
            the reference for RT Struct geometry.
        output_path (str or Path): Path where the RT Struct file will be written.

    Raises:
        TypeError: If segmentation_img is not a nibabel.Nifti1Image instance.
        ValueError: If the segmentation volume is not 3D or if ROI mask validation fails.
    """

    if not isinstance(segmentation_img, nib.Nifti1Image):
        raise TypeError("segmentation_img must be a nibabel.Nifti1Image instance")

    from rt_utils import RTStructBuilder
    import logging

    logging.basicConfig(level=logging.WARNING)  # avoid messages from rt_utils

    # Align segmentation to LPS (DICOM) orientation and reorder axes for rt_utils: (Rows, Columns, Slices)
    lps_volume = _reorient_to_lps(segmentation_img)
    if not isinstance(lps_volume, np.ndarray) or lps_volume.ndim != 3:
        dimensions = getattr(lps_volume, "ndim", "unknown")
        raise ValueError(f"RT Struct source volume must be a 3D numpy array. Got {dimensions} dimensions.")
    rows_columns_slices = np.transpose(lps_volume, (1, 0, 2))

    rtstruct = RTStructBuilder.create_new(dicom_series_path=dcm_reference_file)
    rtstruct_series_data = getattr(rtstruct, "series_data", None)
    expected_slice_count = len(rtstruct_series_data) if rtstruct_series_data is not None else rows_columns_slices.shape[2]

    for raw_class_idx, class_value in tqdm(selected_classes.items()):
        raw_class_name = _rtstruct_label_name(raw_class_idx, class_value)
        class_idx = _normalize_rtstruct_label_index(raw_class_idx, raw_class_name)
        class_name, class_color = _rtstruct_label_metadata(class_idx, class_value)
        mask = rows_columns_slices == class_idx
        if not np.any(mask):
            continue

        mask = np.ascontiguousarray(mask, dtype=np.bool_)
        _validate_rtstruct_mask(mask, class_name, expected_slice_count)

        rtstruct.add_roi(
            mask=mask,
            name=class_name,
            color=class_color,
        )

    rtstruct.save(str(output_path))
