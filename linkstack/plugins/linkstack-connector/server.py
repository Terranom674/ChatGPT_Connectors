#!/usr/bin/env python3
"""MCP runtime for the Bratonien LinkStack management surface."""

from __future__ import annotations

import base64
import json
import os
import re
from typing import Any, Dict, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

from management_surface import OPERATION_BY_NAME, TOOLS

SERVER_NAME = "bratonien-linkstack"
SERVER_VERSION = "0.1.0"
MAX_RESPONSE_BYTES = 8_000_000


class ToolError(Exception):
    pass


def linkstack_origin() -> str:
    value = os.environ.get("LINKSTACK_URL", "").strip().rstrip("/")
    if not value.startswith("https://"):
        raise ToolError("LINKSTACK_URL must be the public HTTPS LinkStack URL.")
    return value


def linkstack_token() -> str:
    value = os.environ.get("LINKSTACK_TOKEN", "").strip()
    if not value:
        raise ToolError("LINKSTACK_TOKEN is not configured.")
    if not value.startswith("ls_"):
        raise ToolError("LINKSTACK_TOKEN must be a Bratonien LinkStack API token beginning with ls_.")
    return value


def read_response(response) -> tuple[int, Dict[str, str], bytes]:
    raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ToolError("LinkStack returned more than the connector response limit.")
    return response.status, dict(response.headers.items()), raw


def request_raw(url: str, method="GET", headers=None, payload: Optional[bytes] = None):
    request_headers = {"Accept": "application/json", "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}"}
    if headers:
        request_headers.update(headers)
    request = Request(url, data=payload, headers=request_headers, method=method)
    try:
        with urlopen(request, timeout=30) as response:
            return read_response(response)
    except HTTPError as exc:
        raw = exc.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ToolError("LinkStack returned more than the connector response limit.")
        return exc.code, dict(exc.headers.items()) if exc.headers else {}, raw
    except URLError:
        raise ToolError("LinkStack could not be reached.")


def decode_body(headers: Dict[str, str], raw: bytes) -> Any:
    if not raw:
        return None
    content_type = next((v for k, v in headers.items() if k.lower() == "content-type"), "")
    if "json" in content_type.lower():
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return {"base64": base64.b64encode(raw).decode("ascii")}


def validate_root_path(path: Any) -> str:
    if not isinstance(path, str) or not path.startswith("/api/v1/") and path != "/api/v1/status":
        raise ToolError("LinkStack path must stay below /api/v1/.")
    if path.startswith("//") or len(path) > 2000 or "\r" in path or "\n" in path:
        raise ToolError("Invalid LinkStack path.")
    return path


def render_path(template: str, arguments: Dict[str, Any]) -> str:
    def repl(match):
        key = match.group(1)
        value = arguments.get(key)
        if not isinstance(value, (str, int)) or isinstance(value, bool) or str(value).strip() == "":
            raise ToolError(f"{key} is required.")
        return quote(str(value).strip(), safe="")
    return validate_root_path(re.sub(r"\{([a-zA-Z0-9_]+)\}", repl, template))


def build_url(path: str, query=None) -> str:
    url = linkstack_origin() + validate_root_path(path)
    if query:
        if not isinstance(query, dict):
            raise ToolError("query must be an object.")
        clean = {k: v for k, v in query.items() if v is not None}
        if clean:
            url += "?" + urlencode(clean, doseq=True)
    return url


def safe_headers(arguments: Dict[str, Any]) -> Dict[str, str]:
    supplied = arguments.get("headers") or {}
    if not isinstance(supplied, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in supplied.items()):
        raise ToolError("headers must contain string keys and values.")
    if any(k.lower() in {"authorization", "host", "cookie"} for k in supplied):
        raise ToolError("Authorization, Host and Cookie headers are managed by the connector.")
    return dict(supplied)


def payload(arguments: Dict[str, Any], headers: Dict[str, str]) -> Optional[bytes]:
    body = arguments.get("body")
    body_base64 = arguments.get("body_base64")
    if body is not None and body_base64 is not None:
        raise ToolError("body and body_base64 are mutually exclusive.")
    if body_base64 is not None:
        if not isinstance(body_base64, str):
            raise ToolError("body_base64 must be a string.")
        try:
            return base64.b64decode(body_base64, validate=True)
        except Exception as exc:
            raise ToolError("body_base64 is not valid base64.") from exc
    if body is not None:
        headers.setdefault("Content-Type", "application/json")
        return json.dumps(body).encode("utf-8")
    return None


def execute_http(method: str, path: str, arguments: Dict[str, Any]) -> Any:
    url = build_url(path, arguments.get("query"))
    headers = safe_headers(arguments)
    headers["Authorization"] = "Bearer " + linkstack_token()
    data = payload(arguments, headers)
    status, response_headers, raw = request_raw(url, method=method, headers=headers, payload=data)
    body = decode_body(response_headers, raw)
    if status >= 400:
        detail = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        if len(detail) > 2000:
            detail = detail[:2000] + "..."
        raise ToolError(f"LinkStack returned HTTP {status}: {detail}")
    return {"status": status, "body": body}


def generic_api_call(arguments: Dict[str, Any]) -> Any:
    method = arguments.get("method")
    path = arguments.get("path")
    if method not in {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}:
        raise ToolError("method must be GET, HEAD, POST, PUT, PATCH, DELETE or OPTIONS.")
    return execute_http(method, validate_root_path(path), arguments)


def call_tool(name: str, arguments: Dict[str, Any]) -> Any:
    if name == "api_call":
        return generic_api_call(arguments)
    op = OPERATION_BY_NAME.get(name)
    if not op:
        raise ToolError("Unknown tool.")
    return execute_http(op["method"], render_path(op["path"], arguments), arguments)


def api_call_tool():
    return {
        "name": "api_call",
        "title": "LinkStack API Call",
        "description": "Call an explicit path below /api/v1/ for forward compatibility. LinkStack still enforces the API application's fine-grained permissions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "method": {"type": "string", "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]},
                "path": {"type": "string"},
                "query": {"type": "object", "additionalProperties": True},
                "headers": {"type": "object", "additionalProperties": {"type": "string"}},
                "body": {},
                "body_base64": {"type": "string"},
            },
            "required": ["method", "path"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False, "openWorldHint": True},
    }


TOOLS = TOOLS + [api_call_tool()]


def handle_message(message: Dict[str, Any]) -> Dict[str, Any]:
    request_id = message.get("id")
    method = message.get("method")
    try:
        if method == "initialize":
            version = ((message.get("params") or {}).get("protocolVersion") or "2025-03-26")
            result = {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = message.get("params") or {}
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if not isinstance(arguments, dict):
                raise ToolError("Tool arguments must be an object.")
            data = call_tool(name, arguments)
            result = {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}], "isError": False}
        else:
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}
        return {"jsonrpc": "2.0", "id": request_id, "result": result}
    except ToolError as exc:
        if method == "tools/call":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": str(exc)}], "isError": True}}
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": str(exc)}}
