"""Internal bridge package for the TotalSegmentator Horos/OsiriX plugin."""

from .schemas import BRIDGE_SCHEMA_VERSION, BRIDGE_VERSION

__version__ = BRIDGE_VERSION

__all__ = ["BRIDGE_SCHEMA_VERSION", "BRIDGE_VERSION", "__version__"]
