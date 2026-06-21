from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADR_PATH = ROOT / "docs" / "adr" / "0001-slicer-parity-robustness-and-clinical-boundary.md"
CHECKLIST_PATH = ROOT / "docs" / "release" / "robustness-release-checklist.md"
README_PATH = ROOT / "README.md"
PLAN_PATH = ROOT / "docs" / "superpowers" / "plans" / "2026-06-20-issue-13-robustness-adr.md"


def _read(path: Path) -> str:
    """
    Read the text content of a file using UTF-8 encoding.

    Parameters:
    	path (Path): The file path to read

    Returns:
    	str: The file's text content
    """
    return path.read_text(encoding="utf-8")


def test_robustness_adr_records_all_maintainer_decisions():
    adr = _read(ADR_PATH)

    for decision_id in range(1, 12):
        assert f"D{decision_id}" in adr
        assert f"Decision D{decision_id}:" in adr

    required_phrases = [
        "pinned TotalSegmentator release or commit",
        "multilabel NIfTI",
        "direct voxel-mask",
        "fail closed",
        "UUID workspace per run",
        "in-place pip install --upgrade",
        "runtime capability probe",
        "Horos and OsiriX",
        "research/non-diagnostic",
        "Slicer terminology",
        "release quality gate",
    ]
    for phrase in required_phrases:
        assert phrase in adr


def test_release_checklist_links_status_to_evidence_and_dependent_issues():
    checklist = _read(CHECKLIST_PATH)

    for issue_number in range(14, 29):
        assert f"#{issue_number}" in checklist

    required_sections = [
        "Supported Matrix",
        "Automated Evidence",
        "Host Smoke Evidence",
        "Certification Status",
        "Release Sign-Off",
    ]
    for section in required_sections:
        assert f"## {section}" in checklist


def test_readme_points_to_robustness_adr_and_release_gate():
    readme = _read(README_PATH)

    assert "research/non-diagnostic" in readme
    assert "docs/adr/0001-slicer-parity-robustness-and-clinical-boundary.md" in readme
    assert "docs/release/robustness-release-checklist.md" in readme


def test_issue_13_plan_uses_sequential_heading_levels():
    plan = _read(PLAN_PATH)

    assert "### Task 1: Documentation Regression Test" not in plan
    assert "### Task 2: ADR and Release Checklist" not in plan
    assert "## Task 1: Documentation Regression Test" in plan
    assert "## Task 2: ADR and Release Checklist" in plan
