#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

EXPECTED_TOOLS = {
    "read_document",
    "doc_search",
    "create_document",
    "update_document",
    "update_document_meta",
}


def upstream_url() -> str:
    base = os.environ["AFFINE_URL"].rstrip("/")
    workspace = os.environ["AFFINE_WORKSPACE_ID"].strip()
    return f"{base}/api/workspaces/{workspace}/mcp/"


def upstream_token() -> str:
    return os.environ["AFFINE_MCP_TOKEN"].strip()


def call_upstream(message: dict) -> dict:
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        upstream_url(),
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer " + upstream_token(),
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = {"message": raw or f"HTTP {exc.code}"}
        return {
            "jsonrpc": "2.0",
            "id": message.get("id"),
            "error": {
                "code": -32000,
                "message": "AFFiNE upstream request failed",
                "data": {"status": exc.code, "upstream": data},
            },
        }
    except Exception as exc:
        return {
            "jsonrpc": "2.0",
            "id": message.get("id"),
            "error": {"code": -32000, "message": f"AFFiNE upstream unavailable: {exc}"},
        }
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {
            "jsonrpc": "2.0",
            "id": message.get("id"),
            "error": {"code": -32000, "message": "AFFiNE returned invalid JSON"},
        }


def handle_message(message: dict) -> dict:
    method = message.get("method")
    if method in {"initialize", "ping", "tools/list", "tools/call"}:
        return call_upstream(message)
    if method == "notifications/initialized":
        return {"jsonrpc": "2.0", "id": message.get("id"), "result": {}}
    return {
        "jsonrpc": "2.0",
        "id": message.get("id"),
        "error": {"code": -32601, "message": "Method not found"},
    }


def validate_upstream() -> tuple[bool, set[str], dict]:
    response = call_upstream({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
    tools = (response.get("result") or {}).get("tools") or []
    names = {str(tool.get("name", "")) for tool in tools}
    return EXPECTED_TOOLS.issubset(names), names, response
