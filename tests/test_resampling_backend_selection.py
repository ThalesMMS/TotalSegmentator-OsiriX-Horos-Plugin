#
# test_resampling_backend_selection.py
#
# Unit tests for resampling backend selection and user-facing one-time hints.
#

import os
import sys
import types

import numpy as np

# Ensure repository root is on sys.path so 'totalsegmentator' can be imported
# when tests are executed from other working directories.
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


def _make_nifti(shape=(8, 8, 8), spacing=(2.0, 2.0, 2.0)):
    data = np.zeros(shape, dtype=np.float32)
    affine = np.diag([spacing[0], spacing[1], spacing[2], 1.0])
    return _FakeNifti(data, affine, spacing)


def _patch_nib_return(monkeypatch, module_under_test, *, data_shape):
    # change_spacing returns nib.Nifti1Image(...). We don't want to require nibabel
    # to be installed in the unit test environment, so we stub it.
    monkeypatch.setattr(
        module_under_test,
        "nib",
        types.SimpleNamespace(Nifti1Image=lambda data, affine: {"data": data, "affine": affine}),
        raising=True,
    )


def test_cuda_cucim_uses_gpu_backend(monkeypatch, capsys):
    # Stub heavy optional deps before importing the module under test.
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

    _patch_nib_return(monkeypatch, r, data_shape=(4, 4, 4))

    monkeypatch.setattr(r, "cupy_available", True, raising=False)
    monkeypatch.setattr(r, "cucim_available", True, raising=False)
    monkeypatch.setattr(r, "_cuda_available", lambda: True, raising=False)

    called = {"gpu": 0, "cpu": 0}

    def _gpu(img, **kwargs):
        called["gpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    def _cpu(img, **kwargs):
        called["cpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img_cucim", _gpu, raising=True)
    monkeypatch.setattr(r, "resample_img", _cpu, raising=True)

    img = _make_nifti(spacing=(2.0, 2.0, 2.0))
    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    assert "Using GPU-accelerated resampling backend: cuCIM" in out
    assert called["gpu"] == 1
    assert called["cpu"] == 0


def test_cuda_missing_cucim_emits_hint_and_uses_cpu(monkeypatch, capsys):
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

    _patch_nib_return(monkeypatch, r, data_shape=(4, 4, 4))

    monkeypatch.setattr(r, "cupy_available", True, raising=False)
    monkeypatch.setattr(r, "cucim_available", False, raising=False)

    # Provide a fake cupy module that reports CUDA device(s) present
    class _FakeCudaRuntime:
        @staticmethod
        def getDeviceCount():
            return 1

    fake_cupy = types.SimpleNamespace(
        cuda=types.SimpleNamespace(runtime=_FakeCudaRuntime())
    )

    monkeypatch.setitem(__import__("sys").modules, "cupy", fake_cupy)

    called = {"cpu": 0}

    def _cpu(img, **kwargs):
        called["cpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img", _cpu, raising=True)

    img = _make_nifti(spacing=(2.0, 2.0, 2.0))
    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    assert (
        "[TotalSegmentator] CUDA detected, but GPU resampling dependencies are missing. "
        "To enable GPU-accelerated resampling, install: pip install cucim cupy-cuda12x"
    ) in out
    assert called["cpu"] == 1


def test_cuda_cucim_skips_gpu_for_4d_input(monkeypatch, capsys):
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

    _patch_nib_return(monkeypatch, r, data_shape=(4, 4, 4, 2))

    monkeypatch.setattr(r, "cupy_available", True, raising=False)
    monkeypatch.setattr(r, "cucim_available", True, raising=False)
    monkeypatch.setattr(r, "_cuda_available", lambda: True, raising=False)

    called = {"gpu": 0, "cpu": 0}

    def _gpu(img, **kwargs):
        called["gpu"] += 1
        return np.zeros((4, 4, 4, 2), dtype=np.float32)

    def _cpu(img, **kwargs):
        called["cpu"] += 1
        return np.zeros((4, 4, 4, 2), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img_cucim", _gpu, raising=True)
    monkeypatch.setattr(r, "resample_img", _cpu, raising=True)

    img = _make_nifti(shape=(8, 8, 8, 2), spacing=(2.0, 2.0, 2.0, 1.0))
    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    assert "GPU resampling skipped for 4D input" in out
    assert "Using GPU-accelerated resampling backend" not in out
    assert called["gpu"] == 0
    assert called["cpu"] == 1


def test_mps_available_logs_note_and_uses_cpu(monkeypatch, capsys):
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

    _patch_nib_return(monkeypatch, r, data_shape=(4, 4, 4))

    monkeypatch.setattr(r, "cupy_available", False, raising=False)
    monkeypatch.setattr(r, "cucim_available", False, raising=False)

    # Fake torch with MPS available but no CUDA
    fake_torch = types.SimpleNamespace(
        backends=types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: True)),
        cuda=types.SimpleNamespace(is_available=lambda: False),
    )
    monkeypatch.setitem(__import__("sys").modules, "torch", fake_torch)

    called = {"cpu": 0}

    def _cpu(img, **kwargs):
        called["cpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img", _cpu, raising=True)

    img = _make_nifti(spacing=(2.0, 2.0, 2.0))
    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    assert "MPS device detected" in out
    assert called["cpu"] == 1


def test_cpu_fallback_uses_cpu_when_no_cuda(monkeypatch, capsys):
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

    _patch_nib_return(monkeypatch, r, data_shape=(4, 4, 4))

    monkeypatch.setattr(r, "cupy_available", False, raising=False)
    monkeypatch.setattr(r, "cucim_available", False, raising=False)
    monkeypatch.setattr(r, "_cuda_available", lambda: False, raising=False)

    called = {"gpu": 0, "cpu": 0}

    def _gpu(img, **kwargs):
        called["gpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    def _cpu(img, **kwargs):
        called["cpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img_cucim", _gpu, raising=True)
    monkeypatch.setattr(r, "resample_img", _cpu, raising=True)

    img = _make_nifti(spacing=(2.0, 2.0, 2.0))
    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    assert "Using GPU-accelerated resampling backend" not in out
    assert called["gpu"] == 0
    assert called["cpu"] == 1


def test_gpu_exception_falls_back_to_cpu(monkeypatch, capsys):
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

    _patch_nib_return(monkeypatch, r, data_shape=(4, 4, 4))

    monkeypatch.setattr(r, "cupy_available", True, raising=False)
    monkeypatch.setattr(r, "cucim_available", True, raising=False)
    monkeypatch.setattr(r, "_cuda_available", lambda: True, raising=False)

    called = {"gpu": 0, "cpu": 0}

    def _gpu(img, **kwargs):
        called["gpu"] += 1
        raise RuntimeError("boom")

    def _cpu(img, **kwargs):
        called["cpu"] += 1
        return np.zeros((4, 4, 4), dtype=np.float32)

    monkeypatch.setattr(r, "resample_img_cucim", _gpu, raising=True)
    monkeypatch.setattr(r, "resample_img", _cpu, raising=True)

    img = _make_nifti(spacing=(2.0, 2.0, 2.0))
    _ = r.change_spacing(img, new_spacing=1.0, nnunet_resample=False)

    out = capsys.readouterr().out
    # The implementation intentionally prints at most one informational hint per run.
    # In the error case, we validate the functional fallback (GPU attempted, then CPU called).
    assert "Using GPU-accelerated resampling backend" in out
    assert called["gpu"] == 1
    assert called["cpu"] == 1
