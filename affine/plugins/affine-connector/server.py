#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

SERVER_NAME = "bratonien-affine"
SERVER_VERSION = "1.1.0"
DEFAULT_PROTOCOL_VERSION = "2025-03-26"
SUPPORTED_PROTOCOL_VERSIONS = {
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    "2024-10-07",
}

# Baseline tools required for the Bratonien READ_WRITE deployment. tools/list
# and tools/call are still forwarded dynamically, so every additional native
# AFFiNE MCP tool is exposed automatically without a connector rebuild.
REQUIRED_TOOLS = {
    "read_document",
    "doc_search",
    "create_document",
    "update_document",
    "update_document_meta",
    "trash_document",
    "restore_document",
    "delete_document",
}


class AffineError(Exception):
    pass


def upstream_url() -> str:
    base = os.environ.get("AFFINE_URL", "").strip().rstrip("/")
    workspace = os.environ.get("AFFINE_WORKSPACE_ID", "").strip()
    if not base.startswith("https://"):
        raise AffineError("AFFINE_URL must use HTTPS.")
    if not workspace:
        raise AffineError("AFFINE_WORKSPACE_ID is not configured.")
    return f"{base}/api/workspaces/{workspace}/mcp/"


def upstream_token() -> str:
    token = os.environ.get("AFFINE_MCP_TOKEN", "").strip()
    if not token:
        raise AffineError("AFFINE_MCP_TOKEN is not configured.")
    if not token.startswith("aff_mcp_v1."):
        raise AffineError("AFFINE_MCP_TOKEN has an unexpected format.")
    return token


def error_response(request_id: Any, code: int, message: str, data: Optional[dict] = None) -> dict:
    error: Dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def call_upstream(message: dict) -> dict:
    try:
        url = upstream_url()
        token = upstream_token()
    except AffineError as exc:
        return error_response(message.get("id"), -32000, str(exc))

    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            upstream = json.loads(raw)
        except json.JSONDecodeError:
            upstream = {"message": raw or f"HTTP {exc.code}"}
        return error_response(
            message.get("id"),
            -32000,
            "AFFiNE upstream request failed",
            {"status": exc.code, "upstream": upstream},
        )
    except Exception as exc:
        return error_response(message.get("id"), -32000, f"AFFiNE upstream unavailable: {exc}")

    if not raw:
        return {"jsonrpc": "2.0", "id": message.get("id"), "result": {}}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return error_response(message.get("id"), -32000, "AFFiNE returned invalid JSON")
    if not isinstance(data, dict):
        return error_response(message.get("id"), -32000, "AFFiNE returned an invalid JSON-RPC response")
    return data


def handle_message(message: dict) -> Optional[dict]:
    request_id = message.get("id")
    method = message.get("method")
    is_notification = "id" not in message

    if message.get("jsonrpc") != "2.0" or not isinstance(method, str):
        return error_response(None, -32600, "Invalid Request")

    if method == "initialize":
        if is_notification:
            return None
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        requested = params.get("protocolVersion") if isinstance(params.get("protocolVersion"), str) else DEFAULT_PROTOCOL_VERSION
        version = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else DEFAULT_PROTOCOL_VERSION
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": version,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }

    if method in {"notifications/initialized", "ping"}:
        if is_notification:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}

    if method == "tools/list":
        if is_notification:
            return None
        return call_upstream({"jsonrpc": "2.0", "id": request_id, "method": "tools/list", "params": {}})

    if method == "tools/call":
        params = message.get("params")
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return error_response(request_id, -32602, "Invalid params")
        if is_notification:
            return None
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            return error_response(request_id, -32602, "Invalid params")
        return call_upstream({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": params["name"], "arguments": arguments},
        })

    if is_notification:
        return None
    return error_response(request_id, -32601, "Method not found")


def validate_upstream() -> tuple[bool, set[str], dict]:
    response = call_upstream({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
    tools = (response.get("result") or {}).get("tools") or []
    names = {str(tool.get("name", "")) for tool in tools if isinstance(tool, dict)}
    return REQUIRED_TOOLS.issubset(names), names, response
