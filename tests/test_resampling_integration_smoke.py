#
# test_resampling_integration_smoke.py
#
# Lightweight integration-style smoke test for change_spacing that:
#  - executes the full code path (without CUDA hardware)
#  - asserts the backend-selection log line is emitted when CUDA+cucim are "available"
#
# This test avoids requiring nibabel/scipy/cupy/cucim by stubbing them.
#

import os
import sys
import types

import numpy as np


_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)


class _FakeHeader:
    def __init__(self, zooms):
        self._zooms = tuple(zooms)

    def get_zooms(self):
        return self._zooms


class _FakeNifti:
    def __init__(self, data, affine, zooms):
        self._data = data
        self.affine = affine
        self.header = _FakeHeader(zooms)

    def get_fdata(self):
        return self._data


def test_change_spacing_smoke_emits_backend_log(monkeypatch, capsys):
    # Stub heavy optional deps before importing totalsegmentator.resampling
    monkeypatch.setitem(sys.modules, "nibabel", types.SimpleNamespace())
    monkeypatch.setitem(sys.modules, "scipy", types.SimpleNamespace(ndimage=types.SimpleNamespace()))
    monkeypatch.setitem(
        sys.modules,
        "joblib",
        types.SimpleNamespace(Parallel=lambda *a, **k: None, delayed=lambda f: f),
    )

    import importlib
    import totalsegmentator.resampling as r

    importlib.reload(r)

    # Provide nib.Nifti1Image stub so change_spacing can return a value.
    monkeypatch.setattr(
        r,
        "nib",
        types.SimpleNamespace(Nifti1Image=lambda data, affine: {"data": data, "affine": affine}),
        raising=True,
    )

    # Simulate CUDA+cucim present so the module prints the backend selection log.
    monkeypatch.setattr(r, "cupy_available", True, raising=False)
    monkeypatch.setattr(r, "cucim_available", True, raising=False)
    monkeypatch.setattr(r, "_cuda_available", lambda: True, raising=False)

    # Avoid importing/using actual cucim: intercept the GPU-resample function.
    def _gpu_resample_img_cucim(img, **kwargs):
        return np.zeros((4, 4, 4), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img_cucim", _gpu_resample_img_cucim, raising=True)

    data = np.zeros((8, 8, 8), dtype=np.float32)
    affine = np.diag([2.0, 2.0, 2.0, 1.0])
    img = _FakeNifti(data, affine, (2.0, 2.0, 2.0))

    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    assert "Using GPU-accelerated resampling backend: cuCIM" in out
