import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import traceback
from pathlib import Path

PACKAGE_PARENT = Path(__file__).resolve().parents[1]
if str(PACKAGE_PARENT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_PARENT))

from ts_horos_bridge.schemas import error_result, success_result, validate_request_schema
from ts_horos_bridge.terminology import label_map_record, load_terminology_resource, terminology_summary

nib = None
np = None
class_map = None
load_multilabel_nifti = None
DEVICE_ARGUMENT_FLAGS = {"--device", "-d"}
VISIBLE_DEVICE_ARGUMENT_VALUES = {"cpu", "gpu", "mps"}


def load_image_dependencies():
    """
    Ensure nibabel and numpy are imported and available as module globals.
    """
    global nib, np
    if nib is None or np is None:
        import nibabel as _nib
        import numpy as _np

        nib = _nib
        np = _np


def load_totalsegmentator_metadata_dependencies():
    """
    Lazily import TotalSegmentator metadata utilities.

    Loads class_map and load_multilabel_nifti from their respective TotalSegmentator modules
    into module globals if not already loaded.
    """
    global class_map, load_multilabel_nifti
    if class_map is None or load_multilabel_nifti is None:
        from totalsegmentator.map_to_binary import class_map as _class_map
        from totalsegmentator.nifti_ext_header import load_multilabel_nifti as _load_multilabel_nifti

        class_map = _class_map
        load_multilabel_nifti = _load_multilabel_nifti


def log(message):
    """
    Log a message to standard error output.
    """
    print(message, file=sys.stderr, flush=True)


def has_flag(arguments, flag):
    """
    Determine if a flag is present in a list of arguments.

    The flag matches if an argument equals it exactly or starts with it followed by "=".

    Parameters:
    	arguments: A list or iterable of command-line argument strings.
    	flag: The flag to search for.

    Returns:
    	True if the flag is found, False otherwise.
    """
    return any(token == flag or str(token).startswith(flag + "=") for token in arguments)


def is_sensitive_argument(argument):
    lowercased = str(argument).lower()
    return any(marker in lowercased for marker in ("license", "token", "password", "secret", "key"))


def is_visible_device_argument_value(argument):
    text = str(argument)
    if text in VISIBLE_DEVICE_ARGUMENT_VALUES:
        return True
    if text.startswith("gpu:"):
        return text.partition(":")[2].isdecimal()
    return False


def redacted_totalseg_args(arguments):
    redacted = []
    redact_next = False
    show_next_device = False
    for argument in arguments:
        text = str(argument)
        if redact_next:
            redacted.append("[redacted]")
            redact_next = False
            continue

        if show_next_device:
            redacted.append(text if is_visible_device_argument_value(text) else "[argument]")
            show_next_device = False
            continue

        if text == "--ml":
            redacted.append(text)
        elif is_sensitive_argument(text):
            if "=" in text:
                prefix = text.split("=", 1)[0]
                redacted.append(prefix + "=[redacted]")
            else:
                redacted.append(text)
                redact_next = True
        elif text in DEVICE_ARGUMENT_FLAGS:
            redacted.append(text)
            show_next_device = True
        elif "=" in text and text.split("=", 1)[0] in DEVICE_ARGUMENT_FLAGS:
            prefix, value = text.split("=", 1)
            redacted_value = value if is_visible_device_argument_value(value) else "[argument]"
            redacted.append(prefix + "=" + redacted_value)
        elif text.startswith("-") and "=" in text:
            prefix = text.split("=", 1)[0]
            redacted.append(prefix + "=[argument]")
        elif text.startswith("-"):
            redacted.append(text)
        else:
            redacted.append("[argument]")
    return redacted


def redacted_command_for_log(base_command, totalseg_args):
    return list(base_command) + redacted_totalseg_args(totalseg_args)


def run_totalsegmentator_command(command):
    process = subprocess.Popen(command, start_new_session=True)
    previous_sigterm = signal.getsignal(signal.SIGTERM)
    previous_sigint = signal.getsignal(signal.SIGINT)

    def forward_signal(signum, _frame):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)
    try:
        return process.wait()
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        signal.signal(signal.SIGINT, previous_sigint)


def atomic_write_json(path, payload):
    """
    Write JSON data to a file atomically.
    """
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
    tmp_path.replace(path)


def canonical_segmentation_path(output_dir, canonical_output_name):
    """
    Construct the path to the canonical segmentation output file.

    Returns:
    	pathlib.Path: The full path to the canonical segmentation file.
    """
    return output_dir / canonical_output_name


def is_nifti_path(path):
    """
    Checks whether a path refers to a NIfTI file.

    Returns:
    	bool: True if the path has a NIfTI filename extension, False otherwise.
    """
    name = path.name.lower()
    return name.endswith(".nii") or name.endswith(".nii.gz")


def noncanonical_nifti_outputs(output_dir, canonical_path):
    """
    Find all NIfTI files in a directory except a specified canonical file.

    Resolved paths are compared to account for symlinks and aliases.

    Parameters:
    	output_dir: Directory to search for NIfTI files.
    	canonical_path: Path to the canonical file to exclude from results.

    Returns:
    	list: NIfTI files whose resolved path differs from canonical_path.
    """
    canonical_resolved = canonical_path.resolve()
    return [
        path
        for path in output_dir.iterdir()
        if path.is_file() and is_nifti_path(path) and path.resolve() != canonical_resolved
    ]


def find_existing_multilabel_candidate(output_dir):
    """
    Find an existing multilabel segmentation file in the directory.

    Returns:
    	Path or None: Path to the segmentation file if found, None otherwise
    """
    candidates = [
        output_dir / "segmentation.nii.gz",
        output_dir / "segmentations.nii.gz",
        output_dir / "segmentations.nii",
        output_dir / "totalsegmentator.nii.gz",
        output_dir / "totalseg.nii.gz",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    for candidate in sorted(output_dir.glob("*.nii.gz")):
        if "seg" in candidate.name.lower():
            return candidate
    for candidate in sorted(output_dir.glob("*.nii")):
        if "seg" in candidate.name.lower():
            return candidate
    return None


def segmentation_data_as_uint16(img):
    """
    Validate and convert NIfTI segmentation voxel data to uint16.

    Ensures the segmentation is a 3D volume with finite, nonnegative, integer-like label values that fit within the uint16 range.

    Parameters:
        img: A nibabel NIfTI image object containing segmentation data.

    Returns:
        A uint16 numpy array containing the validated segmentation labels.

    Raises:
        RuntimeError: If the volume is not 3D, contains non-finite or negative values, contains non-integer values, or exceeds uint16 range.
    """
    load_image_dependencies()
    data = np.asanyarray(img.dataobj)
    if data.ndim > 3:
        data = np.squeeze(data)
    if data.ndim != 3:
        raise RuntimeError("Canonical segmentation must be a 3D NIfTI volume.")
    if not np.all(np.isfinite(data)):
        raise RuntimeError("Canonical segmentation contains non-finite voxel values.")
    if np.any(data < 0):
        raise RuntimeError("Canonical segmentation contains negative label values.")
    rounded = np.rint(data)
    if not np.allclose(data, rounded):
        raise RuntimeError("Canonical segmentation contains non-integer label values.")
    if np.max(rounded) > np.iinfo(np.uint16).max:
        raise RuntimeError("Canonical segmentation label values exceed uint16 range.")
    return rounded.astype(np.uint16)


def load_label_map_from_nifti(img, data, task_identifier):
    """
    Extract or derive a label mapping for segmentation labels.

    Parameters:
        task_identifier (str or None): Task identifier for looking up predefined label mappings.

    Returns:
        dict: Mapping of integer label indices to string label names.
    """
    load_image_dependencies()
    load_totalsegmentator_metadata_dependencies()
    try:
        _, label_map = load_multilabel_nifti(img)
        mapping = {int(k): str(v) for k, v in label_map.items()}
    except Exception:
        if task_identifier and task_identifier in class_map:
            mapping = {int(k): str(v) for k, v in class_map[task_identifier].items()}
        else:
            labels = [int(v) for v in np.unique(data) if int(v) != 0]
            mapping = {label: "Label_{}".format(label) for label in labels}
    return {int(k): str(v) for k, v in mapping.items()}


def validate_canonical_multilabel(img, data, mapping):
    """
    Validate a canonical multilabel segmentation image.

    Checks that the image affine is finite and invertible, that at least one
    non-zero label is present, and that all unique non-zero labels in the data
    exist as keys in the provided mapping.

    Parameters:
        img: A nibabel image object with affine transformation matrix.
        data: A NumPy array of voxel label values.
        mapping: A dictionary mapping label indices (int) to label names (str).

    Returns:
        A sorted list of unique non-zero label values present in data.

    Raises:
        RuntimeError: If the affine contains non-finite values, is not invertible,
                      no non-zero labels exist, or any present label is missing
                      from the mapping.
    """
    load_image_dependencies()
    if not np.all(np.isfinite(img.affine)):
        raise RuntimeError("Canonical segmentation affine contains non-finite values.")
    try:
        np.linalg.inv(img.affine)
    except Exception as exc:
        raise RuntimeError("Canonical segmentation affine is not invertible.") from exc

    present_labels = sorted(int(v) for v in np.unique(data) if int(v) != 0)
    if not present_labels:
        raise RuntimeError("Canonical segmentation contains no non-empty labels.")

    unknown_label_values = [value for value in present_labels if value not in mapping]
    if unknown_label_values:
        raise RuntimeError("Canonical segmentation contains labels missing from label-map.json: {}".format(unknown_label_values))

    return present_labels


def persist_canonical_label_map(output_dir, task_identifier, mapping, present_labels):
    """
    Persist a canonical label map JSON file containing label indices and terminology metadata to the output directory.
    """
    terminology_resource = load_terminology_resource()
    payload = {
        "version": 1,
        "format": "totalsegmentator-canonical-label-map",
        "task": task_identifier,
        "terminology": terminology_summary(terminology_resource),
        "labels": [
            label_map_record(
                label_index,
                mapping[label_index],
                task_identifier,
                present_labels,
                resource=terminology_resource,
            )
            for label_index in sorted(mapping.keys())
        ],
    }
    atomic_write_json(output_dir / "label-map.json", payload)


def normalize_canonical_multilabel_output(output_dir, canonical_output_name, task_identifier):
    """
    Validates, normalizes, and persists a canonical multilabel segmentation NIfTI output.

    Parameters:
    	task_identifier (str): Task identifier used for label mapping lookups.

    Raises:
    	RuntimeError: If the canonical segmentation file is missing and no candidate exists, or if unexpected extra NIfTI files are present.
    """
    load_image_dependencies()
    canonical_path = canonical_segmentation_path(output_dir, canonical_output_name)
    if not canonical_path.exists():
        candidate = find_existing_multilabel_candidate(output_dir)
        if candidate is None:
            raise RuntimeError("TotalSegmentator did not produce canonical segmentation.nii.gz.")
        if candidate != canonical_path:
            shutil.copyfile(candidate, canonical_path)
            candidate.unlink()

    extra_nifti_outputs = noncanonical_nifti_outputs(output_dir, canonical_path)
    if extra_nifti_outputs:
        names = sorted(path.name for path in extra_nifti_outputs)
        raise RuntimeError("Expected exactly one canonical NIfTI output, found extra file(s): {}".format(names))

    img = nib.load(str(canonical_path))
    data = segmentation_data_as_uint16(img)
    mapping = load_label_map_from_nifti(img, data, task_identifier)
    present_labels = validate_canonical_multilabel(img, data, mapping)

    header = img.header.copy()
    header.set_data_dtype(np.uint16)
    canonical_img = nib.Nifti1Image(data.astype(np.uint16), img.affine, header)
    nib.save(canonical_img, str(canonical_path))
    persist_canonical_label_map(output_dir, task_identifier, mapping, present_labels)


def main():
    """
    Orchestrate the TotalSegmentator segmentation workflow, validating configuration, executing segmentation, and post-processing multilabel output if requested.

    Reads configuration from the file specified by `--config`, validates it against the request schema, constructs and executes a TotalSegmentator command, optionally normalizes multilabel segmentation output, and writes results to the file specified by `--result`.

    Returns:
        0 on success, 64 on configuration schema validation failure, 1 on TotalSegmentator launch failure, 2 on multilabel validation failure, or the TotalSegmentator process exit code on segmentation failure.
    """
    parser = argparse.ArgumentParser(description="Bridge script for the Horos TotalSegmentator plugin")
    parser.add_argument("--config", required=True, help="Path to the configuration JSON file")
    parser.add_argument("--result", required=True, help="Path for the machine-readable result JSON")
    args = parser.parse_args()
    result_path = Path(args.result).expanduser()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    try:
        validate_request_schema(config)
    except ValueError as exc:
        atomic_write_json(
            result_path,
            error_result("segmentation", "request_schema_mismatch", str(exc)),
        )
        return 64

    dicom_dir = Path(config["dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_type = config.get("output_type", "dicom")
    canonical_output_name = config.get("canonical_output_name", "segmentation.nii.gz")
    use_multilabel = bool(config.get("use_multilabel", False))
    task_identifier = config.get("task_identifier") or "total"

    output_dir.mkdir(parents=True, exist_ok=True)
    output_target = canonical_segmentation_path(output_dir, canonical_output_name) if use_multilabel else output_dir

    base_command = [
        sys.executable,
        "-m",
        "totalsegmentator.bin.TotalSegmentator",
        "-i",
        str(dicom_dir),
        "-o",
        str(output_target),
        "--output_type",
        output_type,
    ]
    totalseg_args = list(config.get("totalseg_args", []))
    if use_multilabel and not has_flag(totalseg_args, "--ml"):
        totalseg_args.append("--ml")
    command = base_command + totalseg_args

    safe_command = redacted_command_for_log(base_command, totalseg_args)
    print("[TotalSegmentatorBridge] Executing: " + " ".join(safe_command), flush=True)

    try:
        return_code = run_totalsegmentator_command(command)
    except Exception as exc:
        print("[TotalSegmentatorBridge] Failed to execute TotalSegmentator:", file=sys.stderr, flush=True)
        traceback.print_exc()
        atomic_write_json(
            result_path,
            error_result("segmentation", "totalsegmentator_launch_failed", str(exc)),
        )
        return 1

    if return_code != 0:
        print(f"[TotalSegmentatorBridge] TotalSegmentator exited with status {return_code}", file=sys.stderr, flush=True)
        atomic_write_json(
            result_path,
            error_result(
                "segmentation",
                "totalsegmentator_failed",
                "TotalSegmentator exited with status {}".format(return_code),
            ),
        )
        return return_code

    if use_multilabel:
        try:
            normalize_canonical_multilabel_output(output_dir, canonical_output_name, task_identifier)
        except Exception as exc:
            print("[TotalSegmentatorBridge] Canonical multilabel validation failed:", file=sys.stderr, flush=True)
            traceback.print_exc()
            atomic_write_json(
                result_path,
                error_result("segmentation_validation", "canonical_multilabel_invalid", str(exc)),
            )
            return 2

    atomic_write_json(
        result_path,
        success_result(
            "segmentation",
            output_dir=str(output_dir),
            canonical_output_path=str(canonical_segmentation_path(output_dir, canonical_output_name)) if use_multilabel else None,
            label_map_path=str(output_dir / "label-map.json") if use_multilabel else None,
        ),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
