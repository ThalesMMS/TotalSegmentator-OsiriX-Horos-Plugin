# TotalSegmentator OsiriX/Horos Plugin

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)
![Host app Horos or OsiriX](https://img.shields.io/badge/Host-Horos%20%2F%20OsiriX-6f42c1.svg)
![Python 3.9+ or 3.13](https://img.shields.io/badge/Python-3.9%2B%20or%203.13-3776AB.svg)
![License Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-green.svg)

---

## Overview

This private development repository packages the [TotalSegmentator](https://github.com/wasserth/TotalSegmentator) pipeline as a macOS Horos/OsiriX plugin for DICOM studies. It exports the active CT or MR series, runs the Python TotalSegmentator and nnUNet segmentation flow, then re-imports the generated results as volumetric brush/tPlain ROIs in the current viewer. RT-Struct objects are still generated and imported as database artifacts for interoperability, but the displayed ROIs are built directly from the voxel masks.

The repository still ships the upstream `totalsegmentator/` sources because the plugin reuses internal scripts and helpers, but the main purpose here is the native Swift plugin, the host-app bridge, and the packaging flow for Horos and OsiriX.

---

## Current Status

- ✅ End-to-end export → segmentation → import flow works for 2D CT/MR series.
- ✅ Isolated Python environment bootstrapped under `~/Library/Application Support/TotalSegmentatorHorosPlugin`.
- ✅ Volumetric brush/tPlain ROIs are generated from NIfTI voxel masks and applied to the active viewer (Horos ≥ 4.0.1 required).
- ✅ RT-Struct files are still generated/imported for interoperability and fallback.
- ⚠️ Configuration UI is minimal; advanced class selection is still limited.
- ⚠️ Horos must be running in English to avoid localization issues in menus.
- 🚧 Automated tests and formal distribution (installer `.pkg`) are not yet available.

---

## Downloadable Builds

Need a prebuilt bundle? The checked-in packaged artifacts currently present in `Releases/` are:

- [Horos debug package (2026-01-08)](Releases/TotalSegmentatorPlugin%20Horos%202026%2001%2008.osirixplugin.zip)
- [OsiriX debug package (2026-01-08)](Releases/TotalSegmentatorPlugin%20OsiriX%202026%2001%2008.osirixplugin.zip)

Unzip the package first, then copy the extracted `.osirixplugin` bundle into the matching plugin folder:

- Horos: `~/Library/Application Support/Horos/Plugins/`
- OsiriX: `~/Library/Application Support/OsiriX/Plugins/`

After copying, run `codesign --force --deep --sign - "/path/to/plugin.osirixplugin"` if you need an ad-hoc local signature, then relaunch the host app. On first launch the plugin provisions its Python environment automatically; no additional files are required beyond Horos or OsiriX, a compatible macOS version, and an internet connection to fetch TotalSegmentator weights when needed.

---

## Screenshots

![Segmentation example 1](Screenshots/screenshot1.png)

![Segmentation example 2](Screenshots/screenshot2.png)

---

## Requirements

- macOS 14 or newer (validated on macOS 15.0.1).
- Horos 4.0.1 (build 20231016) or compatible OsiriX-based host.
- Xcode 15/16+ with Swift 5 toolchain.
- Python 3.9 or 3.13 available (the plugin provisions its own virtualenv).
- Optional GPU; CPU mode works but is faster with `--fast`.
- Optional **GPU-accelerated resampling** (pre-processing) on Linux/Windows only when **CUDA** is available and the Python environment includes `cucim` + `cupy`.
  - When available, TotalSegmentator will automatically use cuCIM (CUDA) for spacing changes.
  - macOS/Apple Silicon is not supported for this path because CuPy/cuCIM wheels are not available; Apple Silicon **MPS** can run inference on GPU, but resampling falls back to CPU.

---

## Quick Build & Install

1. **Clone the repository**
   ```bash
   git clone https://github.com/ThalesMMS/TotalSegmentator-OsiriX-Horos-Plugin-dev.git
   cd TotalSegmentator-OsiriX-Horos-Plugin-dev
   ```

2. **Confirm the Xcode project is visible**
   ```bash
   xcodebuild -list -project MyOsiriXPluginFolder-Swift/TotalSegmentatorHorosPlugin.xcodeproj
   ```

3. **Build with the helper script**
   ```bash
   ./build.sh horos --sign
   # or: ./build.sh both --sign
   ```

4. **Install into Horos**
   ```bash
   PLUGIN_DST="$HOME/Library/Application Support/Horos/Plugins/"
   mkdir -p "$PLUGIN_DST"

   rm -rf "$PLUGIN_DST"/TotalSegmentatorPlugin*.osirixplugin
   cp -R Releases/Horos/*.osirixplugin "$PLUGIN_DST"
   ```

   For OsiriX builds, use `./build.sh osirix --sign` and copy from `Releases/Osirix/` into `~/Library/Application Support/OsiriX/Plugins/`.

5. **Launch Horos** and confirm the entry under `Plugins ▸ Plugin Manager ▸ TotalSegmentator`.

---

## Using the Plugin in Horos

1. Open a study and ensure the active series is 2D (CT or MR).
2. Choose `Plugins ▸ TotalSegmentator ▸ Run TotalSegmentator`.
3. Adjust the basic settings (task, device, output) and press **Run**.
   The task picker groups targets by anatomy and shows helper text for the selected task. Use the **Fast mode** checkbox when you want the TotalSegmentator `--fast` path; the task picker only selects the anatomical task. The plugin internally requests NIfTI output so it can preserve the voxel masks as volumetric ROIs, even when the UI or additional arguments request DICOM output.
4. Watch the progress window. On success the plugin:
   - imports the generated DICOM/RT-Struct artifacts,
   - creates a per-slice volumetric ROI manifest from the NIfTI masks,
   - inserts the masks into Horos as brush/tPlain ROIs across the source slices.

> **Tip:** to transfer RT-Struct to another workstation, export the newly imported objects from Horos after the segmentation finishes. For in-Horos volumetry, use the generated brush ROIs in the original series.

---

## Troubleshooting

| Symptom | Common Cause | Action |
| --- | --- | --- |
| Plugin missing from menu | Bundle not copied/signed correctly | Re-run installation steps and check permissions |
| “rt_utils” missing error | Python dependency absent | Execute `~/Library/.../PythonEnvironment/bin/pip install rt_utils` |
| GPU resampling not used | `change_spacing()` is silent in CPU-only/no-CUDA mode unless a GPU backend was explicitly selected. Messages are emitted for GPU selection, GPU failure, CUDA-with-missing-cuCIM (`[TotalSegmentator] CUDA detected, but GPU resampling dependencies are missing...`), or MPS detection. | Install `cucim`/`cupy` only when using GPU resampling. If CUDA is present and you see cuCIM/cupy import errors, recreate the venv with a matching `cupy-cudaXX` wheel; otherwise keep CPU resampling. |
| cuCIM/cupy import errors | CUDA toolkit / wheel mismatch | Use a matching `cupy-cudaXX` wheel for your CUDA version; recreate the venv if needed |
| No volumetric ROIs applied | Active viewer mismatch, unreadable volumetric ROI manifest, or DICOM/NIfTI geometry mismatch | Keep the original 2D series open, inspect `Window ▸ Logs ▸ TotalSegmentator`, and verify the progress log reports generated volumetric brush ROI slices |
| Only RT-Struct contour ROIs appear | Volumetric import failed and the plugin fell back to RT-Struct conversion | Inspect the progress log for `Volumetric ROI import warning`; check that `pydicom`, `nibabel`, and TotalSegmentator are available in the plugin Python environment |
| Python env corrupted | Interrupted during virtualenv setup | Delete `~/Library/Application Support/TotalSegmentatorHorosPlugin` and run the plugin again |

### Optional: enable CUDA GPU-accelerated resampling

Linux/Windows only — macOS/Apple Silicon not supported (no CuPy/cuCIM wheels).

If you have an NVIDIA CUDA-capable GPU and want faster spacing changes during preprocessing, install the optional dependencies into the plugin-managed virtualenv:

```bash
"$HOME/Library/Application Support/TotalSegmentatorHorosPlugin/PythonEnvironment/bin/pip" install cucim cupy-cuda12x
```

Notes:
- If your system uses a different CUDA major version, replace `cupy-cuda12x` accordingly.

---

## Development Notes

- Core plugin logic: `MyOsiriXPluginFolder-Swift/Plugin.swift`.
- Interface files (XIB): `Settings.xib`, `RunSegmentationWindowController.xib`.
- Python helpers (bridge, converters): generated on the fly in the plugin’s temporary workspace.
- GPU resampling backend selection (CUDA/cuCIM/CuPy): see [DEV_NOTES.md](DEV_NOTES.md).

### Coding Guidelines
- Swift 5 with `swift-format` where available.
- Comments only for non-obvious blocks; emphasize readable implementation.
- Avoid adding extra bundled dependencies—reuse Horos frameworks whenever possible.

---

## Repository Layout

```
MyOsiriXPluginFolder-Swift/     # Horos plugin sources
Screenshots/                    # Images used in this README
totalsegmentator/               # Original TotalSegmentator codebase (reference)
resources/                      # Artwork and diagrams inherited from upstream
tests/                          # TotalSegmentator test suite (not plugin-specific yet)
```

---

## Related ThalesMMS Repositories

- [`ThalesMMS/Python-Runner-OsiriX-Horos-Plugin-dev`](https://github.com/ThalesMMS/Python-Runner-OsiriX-Horos-Plugin-dev), a minimal Horos/OsiriX plugin template that runs a bundled Python script.
- [`ThalesMMS/dcmtag2table-OsiriX-Horos-Plugin-dev`](https://github.com/ThalesMMS/dcmtag2table-OsiriX-Horos-Plugin-dev), a sibling plugin that exports DICOM metadata from Horos or OsiriX to CSV.
- [`ThalesMMS/DICOM-Decoder-dev`](https://github.com/ThalesMMS/DICOM-Decoder-dev), a Swift DICOM decoder toolkit for viewers, PACS clients, and related imaging tools.

---

## Roadmap

- [ ] Advanced preferences panel with class selection via TotalSegmentator API.
- [ ] Support volumetric multi-frame series and MPR viewers.
- [ ] Automate packaging as `.pkg` with pre-provisioned Python environment.
- [ ] Add smoke-test harness that triggers the plugin headlessly.

---

## Credits & License

- **Author**: Thales Matheus Mendonça Santos — October 2025.
- **TotalSegmentator**: University Hospital Basel, Apache 2.0.
- **Horos**: open-source project derived from OsiriX.
- **Horos Plugin Code**: (c) 2025, TotalSegmentator Horos Plugin community. Additional code follows Apache 2.0 unless otherwise noted.
- **Acknowledgements**: thanks to the OsiriX team for the OsiriX plugin template that kick-started this project.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

```
   http://www.apache.org/licenses/LICENSE-2.0
```

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

Contributions are welcome! Please open issues or pull requests with details about your test environment (macOS version, Horos build, Python version).
