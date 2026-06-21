from __future__ import annotations

import json
from pathlib import Path
from typing import Any


BRIDGE_VERSION = "0.1.0"
BRIDGE_SCHEMA_VERSION = 1


class BridgeSchemaError(ValueError):
    """Raised when a bridge request does not match the bundled schema."""


def validate_request_schema(payload: dict[str, Any]) -> None:
    """
    Validate that an incoming bridge request has the expected schema version.
    
    Raises:
        BridgeSchemaError: If the request's schema_version does not match BRIDGE_SCHEMA_VERSION.
    """
    schema_version = payload.get("schema_version")
    if schema_version != BRIDGE_SCHEMA_VERSION:
        raise BridgeSchemaError(
            "Bridge request schema version {} does not match expected version {}.".format(
                schema_version,
                BRIDGE_SCHEMA_VERSION,
            )
        )


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    """
    Atomically write a dictionary as JSON to a file.
    
    Parameters:
    	path (Path): The file path to write to
    	payload (dict): The dictionary to serialize as JSON
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
    tmp_path.replace(path)


def success_result(stage: str, **payload: Any) -> dict[str, Any]:
    """
    Construct a success response for the bridge protocol.
    
    Parameters:
        stage (str): The processing stage for this response.
        **payload (Any): Additional fields to include in the response.
    
    Returns:
        dict[str, Any]: Response dictionary with schema version, bridge version, stage, status "ok", and any additional payload.
    """
    result: dict[str, Any] = {
        "schema_version": BRIDGE_SCHEMA_VERSION,
        "bridge_version": BRIDGE_VERSION,
        "stage": stage,
        "status": "ok",
        "error_code": None,
        "message": None,
    }
    result.update(payload)
    return result


def error_result(stage: str, error_code: str, message: str) -> dict[str, Any]:
    """
    Construct an error response with the given stage, error code, and message.
    
    Parameters:
    	stage (str): The stage identifier where the error occurred
    	error_code (str): The error code
    	message (str): The error message
    
    Returns:
    	dict[str, Any]: A dictionary with the schema and bridge versions, stage, error status, error code, and message.
    """
    return {
        "schema_version": BRIDGE_SCHEMA_VERSION,
        "bridge_version": BRIDGE_VERSION,
        "stage": stage,
        "status": "error",
        "error_code": error_code,
        "message": message,
    }
