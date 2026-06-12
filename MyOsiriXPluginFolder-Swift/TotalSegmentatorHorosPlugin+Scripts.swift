//
// TotalSegmentatorHorosPlugin+Scripts.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    func prepareBridgeScript(at directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("TotalSegmentatorBridge.py", isDirectory: false)
        let scriptContents = """
import argparse
import json
import subprocess
import sys
import traceback
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Bridge script for the Horos TotalSegmentator plugin")
    parser.add_argument("--config", required=True, help="Path to the configuration JSON file")
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    dicom_dir = Path(config["dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_type = config.get("output_type", "dicom")

    output_dir.mkdir(parents=True, exist_ok=True)

    command = [
        sys.executable,
        "-m",
        "totalsegmentator.bin.TotalSegmentator",
        "-i",
        str(dicom_dir),
        "-o",
        str(output_dir),
        "--output_type",
        output_type,
    ]
    command.extend(config.get("totalseg_args", []))

    print("[TotalSegmentatorBridge] Executing: " + " ".join(command), flush=True)

    try:
        result = subprocess.run(command, check=False)
    except Exception:
        print("[TotalSegmentatorBridge] Failed to execute TotalSegmentator:", file=sys.stderr, flush=True)
        traceback.print_exc()
        return 1

    if result.returncode != 0:
        print(f"[TotalSegmentatorBridge] TotalSegmentator exited with status {result.returncode}", file=sys.stderr, flush=True)

    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
"""

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

        return scriptURL
    }

    func prepareNiftiConversionScript(at directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("TotalSegmentatorNiftiConversion.py", isDirectory: false)
        let scriptContents = """
import argparse
import json
import sys
from pathlib import Path

import nibabel as nib
import numpy as np

try:
    import pydicom
except Exception:
    pydicom = None

from totalsegmentator.dicom_io import save_mask_as_rtstruct
from totalsegmentator.nifti_ext_header import load_multilabel_nifti
from totalsegmentator.map_to_binary import class_map


def log(message):
    print(message, file=sys.stderr, flush=True)


def normalize_name(value):
    return value.strip().lower().replace(" ", "_")


def sanitize_path_component(value):
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    text = str(value) if value is not None else ""
    cleaned = "".join(ch if ch in allowed else "_" for ch in text).strip("._")
    return cleaned or "roi"


def strip_extension(path):
    name = path.name
    if name.lower().endswith(".nii.gz"):
        return name[:-7]
    if name.lower().endswith(".nii"):
        return name[:-4]
    return name


def find_multilabel_file(base):
    candidates = [
        base / "segmentations.nii.gz",
        base / "segmentations.nii",
        base / "totalsegmentator.nii.gz",
        base / "totalseg.nii.gz",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    for candidate in sorted(base.glob("*.nii.gz")):
        if "seg" in candidate.name.lower():
            return candidate
    for candidate in sorted(base.glob("*.nii")):
        if "seg" in candidate.name.lower():
            return candidate
    return None


def gather_binary_masks(base):
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
        if "segmentations" in name and path.parent == base:
            continue
        if name.endswith(".nii") or name.endswith(".nii.gz"):
            if "image" in name and "seg" not in name:
                continue
            masks.append(path)
            seen.add(path)
    return masks


def build_multilabel_from_masks(paths):
    if not paths:
        return None
    first_img = nib.load(str(paths[0]))
    data = np.zeros(first_img.shape, dtype=np.uint16)
    mapping = {}
    index = 1
    for path in paths:
        img = nib.load(str(path))
        arr = np.asanyarray(img.dataobj)
        if np.any(arr):
            mapping[index] = strip_extension(path)
            data[arr > 0.5] = index
            index += 1
    if not mapping:
        return None
    new_header = first_img.header.copy()
    new_header.set_data_dtype(np.uint16)
    nifti_img = nib.Nifti1Image(data.astype(np.uint16), first_img.affine, new_header)
    return nifti_img, mapping


def load_segmentation(base, task_name):
    multi = find_multilabel_file(base)
    if multi:
        img = nib.load(str(multi))
        data = np.asanyarray(img.dataobj)
        if data.ndim > 3:
            data = np.squeeze(data)
        data = np.rint(data).astype(np.uint16)
        try:
            _, label_map = load_multilabel_nifti(img)
            mapping = {int(k): str(v) for k, v in label_map.items()}
        except Exception:
            if task_name and task_name in class_map:
                mapping = {int(k): str(v) for k, v in class_map[task_name].items()}
            else:
                labels = [int(v) for v in np.unique(data) if int(v) != 0]
                mapping = {label: "Label_{}".format(label) for label in labels}
        header = img.header.copy()
        header.set_data_dtype(np.uint16)
        nifti_img = nib.Nifti1Image(data.astype(np.uint16), img.affine, header)
        return nifti_img, mapping

    mask_result = build_multilabel_from_masks(gather_binary_masks(base))
    if mask_result:
        return mask_result

    raise RuntimeError("No NIfTI segmentations were found for conversion.")


def filter_selection(segmentation_img, mapping, selected):
    if not selected:
        return segmentation_img, mapping

    selected_indices = [idx for idx, name in mapping.items() if normalize_name(name) in selected]
    if not selected_indices:
        return segmentation_img, mapping

    selected_indices.sort()
    data = np.asanyarray(segmentation_img.dataobj)
    if data.ndim > 3:
        data = np.squeeze(data)
    data = np.rint(data).astype(np.uint16)
    new_data = np.zeros_like(data, dtype=np.uint16)
    new_mapping = {}
    next_index = 1
    for idx in selected_indices:
        new_data[data == idx] = next_index
        new_mapping[next_index] = mapping[idx]
        next_index += 1

    header = segmentation_img.header.copy()
    header.set_data_dtype(np.uint16)
    filtered_img = nib.Nifti1Image(new_data.astype(np.uint16), segmentation_img.affine, header)
    return filtered_img, new_mapping


def save_source_segmentation(segmentation_img, output_dir):
    roi_root = output_dir / "volumetric_rois"
    roi_root.mkdir(parents=True, exist_ok=True)
    source_path = roi_root / "source_segmentation.nii.gz"
    nib.save(segmentation_img, str(source_path))
    return source_path


def load_reference_slices(reference_dir):
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
    data = np.asanyarray(segmentation_img.dataobj)
    if data.ndim > 3:
        data = np.squeeze(data)
    if data.ndim != 3:
        raise RuntimeError("The segmentation NIfTI is not a 3D volume.")
    return np.rint(data).astype(np.uint16)


def sample_slice_labels(data, inverse_affine, reference_slice):
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


def generate_volumetric_roi_manifest(segmentation_img, mapping, reference_dir, output_dir, source_segmentation_path=None):
    reference_slices = load_reference_slices(reference_dir)
    data = segmentation_data_as_uint16(segmentation_img)
    inverse_affine = np.linalg.inv(segmentation_img.affine)

    rows = reference_slices[0]["rows"]
    columns = reference_slices[0]["columns"]
    roi_root = output_dir / "volumetric_rois"
    roi_root.mkdir(parents=True, exist_ok=True)

    label_records = {}
    for label_index in sorted(mapping.keys()):
        label_name = str(mapping[label_index])
        safe_name = sanitize_path_component(label_name)
        label_records[int(label_index)] = {
            "index": int(label_index),
            "name": label_name,
            "safe_name": safe_name,
            "slices": [],
            "voxel_count": 0,
        }

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
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    nifti_dir = Path(config["nifti_dir"]).expanduser()
    reference_dir = Path(config["reference_dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    selected = {normalize_name(name) for name in config.get("selected_classes", []) if isinstance(name, str)}
    task_name = config.get("task")

    segmentation_img, mapping = load_segmentation(nifti_dir, task_name)
    if not mapping:
        raise RuntimeError("No segmentation labels available for conversion.")

    segmentation_img, mapping = filter_selection(segmentation_img, mapping, selected)
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
        )
        if volumetric_roi_manifest_path:
            log("[TotalSegmentatorNiftiConversion] Generated volumetric ROI manifest at {}".format(volumetric_roi_manifest_path))
        else:
            log("[TotalSegmentatorNiftiConversion] No non-empty volumetric ROI masks were generated.")
    except Exception as exc:
        log("[TotalSegmentatorNiftiConversion] Volumetric ROI manifest generation failed: {}".format(exc))

    rtstruct_name = config.get("rtstruct_name", "segmentations_rtstruct.dcm")
    rtstruct_path = output_dir / rtstruct_name

    rtstruct_paths = []
    try:
        save_mask_as_rtstruct(segmentation_img, mapping, str(reference_dir), str(rtstruct_path))
        rtstruct_paths = [str(rtstruct_path)]
    except Exception as exc:
        if volumetric_roi_manifest_path:
            log("[TotalSegmentatorNiftiConversion] RT Struct generation failed; continuing with volumetric ROI manifest: {}".format(exc))
        else:
            raise

    result = {
        "rtstruct_paths": rtstruct_paths,
        "dicom_series_directories": [],
        "volumetric_roi_manifest_path": volumetric_roi_manifest_path,
        "source_segmentation_path": str(source_segmentation_path),
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log("[TotalSegmentatorNiftiConversion] {}".format(exc))
        sys.exit(1)
"""

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

        return scriptURL
    }

    func prepareVolumetricProjectionScript(at directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("TotalSegmentatorVolumetricProjection.py", isDirectory: false)
        let scriptContents = """
import argparse
import json
import sys
from pathlib import Path

import nibabel as nib

from totalsegmentator.dicom_io import (
    generate_projected_volumetric_roi_manifest,
    load_volumetric_roi_manifest,
)


def main():
    parser = argparse.ArgumentParser(description="Project TotalSegmentator volumetric ROIs onto viewer geometry")
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    original_manifest = load_volumetric_roi_manifest(config["manifest_path"])
    source_path = original_manifest.get("source_segmentation_path")
    if not source_path:
        raise RuntimeError("The volumetric ROI manifest does not contain source_segmentation_path.")
    if not Path(source_path).exists():
        raise RuntimeError("The source segmentation volume is missing: {}".format(source_path))

    labels = original_manifest.get("labels", [])
    mapping = {int(label["index"]): str(label["name"]) for label in labels if "index" in label and "name" in label}
    if not mapping:
        raise RuntimeError("The volumetric ROI manifest does not contain labels.")

    output_dir = Path(config["output_dir"]).expanduser()
    planes = config.get("planes", [])
    segmentation_img = nib.load(source_path)
    projected_manifest = generate_projected_volumetric_roi_manifest(
        segmentation_img=segmentation_img,
        mapping=mapping,
        planes=planes,
        output_dir=output_dir,
        source_segmentation_path=source_path,
        reference_dicom_dir=original_manifest.get("reference_dicom_dir", ""),
    )
    if not projected_manifest:
        raise RuntimeError("No projected volumetric ROIs were generated for the current viewer geometry.")

    print(json.dumps({"manifest_path": projected_manifest}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("[TotalSegmentatorVolumetricProjection] {}".format(exc), file=sys.stderr, flush=True)
        sys.exit(1)
"""

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

        return scriptURL
    }

    func writeVolumetricProjectionConfiguration(
        to directory: URL,
        manifestPath: String,
        outputDirectory: URL,
        planes: [[String: Any]]
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorVolumetricProjection.json", isDirectory: false)

        let payload: [String: Any] = [
            "manifest_path": manifestPath,
            "output_dir": outputDirectory.path,
            "planes": planes
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }

    func writeBridgeConfiguration(
        to directory: URL,
        dicomDirectory: URL,
        outputDirectory: URL,
        outputType: String,
        totalsegmentatorArguments: [String]
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorBridgeConfiguration.json", isDirectory: false)

        let payload: [String: Any] = [
            "dicom_dir": dicomDirectory.path,
            "output_dir": outputDirectory.path,
            "output_type": outputType,
            "totalseg_args": totalsegmentatorArguments
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }

    func writeNiftiConversionConfiguration(
        to directory: URL,
        niftiDirectory: URL,
        referenceDirectory: URL,
        outputDirectory: URL,
        preferences: SegmentationPreferences.State
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorNiftiConversion.json", isDirectory: false)

        var payload: [String: Any] = [
            "nifti_dir": niftiDirectory.path,
            "reference_dicom_dir": referenceDirectory.path,
            "output_dir": outputDirectory.path,
            "selected_classes": preferences.selectedClassNames,
            "rtstruct_name": "segmentations_rtstruct.dcm"
        ]

        if let task = preferences.task {
            payload["task"] = task
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }
}
