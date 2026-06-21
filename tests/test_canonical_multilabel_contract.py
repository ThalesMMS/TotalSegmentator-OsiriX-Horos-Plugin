from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SEGMENTATION_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Segmentation.swift"
SCRIPTS_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Scripts.swift"
IMPORT_SWIFT = ROOT / "MyOsiriXPluginFolder-Swift" / "TotalSegmentatorHorosPlugin+Import.swift"
BRIDGE_PACKAGE = ROOT / "MyOsiriXPluginFolder-Swift" / "python_bridge" / "ts_horos_bridge"
BRIDGE_CLI = BRIDGE_PACKAGE / "cli.py"
BRIDGE_NIFTI_CONVERSION = BRIDGE_PACKAGE / "nifti_conversion.py"
README = ROOT / "README.md"


def _read(path: Path) -> str:
    """
    Read the text contents of a file.
    
    Parameters:
    	path (Path): The file path to read.
    
    Returns:
    	str: The file contents.
    """
    return path.read_text(encoding="utf-8")


def test_supported_tasks_launch_with_multilabel_and_canonical_output_contract():
    segmentation = _read(SEGMENTATION_SWIFT)
    scripts = _read(SCRIPTS_SWIFT)
    bridge_cli = _read(BRIDGE_CLI)

    assert "launchCapability.supportsMultilabel" in segmentation
    assert "TaskCapabilityManifest.containsFlag(\"--ml\"" in segmentation
    assert "totalSegmentatorArguments.append(\"--ml\")" in segmentation
    assert "canonicalOutputName: \"segmentation.nii.gz\"" in segmentation
    assert "useMultilabel: launchCapability.supportsMultilabel" in segmentation
    assert "taskIdentifier: launchCapability.identifier" in segmentation

    assert "\"canonical_output_name\"" in scripts
    assert "\"use_multilabel\"" in scripts
    assert "\"task_identifier\"" in scripts
    assert "segmentation.nii.gz" in bridge_cli
    assert "label-map.json" in bridge_cli


def test_bridge_normalizes_and_validates_backend_multilabel_output():
    bridge_cli = _read(BRIDGE_CLI)

    for symbol in [
        "normalize_canonical_multilabel_output",
        "persist_canonical_label_map",
        "load_multilabel_nifti",
        "np.linalg.inv",
        "np.isfinite",
        "np.allclose",
        "canonical_segmentation_path",
        "noncanonical_nifti_outputs",
        "unknown_label_values",
        "Expected exactly one canonical NIfTI output",
        "non-integer label values",
    ]:
        assert symbol in bridge_cli


def test_conversion_consumes_canonical_nifti_and_label_map_before_compatibility_masks():
    conversion = _read(BRIDGE_NIFTI_CONVERSION)

    assert "load_normalized_label_map" in conversion
    assert "allow_binary_mask_compatibility=False" in conversion
    assert "allow_binary_mask_compatibility" in conversion
    assert "base / \"segmentation.nii.gz\"" in conversion
    assert "base / \"label-map.json\"" in conversion
    assert "build_multilabel_from_masks(gather_binary_masks(base))" not in conversion
    assert "def find_multilabel_file" not in conversion


def test_class_filter_preserves_backend_label_ids_without_renumbering():
    """
    Validate that label filtering preserves backend label IDs without renumbering.
    
    Verifies that the filter_selection logic in the conversion pipeline preserves original label identifiers and values without introducing renumbering.
    """
    conversion = _read(BRIDGE_NIFTI_CONVERSION)
    filter_start = conversion.find("def filter_selection")
    filter_end = conversion.find("def save_source_segmentation", filter_start)
    filter_block = conversion[filter_start:filter_end]

    assert "new_mapping[idx] = mapping[idx]" in filter_block
    assert "new_data[data == idx] = idx" in filter_block
    assert "next_index" not in filter_block


def test_swift_validation_requires_canonical_pair_for_multilabel_tasks():
    source = _read(IMPORT_SWIFT)

    assert "requiresCanonicalMultilabelOutput" in source
    assert "segmentation.nii.gz" in source
    assert "label-map.json" in source
    assert "label-map" in source
    assert "expectedArtifactMissing(\"segmentation.nii.gz\")" in source
    assert "expectedArtifactMissing(\"label-map.json\")" in source


def test_readme_documents_canonical_multilabel_outputs():
    readme = _read(README)

    assert "segmentation.nii.gz" in readme
    assert "label-map.json" in readme
    assert "canonical multilabel" in readme
