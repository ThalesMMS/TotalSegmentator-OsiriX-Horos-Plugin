# Installed backend upgrade: TotalSegmentator 2.18.0

## Scope and provenance

This change upgrades the **installed inference distribution** from 2.11.0 to
**2.18.0**, released on 2026-08-12 and checked on 2026-09-07. Both Horos and OsiriX
build configurations already package `TotalSegmentatorEnvironmentLock.json` and
`TotalSegmentatorTaskCapabilities.json`; their native bridge continues to execute
the pinned distribution, not the repository's reference-only source tree.

The environment lock identifier, backend version, exact package requirement and
weights provenance are updated together. Other existing package pins, the Python
3.11–3.12 range and the pinned dcm2niix artifact are unchanged. This is **not** a
complete transitive-dependency refresh or a replacement of the native plugin.

Reviewed upstream sources:

- [PyPI release and artifact hashes](https://pypi.org/project/TotalSegmentator/2.18.0/)
- [Immutable release commit](https://github.com/wasserth/TotalSegmentator/commit/184fa4765456492b2ab81a981cc387465906b003)
- [Release changelog](https://github.com/wasserth/TotalSegmentator/blob/184fa4765456492b2ab81a981cc387465906b003/CHANGELOG.md)
- [Task registry](https://github.com/wasserth/TotalSegmentator/blob/184fa4765456492b2ab81a981cc387465906b003/totalsegmentator/registry.py)
- [Task configurations and model constraints](https://github.com/wasserth/TotalSegmentator/blob/184fa4765456492b2ab81a981cc387465906b003/totalsegmentator/map_tasks_config.py)

`tests/fixtures/totalsegmentator-2.18.0-contract.json` records the release commit,
reviewed task metadata, exclusions, six upstream Git blob identities and the wheel
SHA-256 reported by PyPI. The upstream project is Apache-2.0 licensed. The wheel
hash is provenance, **not** a claim that this PR downloaded/verified the wheel or
adds pip hash enforcement. Git blob SHA-1 values identify reviewed source files;
they are not used as package-download security hashes.

Do not substitute the moving upstream `master` branch for this release: it can
contain changes even while `setup.py` still declares 2.18.0. Do not replace all
weight URLs with the newest release tag. Model weights have independent release
versions; the installed backend selects the correct dataset and weight release.
The `v3.0.0-weights` release was marked **prerelease** on 2026-09-07, so this change
does not switch the default task to `total_v3`.

## Native task integration

The picker now exposes **45 tasks** (38 existing plus seven additions), using its
existing manifest-driven implementation. New entries are:

| Task | Input | Notes |
| --- | --- | --- |
| `vertebrae_pp` | CT | Upstream vertebrae PP label set |
| `vertebrae_pp_refined` | CT | Additional vertebral-body refinement pass |
| `liver_lesions` | CT | Liver-lesion candidates |
| `liver_lesions_mr` | MR | Liver-lesion candidates |
| `trunk_cavities` | CT | Abdominal/thoracic cavities, pericardium and mediastinum |
| `brain_aneurysm` | TOF MR angiography | Not a CT model or a general-purpose MR task |
| `pulmonary_artery_landmarks` | CT | License required; segmentation only, not the separate report command |

The replacement `lung_vessels` model uses canonical multilabel NIfTI output and
separates arteries, veins, airways and airway walls. `vertebrae_body` no longer
requests a license, matching the new upstream category. CT/MR task identifiers
follow the new registry, including the separate `_mr` identifier for thigh and
shoulder muscles. The `total` description now reflects its 117-class label set.

Eight upstream choices are deliberately not exposed:

- `total_v3`: prerelease weights, requiring separate evaluation.
- `lung_vessels_LEGACY`, `coronary_arteries_LEGACY`: deprecated models.
- `test`, `total_highres_test`: internal/experimental tasks.
- `renal_arteries`, `aorta_annulus`, `aortic_dissection`: upstream explicitly says
  these models expect already-cropped input from the aorta-report pipeline. The
  plugin exports a complete active series and does not implement that pipeline.

The bridge retains NIfTI as the canonical output, source-series identity checks,
voxel geometry validation, installed-runtime class maps and the existing
terminology fallback. This change does not invent terminology codes for newly
introduced labels. Review their displayed names/colors in the host acceptance
checks. RT-Struct remains disabled by default and remains an optional/required
*derived* interoperability artifact, not the source of brush ROIs.

Upstream 2.12 changed DICOM output paths from directories to filenames. This PR
does not route canonical inference through that output mode. Upstream 2.18 also
fixes a DICOM export mirroring case; this does not replace the plugin's own
geometry checks or constitute validation of all orientations. The backend's newer
resampling default is inherited; identical voxel predictions to 2.11 are not
promised. No low-resolution-output or report-generation option is enabled by
default.

## Verification commands

Run these from a full checkout:

```bash
python tools/validate_backend_upgrade.py
python -m pytest -q tests/test_backend_upgrade_contract.py tests/test_plugin_capability_manifest.py
```

The default validator checks the reviewed contract and the two bundle manifests;
it does not claim that a backend is installed. To audit an actual plugin runtime:

```bash
PYTHON="$HOME/Library/Application Support/TotalSegmentatorHorosPlugin/PythonEnvironment/bin/python"
"$PYTHON" tools/validate_backend_upgrade.py --installed
"$PYTHON" -m pip check
```

The installed audit uses `python -I` in an empty temporary working directory. It
checks the exact required package versions, optional package versions when
present, the Python version range, actual distribution/module resolution and the
six reviewed upstream source identities. It imports neither the engine nor torch
and downloads no weights. Missing dependencies or a stale/shadowed backend cause a
nonzero exit, not a misleading success. This is still not a scientific-library
import test, a wheel-availability resolver, a device probe or an inference test.

### Checks executed while preparing this change

The changed Python files and JSON resources were materialized in a **partial
checkout**, in a Linux/Python 3.13.5 environment without TotalSegmentator, nibabel,
pydicom, macOS, Xcode or a host application. Python 3.13 was used only to execute
stdlib packaging tests; it is not added to the plugin's supported runtime range.

```bash
python tools/validate_backend_upgrade.py
python -m pytest -q tests/test_backend_upgrade_contract.py tests/test_plugin_capability_manifest.py -k 'not swift'
python -m compileall -q tools/validate_backend_upgrade.py tests/test_backend_upgrade_contract.py tests/test_plugin_capability_manifest.py
```

Result: **39 passed, 3 deselected**. The three existing Swift source-inspection
tests remain in the suite, unchanged in purpose, but were not run because the
native source files were not materialized in that partial checkout. The installed
audit was also invoked as a negative check: it exited 1 and correctly reported
that TotalSegmentator was not installed. Full dependency resolution, scientific
imports, installed-release positive validation, model inference, native
compilation, signing and Horos/OsiriX end-to-end validation were **not performed**.
No GitHub Actions workflow or required CI check is added.

## Build, deployment and acceptance

Build fresh bundles on macOS using the existing workflow:

```bash
./build.sh both --sign
```

The bundles already checked into `Releases/` are historical builds. They were not
rebuilt or modified in place; changing a signed bundle's resource files would not
be a substitute for a proper build/sign/install cycle. Building this PR is needed
to obtain a plugin bundle that ships the new lock and task manifest.

Quit both hosts before replacing a bundle. Preserve the old bundle and managed
virtual environment for rollback. On the next setup, the new lock drives the
existing managed-environment installation/health-check flow. Do not use
`pip install .` from this repository as an upgrade: root `setup.py` and
`totalsegmentator/` still describe the historical reference backend. Keep existing
weights, configuration and provenance/run records; do not clear them merely to
change the package version.

**Existing Intel limitation:** the unchanged PyTorch 2.8 / torchvision 0.23 pins
must not be read as a promise of turnkey macOS x86_64 installation. PyTorch
[stopped publishing official macOS x86_64 binaries starting with 2.3](https://dev-discuss.pytorch.org/t/pytorch-macos-x86-builds-deprecation-starting-january-2024/1690).
This PR does not add an Intel-specific dependency stack, custom wheels or CPU-only
fallback package set. Validate wheel resolution on the intended architecture;
Apple Silicon and any separately provisioned Intel environment require their own
acceptance evidence. Existing architecture declarations are not expanded here.

Before merging for deployment, complete these local acceptance checks:

- [ ] Resolve/install the lock on the intended Mac; run the installed audit,
  `pip check`, scientific-library imports and the existing runtime device probe.
- [ ] Build/sign both host bundles and confirm their packaged resources contain
  `2.18.0` and the new lock identifier, without modifying historical releases.
- [ ] In Horos and OsiriX, run representative CT `total` and MR `total_mr` studies;
  verify nonempty NIfTI, label-map/provenance versions, source identity and brush
  alignment on axial, sagittal, coronal and oblique series.
- [ ] Exercise supported fast/fastest modes and ROI subsets, the replacement
  `lung_vessels` model, new task labels, license gating, cancellation and failure
  handling. Test `brain_aneurysm` only with an appropriate TOF MR input.
- [ ] Exercise optional/required RT-Struct, including the axial orientation case
  fixed upstream. Review outputs against the source images before any clinical
  use. Do not equate passing metadata tests with clinical validation.

This is an implementation and review artifact, not a newly certified or
clinically validated plugin release. No merge, deployment or release publication
is performed by this change.
