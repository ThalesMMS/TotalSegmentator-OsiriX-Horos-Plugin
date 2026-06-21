from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import re
import subprocess
import sys
import traceback
from typing import Any


PROBE_VERSION = "2026.06.runtime-capabilities.v1"
BACKEND_RECOGNIZED_DEVICE_VALUES = ["cpu", "gpu", "mps"]


def _available_memory_mb() -> int | None:
    """
    Detect approximate available system memory in MB.

    Returns:
        int | None: Available memory in MB, or None if detection failed or is unsupported.
    """
    if hasattr(os, "sysconf"):
        names = os.sysconf_names
        if "SC_AVPHYS_PAGES" in names and "SC_PAGE_SIZE" in names:
            try:
                pages = int(os.sysconf("SC_AVPHYS_PAGES"))
                page_size = int(os.sysconf("SC_PAGE_SIZE"))
                return int((pages * page_size) / (1024 * 1024))
            except (OSError, ValueError):
                pass
    if sys.platform == "darwin":
        try:
            output = subprocess.check_output(["/usr/bin/vm_stat"], text=True, timeout=2)
            page_size_match = re.search(r"page size of (\d+) bytes", output)
            page_size = int(page_size_match.group(1)) if page_size_match else 16_384
            page_counts = {}
            for line in output.splitlines():
                match = re.match(r"Pages (free|inactive|speculative):\s+([0-9.]+)", line)
                if match:
                    page_counts[match.group(1)] = int(match.group(2).replace(".", ""))
            available_pages = sum(page_counts.values())
            if available_pages > 0:
                return int((available_pages * page_size) / (1024 * 1024))
        except Exception:
            return None
    return None


def _import_status(module_names: list[str]) -> dict[str, bool]:
    """
    Determine which modules from a list can be imported.

    Parameters:
    	module_names (list[str]): Names of modules to check for importability.

    Returns:
    	dict[str, bool]: A dictionary mapping each module name to whether it can be imported.
    """
    return {name: importlib.util.find_spec(name) is not None for name in module_names}


def _device(value: str, available: bool, validated: bool, reason: str, **details: Any) -> dict[str, Any]:
    """
    Create a standardized device capability entry.

    Parameters:
    	details: Additional key-value pairs to include in the capability entry.

    Returns:
    	dict[str, Any]: Device capability dictionary with standard fields (value, available, validated, experimental, reason) plus any additional details.
    """
    payload: dict[str, Any] = {
        "value": value,
        "available": bool(available),
        "validated": bool(validated),
        "experimental": False,
        "reason": reason,
    }
    payload.update(details)
    return payload


def _cuda_device(torch_module: Any) -> dict[str, Any]:
    """
    Probe CUDA capability from a PyTorch module.

    Returns:
        dict[str, Any]: A device capability payload with fields `value`, `available`, `validated`,
        `experimental`, `reason`, and optional metadata including device name, count, compute
        capability, and usable memory in MB.
    """
    cuda = getattr(torch_module, "cuda", None)
    if cuda is None or not callable(getattr(cuda, "is_available", None)):
        return _device("gpu", False, False, "PyTorch CUDA runtime is unavailable.")

    try:
        if not cuda.is_available():
            return _device("gpu", False, False, "CUDA is not available in the pinned PyTorch runtime.")

        count = int(cuda.device_count())
        if count <= 0:
            return _device("gpu", False, False, "CUDA reported no devices.")

        name = str(cuda.get_device_name(0)) if callable(getattr(cuda, "get_device_name", None)) else "CUDA GPU"
        compute_capability = None
        if callable(getattr(cuda, "get_device_capability", None)):
            capability = cuda.get_device_capability(0)
            compute_capability = ".".join(str(part) for part in capability)

        usable_memory_mb = None
        if callable(getattr(cuda, "mem_get_info", None)):
            free_bytes, _total_bytes = cuda.mem_get_info()
            usable_memory_mb = int(free_bytes / (1024 * 1024))

        return _device(
            "gpu",
            True,
            True,
            "CUDA probe passed.",
            name=name,
            device_count=count,
            compute_capability=compute_capability,
            usable_memory_mb=usable_memory_mb,
        )
    except Exception as exc:
        return _device("gpu", False, False, "CUDA probe failed: {}".format(exc))


def _mps_device(torch_module: Any) -> dict[str, Any]:
    """
    Detects Apple MPS backend availability and functionality.

    Parameters:
    	torch_module (Any): The PyTorch module to probe.

    Returns:
    	dict[str, Any]: A device capability entry indicating MPS availability, validation status, and probe outcome.
    """
    backends = getattr(torch_module, "backends", None)
    mps = getattr(backends, "mps", None)
    if mps is None:
        return _device("mps", False, False, "PyTorch MPS backend is unavailable.")

    try:
        is_built = bool(mps.is_built()) if callable(getattr(mps, "is_built", None)) else True
        is_available = bool(mps.is_available()) if callable(getattr(mps, "is_available", None)) else False
        if not is_built or not is_available:
            return _device("mps", False, False, "MPS is not available in the pinned PyTorch runtime.")

        try:
            tensor = torch_module.tensor([1.0], device="mps")
            _ = (tensor + tensor).sum().item()
        except Exception as exc:
            return _device("mps", False, False, "MPS smoke test failed: {}".format(exc))

        try:
            layer = torch_module.nn.ConvTranspose3d(1, 1, kernel_size=2).to("mps")
            sample = torch_module.ones((1, 1, 4, 4, 4), device="mps")
            _ = layer(sample)
            synchronize = getattr(getattr(torch_module, "mps", None), "synchronize", None)
            if callable(synchronize):
                synchronize()
        except Exception as exc:
            return _device("mps", False, False, "MPS ConvTranspose3d probe failed: {}".format(exc))

        return _device("mps", True, True, "MPS smoke test passed, including ConvTranspose3d.")
    except Exception as exc:
        return _device("mps", False, False, "MPS probe failed: {}".format(exc))


def probe_runtime_capabilities(
    *,
    torch_module: Any | None = None,
    available_memory_mb: int | None = None,
    import_status: dict[str, bool] | None = None,
) -> dict[str, Any]:
    """
    Probe and return runtime capability information for the execution environment.

    Collects Python/system metadata (versions, architecture, executable path), PyTorch availability and version details, device capabilities (CPU, CUDA GPU, Apple MPS), optional resampling library availability (cucim, cupy), and available system memory.

    Parameters:
    	torch_module (Any | None): PyTorch module to probe; if not provided, attempts to import torch.
    	available_memory_mb (int | None): Available system memory in MB; if not provided, detects automatically.
    	import_status (dict[str, bool] | None): Module name to availability mapping; if not provided, checks cucim and cupy.

    Returns:
    	dict[str, Any]: Structured payload with schema_version, probe_version, python_version, python_executable, architecture, cpu_architecture, available_memory_mb, torch (version and cuda_version), backend_recognized_device_values, devices (list of device capability entries), resampling_backends (cucim and cupy availability), and failures (list of import errors, if any).
    """
    failures: list[str] = []
    if torch_module is None:
        try:
            import torch as torch_module  # type: ignore[no-redef]
        except Exception:
            failures.append("Unable to import torch:\n{}".format(traceback.format_exc()))
            torch_module = None

    torch_payload = {
        "version": getattr(torch_module, "__version__", None) if torch_module is not None else None,
        "cuda_version": getattr(getattr(torch_module, "version", None), "cuda", None) if torch_module is not None else None,
    }

    devices = [_device("cpu", True, True, "CPU execution is always available.")]
    if torch_module is None:
        devices.append(_device("gpu", False, False, "PyTorch is unavailable, so CUDA cannot be probed."))
        devices.append(_device("mps", False, False, "PyTorch is unavailable, so MPS cannot be probed."))
    else:
        devices.append(_cuda_device(torch_module))
        devices.append(_mps_device(torch_module))

    imports = import_status if import_status is not None else _import_status(["cucim", "cupy"])

    return {
        "schema_version": 1,
        "probe_version": PROBE_VERSION,
        "python_version": platform.python_version(),
        "python_executable": sys.executable,
        "architecture": platform.machine() or platform.processor() or "unknown",
        "cpu_architecture": platform.processor() or platform.machine() or "unknown",
        "available_memory_mb": available_memory_mb if available_memory_mb is not None else _available_memory_mb(),
        "torch": torch_payload,
        "backend_recognized_device_values": BACKEND_RECOGNIZED_DEVICE_VALUES,
        "devices": devices,
        "resampling_backends": {
            "cucim": bool(imports.get("cucim", False)),
            "cupy": bool(imports.get("cupy", False)),
        },
        "failures": failures,
    }


def main(argv: list[str] | None = None) -> int:
    """
    Probe runtime capabilities and output the result as JSON to stdout.

    Parameters:
    	argv (list[str] | None): Command-line arguments to parse. If `None`, uses default parsing. Supports `--pretty` to format JSON output.

    Returns:
    	int: Exit code (always `0`).
    """
    parser = argparse.ArgumentParser(description="Probe TotalSegmentator runtime capabilities")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    args = parser.parse_args(argv)

    payload = probe_runtime_capabilities()
    json.dump(payload, sys.stdout, indent=2 if args.pretty else None, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
