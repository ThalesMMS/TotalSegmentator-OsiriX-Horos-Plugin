import json
import importlib
import sys
from pathlib import Path

import numpy as np
import pytest


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "MyOsiriXPluginFolder-Swift"
BRIDGE_ROOT = SWIFT_DIR / "python_bridge"
PACKAGE_ROOT = BRIDGE_ROOT / "ts_horos_bridge"
SEGMENTATION_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Segmentation.swift"
IMPORT_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Import.swift"
SCRIPTS_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Scripts.swift"
PREFERENCES_SWIFT = SWIFT_DIR / "TotalSegmentatorHorosPlugin+Preferences.swift"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Load text content from a file.

    Returns:
    	str: The file's text content.
    """
    return path.read_text(encoding="utf-8")


class _FakeHeader:
    def copy(self):
        return self

    def set_data_dtype(self, dtype):
        self.dtype = dtype


class _FakeSegmentationImage:
    def __init__(self, data):
        self.dataobj = data
        self.affine = np.eye(4)
        self.header = _FakeHeader()


def _nifti_conversion_module():
    sys.path.insert(0, str(BRIDGE_ROOT))
    sys.modules.pop("ts_horos_bridge.nifti_conversion", None)
    return importlib.import_module("ts_horos_bridge.nifti_conversion")


def _use_loaded_numpy(module):
    module.np = np
    module.nib = object()


def test_disabled_rtstruct_mode_does_not_load_rt_utils(monkeypatch):
    module = _nifti_conversion_module()
    called = False

    def fail_if_called():
        nonlocal called
        called = True
        raise ImportError("rt_utils missing")

    monkeypatch.setattr(module, "load_rtstruct_writer", fail_if_called)

    paths, status, error = module.generate_rtstruct_artifact(
        rtstruct_mode="disabled",
        segmentation_img=object(),
        mapping={1: "liver"},
        label_metadata={},
        task_name="total",
        reference_dir=Path("/tmp/reference"),
        rtstruct_path=Path("/tmp/rtstruct.dcm"),
        volumetric_roi_manifest_path="/tmp/volumetric_rois/manifest.json",
    )

    assert paths == []
    assert status == "disabled"
    assert error is None
    assert called is False


def test_default_disabled_rtstruct_reports_failure_when_no_volumetric_roi_manifest(monkeypatch):
    module = _nifti_conversion_module()
    called = False

    def fail_if_called():
        nonlocal called
        called = True
        raise ImportError("rt_utils missing")

    monkeypatch.setattr(module, "load_rtstruct_writer", fail_if_called)

    paths, status, error = module.generate_rtstruct_artifact(
        rtstruct_mode="disabled",
        segmentation_img=object(),
        mapping={1: "liver"},
        label_metadata={},
        task_name="total",
        reference_dir=Path("/tmp/reference"),
        rtstruct_path=Path("/tmp/rtstruct.dcm"),
        volumetric_roi_manifest_path=None,
    )

    assert paths == []
    assert status == "failed"
    assert "No importable volumetric ROI manifest" in error
    assert called is False


def test_optional_rtstruct_failure_is_reported_without_raising(monkeypatch):
    module = _nifti_conversion_module()

    def missing_writer():
        raise ImportError("rt_utils missing")

    monkeypatch.setattr(module, "load_rtstruct_writer", missing_writer)

    paths, status, error = module.generate_rtstruct_artifact(
        rtstruct_mode="optional",
        segmentation_img=object(),
        mapping={1: "liver"},
        label_metadata={},
        task_name="total",
        reference_dir=Path("/tmp/reference"),
        rtstruct_path=Path("/tmp/rtstruct.dcm"),
        volumetric_roi_manifest_path="/tmp/volumetric_rois/manifest.json",
    )

    assert paths == []
    assert status == "failed"
    assert "rt_utils missing" in error


def test_required_rtstruct_failure_raises_derived_artifact_error(monkeypatch):
    module = _nifti_conversion_module()

    def failing_writer():
        raise RuntimeError("conversion failed")

    monkeypatch.setattr(module, "load_rtstruct_writer", failing_writer)

    try:
        module.generate_rtstruct_artifact(
            rtstruct_mode="required",
            segmentation_img=object(),
            mapping={1: "liver"},
            label_metadata={},
            task_name="total",
            reference_dir=Path("/tmp/reference"),
            rtstruct_path=Path("/tmp/rtstruct.dcm"),
            volumetric_roi_manifest_path="/tmp/volumetric_rois/manifest.json",
        )
    except RuntimeError as exc:
        assert "Required RT Struct generation failed" in str(exc)
    else:
        raise AssertionError("required RT-Struct failure should raise")


def test_rtstruct_writer_receives_same_label_indexes_as_canonical_mapping(monkeypatch):
    module = _nifti_conversion_module()
    captured = {}

    def fake_writer(segmentation_img, rtstruct_mapping, reference_dir, rtstruct_path):
        captured["mapping"] = rtstruct_mapping
        captured["reference_dir"] = reference_dir
        captured["rtstruct_path"] = rtstruct_path

    monkeypatch.setattr(module, "load_rtstruct_writer", lambda: fake_writer)

    paths, status, error = module.generate_rtstruct_artifact(
        rtstruct_mode="optional",
        segmentation_img=object(),
        mapping={7: "liver", 12: "spleen"},
        label_metadata={},
        task_name="total",
        reference_dir=Path("/tmp/reference"),
        rtstruct_path=Path("/tmp/rtstruct.dcm"),
        volumetric_roi_manifest_path="/tmp/volumetric_rois/manifest.json",
    )

    assert paths == ["/tmp/rtstruct.dcm"]
    assert status == "succeeded"
    assert error is None
    assert set(captured["mapping"]) == {7, 12}


def test_binary_mask_gathering_excludes_only_exact_root_multilabel_outputs(tmp_path):
    module = _nifti_conversion_module()
    base = tmp_path
    nested = base / "segmentations"
    nested.mkdir()

    root_multilabel = base / "segmentations.nii.gz"
    future_mask = base / "abdominal_segmentations.nii.gz"
    nested_mask = nested / "liver.nii.gz"
    source_image = base / "image.nii.gz"
    for path in [root_multilabel, future_mask, nested_mask, source_image]:
        path.write_text("placeholder", encoding="utf-8")

    masks = module.gather_binary_masks(base)

    assert root_multilabel not in masks
    assert future_mask in masks
    assert nested_mask in masks
    assert source_image not in masks


def test_class_filter_raises_when_requested_classes_match_no_labels():
    module = _nifti_conversion_module()
    _use_loaded_numpy(module)

    with pytest.raises(RuntimeError, match="did not match any segmentation labels"):
        module.filter_selection(
            object(),
            {1: "liver"},
            {module.normalize_name("stale_class_name")},
            {},
        )


@pytest.mark.parametrize(
    ("data", "message"),
    [
        (np.array([[[np.nan]]], dtype=np.float64), "non-finite"),
        (np.array([[[-1.0]]], dtype=np.float64), "negative"),
        (np.array([[[1.25]]], dtype=np.float64), "non-integer"),
        (np.array([[[70000.0]]], dtype=np.float64), "uint16"),
    ],
)
def test_segmentation_data_as_uint16_rejects_invalid_label_values(data, message):
    module = _nifti_conversion_module()
    _use_loaded_numpy(module)

    with pytest.raises(RuntimeError, match=message):
        module.segmentation_data_as_uint16(_FakeSegmentationImage(data))


def test_conversion_main_fails_when_no_importable_artifact_is_created(tmp_path, monkeypatch):
    module = _nifti_conversion_module()
    config_path = tmp_path / "config.json"
    result_path = tmp_path / "result.json"
    output_dir = tmp_path / "output"
    config_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "nifti_dir": str(tmp_path / "nifti"),
                "reference_dicom_dir": str(tmp_path / "dicom"),
                "output_dir": str(output_dir),
                "rtstruct_mode": "disabled",
            }
        ),
        encoding="utf-8",
    )

    fake_segmentation = object()
    monkeypatch.setattr(module, "load_segmentation", lambda *args: (fake_segmentation, {1: "liver"}, {}))
    monkeypatch.setattr(module, "filter_selection", lambda segmentation, mapping, selected, metadata: (segmentation, mapping, metadata))
    monkeypatch.setattr(module, "save_source_segmentation", lambda *args: output_dir / "volumetric_rois" / "source_segmentation.nii.gz")
    monkeypatch.setattr(module, "generate_volumetric_roi_manifest", lambda *args: None)
    monkeypatch.setattr(
        module,
        "generate_rtstruct_artifact",
        lambda **kwargs: ([], "failed", "No importable volumetric ROI manifest was generated and RT Struct generation is disabled."),
    )
    monkeypatch.setattr(sys, "argv", ["nifti_conversion.py", "--config", str(config_path), "--result", str(result_path)])

    exit_code = module.main()

    payload = json.loads(result_path.read_text(encoding="utf-8"))
    assert exit_code != 0
    assert payload["status"] == "error"
    assert payload["stage"] == "nifti_conversion"
    assert payload["error_code"] == "no_importable_artifacts"
    assert "No importable artifact" in payload["message"]


def test_load_and_filter_selection_use_strict_uint16_conversion():
    source = _read(PACKAGE_ROOT / "nifti_conversion.py")
    load_start = source.find("def load_segmentation")
    load_end = source.find("def filter_selection", load_start)
    load_body = source[load_start:load_end]
    filter_start = source.find("def filter_selection")
    filter_end = source.find("def save_source_segmentation", filter_start)
    filter_body = source[filter_start:filter_end]

    assert "data = segmentation_data_as_uint16(img)" in load_body
    assert "data = segmentation_data_as_uint16(segmentation_img)" in filter_body
    assert "np.rint(data).astype(np.uint16)" not in load_body
    assert "np.rint(data).astype(np.uint16)" not in filter_body


def test_swift_rtstruct_policy_is_postprocessing_only():
    """
    Validates that the Swift plugin implements RT-Struct export as a postprocessing-only operation with disabled-by-default behavior.

    Checks that the Swift source files adhere to the RT-Struct policy by asserting:
    - RT-Struct utilities are not eagerly loaded in segmentation code.
    - The preferences module defaults to disabled export mode.
    - The segmentation code extracts the export mode setting.
    - The Python bridge scripts receive the export mode value.
    """
    segmentation = _read(SEGMENTATION_SWIFT)
    preferences = _read(PREFERENCES_SWIFT)
    scripts = _read(SCRIPTS_SWIFT)

    assert "ensureRtUtilsAvailable" not in segmentation
    assert "rtStructExportMode: RTStructExportMode = .disabled" in preferences
    assert "extractRTStructExportMode" in segmentation
    assert "\"rtstruct_mode\": preferences.rtStructExportMode.rawValue" in scripts


def test_swift_visualization_imports_volumetric_rois_before_rtstruct_paths():
    source = _read(IMPORT_SWIFT)
    update_start = source.index("private func updateVisualization")
    update_end = source.index("private func openViewer", update_start)
    update_body = source[update_start:update_end]

    assert "TSVolumetricROIImporter.importVolumetricROIs" in update_body
    assert "if appliedOverlayCount == 0" not in update_body
    assert "RT Struct overlay applied; volumetric brush ROI import remains available as fallback" not in update_body
    assert "Waiting for Horos to finish converting RT Struct overlays" not in update_body
    assert "waitForRTStructConversionsToFinish" not in update_body


def test_progress_and_readme_describe_rtstruct_as_optional_derived_artifact():
    swift_source = _read(IMPORT_SWIFT) + _read(SEGMENTATION_SWIFT)
    readme = _read(README)

    assert "RT Struct generation disabled." in swift_source
    assert "Optional RT Struct generation failed" in swift_source
    assert "RT-Struct export is disabled by default" in readme
