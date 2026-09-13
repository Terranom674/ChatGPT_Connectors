#!/usr/bin/env python3
from __future__ import annotations

import base64
import http.cookiejar
import json
import os
import threading
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional

import socketio

SERVER_NAME = "bratonien-affine"
SERVER_VERSION = "1.4.0"
DEFAULT_PROTOCOL_VERSION = "2025-03-26"
SUPPORTED_PROTOCOL_VERSIONS = {
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    "2024-10-07",
}
MAX_RESPONSE_BYTES = 8_000_000
AFFINE_CLIENT_VERSION = os.environ.get("AFFINE_CLIENT_VERSION", "0.27.0").strip() or "0.27.0"

# Only tools that must exist in AFFiNE's own native MCP surface. Lifecycle tools
# are intentionally implemented by this external connector so AFFiNE Core stays
# untouched apart from the separate minimal READ_WRITE gate patch.
REQUIRED_TOOLS = {
    "read_document",
    "doc_search",
    "create_document",
    "update_document",
    "update_document_meta",
}

LOCAL_TOOL_NAMES = {
    "api_call",
    "trash_document",
    "restore_document",
    "delete_document",
}

_SESSION_LOCK = threading.Lock()
_SESSION_COOKIE: Optional[str] = None


class AffineError(Exception):
    pass


def affine_origin() -> str:
    base = os.environ.get("AFFINE_URL", "").strip().rstrip("/")
    if not base.startswith("https://"):
        raise AffineError("AFFINE_URL must use HTTPS.")
    return base


def workspace_id() -> str:
    workspace = os.environ.get("AFFINE_WORKSPACE_ID", "").strip()
    if not workspace:
        raise AffineError("AFFINE_WORKSPACE_ID is not configured.")
    return workspace


def upstream_url() -> str:
    return f"{affine_origin()}/api/workspaces/{workspace_id()}/mcp/"


def upstream_token() -> str:
    token = os.environ.get("AFFINE_MCP_TOKEN", "").strip()
    if not token:
        raise AffineError("AFFINE_MCP_TOKEN is not configured.")
    if not token.startswith("aff_mcp_v1."):
        raise AffineError("AFFINE_MCP_TOKEN has an unexpected format.")
    return token


def configured_api_auth() -> Optional[tuple[str, str]]:
    header = os.environ.get("AFFINE_API_AUTH_HEADER", "").strip()
    value = os.environ.get("AFFINE_API_AUTH_VALUE", "").strip()
    if not header and not value:
        return None
    if not header or not value:
        raise AffineError("AFFINE_API_AUTH_HEADER and AFFINE_API_AUTH_VALUE must be configured together.")
    if any(ch in header for ch in "\r\n:") or any(ch in value for ch in "\r\n"):
        raise AffineError("Configured AFFiNE API authentication contains invalid characters.")
    return header, value


def connector_credentials() -> tuple[str, str]:
    email = os.environ.get("AFFINE_EMAIL", "").strip()
    password = os.environ.get("AFFINE_PASSWORD", "")
    if not email or not password:
        raise AffineError(
            "AFFiNE connector credentials are not configured. Set AFFINE_EMAIL and AFFINE_PASSWORD "
            "inside the connector service, or provide a server-managed AFFINE_API_AUTH_HEADER/AFFINE_API_AUTH_VALUE."
        )
    if "\r" in email or "\n" in email:
        raise AffineError("AFFINE_EMAIL contains invalid characters.")
    return email, password


def _cookie_header(jar: http.cookiejar.CookieJar) -> str:
    pairs = [f"{cookie.name}={cookie.value}" for cookie in jar]
    return "; ".join(pairs)


def login_session(force: bool = False) -> str:
    global _SESSION_COOKIE
    explicit = configured_api_auth()
    if explicit is not None:
        header, value = explicit
        if header.lower() != "cookie":
            raise AffineError("Internal AFFiNE session login is not needed when non-cookie API authentication is configured.")
        return value

    with _SESSION_LOCK:
        if _SESSION_COOKIE and not force:
            return _SESSION_COOKIE

        email, password = connector_credentials()
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        request = urllib.request.Request(
            affine_origin() + "/api/auth/sign-in",
            data=json.dumps({"email": email, "password": password}, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/plain, */*",
                "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}",
                "X-Affine-Version": AFFINE_CLIENT_VERSION,
            },
        )
        try:
            with opener.open(request, timeout=30) as response:
                response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            raw = exc.read(2000).decode("utf-8", errors="replace")
            raise AffineError(f"AFFiNE connector sign-in failed with HTTP {exc.code}: {raw}") from exc
        except Exception as exc:
            raise AffineError(f"AFFiNE connector sign-in failed: {exc}") from exc

        cookie = _cookie_header(jar)
        if not cookie:
            raise AffineError("AFFiNE connector sign-in succeeded but returned no session cookie.")
        if "\r" in cookie or "\n" in cookie:
            raise AffineError("AFFiNE returned an invalid session cookie.")
        _SESSION_COOKIE = cookie
        return cookie


def api_auth(force_refresh: bool = False) -> tuple[str, str]:
    explicit = configured_api_auth()
    if explicit is not None:
        return explicit
    return "Cookie", login_session(force=force_refresh)


def socket_auth(force_refresh: bool = False) -> tuple[dict, dict]:
    """Return Socket.IO auth payload and HTTP headers using connector-managed AFFiNE auth."""
    header, value = api_auth(force_refresh=force_refresh)
    lower = header.lower()
    if lower == "authorization" and value.lower().startswith("bearer "):
        token = value[7:].strip()
        if not token:
            raise AffineError("AFFiNE Authorization bearer token is empty.")
        return {"token": token, "tokenType": "jwt"}, {}
    if lower == "cookie":
        return {}, {"Cookie": value}
    raise AffineError("AFFiNE connector authentication must resolve to a Bearer token or Cookie session.")


def error_response(request_id: Any, code: int, message: str, data: Optional[dict] = None) -> dict:
    error: Dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def read_http_response(response) -> tuple[int, Dict[str, str], bytes]:
    raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise AffineError("AFFiNE returned more than the connector response limit.")
    return response.status, dict(response.headers.items()), raw


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


def api_call_tool() -> dict:
    return {
        "name": "api_call",
        "title": "AFFiNE API Call",
        "description": (
            "Call an explicit AFFiNE HTTP API path below /api/. Authentication and session renewal are managed "
            "entirely inside this connector."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "method": {
                    "type": "string",
                    "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
                },
                "path": {"type": "string"},
                "query": {"type": "object", "additionalProperties": True},
                "headers": {"type": "object", "additionalProperties": {"type": "string"}},
                "body": {},
                "body_base64": {"type": "string"},
            },
            "required": ["method", "path"],
            "additionalProperties": False,
        },
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": True,
        },
    }


def lifecycle_tool(name: str, title: str, lifecycle: str, description: str) -> dict:
    return {
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": {
                "docId": {"type": "string", "description": "The AFFiNE document ID"},
            },
            "required": ["docId"],
            "additionalProperties": False,
        },
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": lifecycle in {"trash", "delete"},
            "idempotentHint": False,
            "openWorldHint": False,
        },
    }


def local_tools() -> list[dict]:
    return [
        api_call_tool(),
        lifecycle_tool(
            "trash_document",
            "Trash Document",
            "trash",
            "Move an AFFiNE document to trash using AFFiNE's native sync API through this connector.",
        ),
        lifecycle_tool(
            "restore_document",
            "Restore Document",
            "restore",
            "Restore an AFFiNE document from trash using AFFiNE's native sync API through this connector.",
        ),
        lifecycle_tool(
            "delete_document",
            "Delete Document",
            "delete",
            "Permanently delete an AFFiNE document using AFFiNE's native sync API through this connector. This cannot be undone.",
        ),
    ]


def validate_api_path(path: Any) -> str:
    if not isinstance(path, str) or not path.startswith("/api/"):
        raise AffineError("AFFiNE API path must stay below /api/.")
    if path.startswith("//") or len(path) > 2000 or "\r" in path or "\n" in path:
        raise AffineError("Invalid AFFiNE API path.")
    parsed = urllib.parse.urlsplit(path)
    if parsed.scheme or parsed.netloc:
        raise AffineError("AFFiNE API path must be relative to AFFINE_URL.")
    return path


def decode_api_body(headers: Dict[str, str], raw: bytes) -> Any:
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


def _execute_api_call_once(arguments: Dict[str, Any], force_refresh: bool = False) -> dict:
    method = arguments.get("method")
    if method not in {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}:
        raise AffineError("Unsupported HTTP method.")
    path = validate_api_path(arguments.get("path"))
    query = arguments.get("query") or {}
    if not isinstance(query, dict):
        raise AffineError("query must be an object.")

    supplied_headers = arguments.get("headers") or {}
    if not isinstance(supplied_headers, dict) or any(
        not isinstance(k, str) or not isinstance(v, str) for k, v in supplied_headers.items()
    ):
        raise AffineError("headers must contain string keys and values.")

    auth_header, auth_value = api_auth(force_refresh=force_refresh)
    protected = {"host", "authorization", "cookie", auth_header.lower()}
    if any(k.lower() in protected for k in supplied_headers):
        raise AffineError("Authentication, Host and Cookie headers are managed by the connector.")

    url = affine_origin() + path
    clean_query = {k: v for k, v in query.items() if v is not None}
    if clean_query:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(clean_query, doseq=True)

    headers = {
        "Accept": "application/json, text/plain, */*",
        "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}",
        "X-Affine-Version": AFFINE_CLIENT_VERSION,
        auth_header: auth_value,
    }
    headers.update(supplied_headers)

    body = arguments.get("body")
    body_base64 = arguments.get("body_base64")
    if body is not None and body_base64 is not None:
        raise AffineError("body and body_base64 are mutually exclusive.")
    payload: Optional[bytes] = None
    if body_base64 is not None:
        if not isinstance(body_base64, str):
            raise AffineError("body_base64 must be a string.")
        try:
            payload = base64.b64decode(body_base64, validate=True)
        except Exception as exc:
            raise AffineError("body_base64 is not valid base64.") from exc
    elif body is not None:
        headers.setdefault("Content-Type", "application/json")
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")

    request = urllib.request.Request(url, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status, response_headers, raw = read_http_response(response)
    except urllib.error.HTTPError as exc:
        raw = exc.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise AffineError("AFFiNE returned more than the connector response limit.")
        status = exc.code
        response_headers = dict(exc.headers.items()) if exc.headers else {}

    result = {
        "status": status,
        "headers": {
            k: v
            for k, v in response_headers.items()
            if k.lower() in {"content-type", "etag", "last-modified", "location"}
        },
        "body": decode_api_body(response_headers, raw),
    }
    if status >= 400:
        error = AffineError(f"AFFiNE API returned HTTP {status}: {json.dumps(result['body'], ensure_ascii=False)[:2000]}")
        setattr(error, "status", status)
        raise error
    return result


def execute_api_call(arguments: Dict[str, Any]) -> dict:
    try:
        return _execute_api_call_once(arguments, force_refresh=False)
    except AffineError as exc:
        if getattr(exc, "status", None) not in {401, 403} or configured_api_auth() is not None:
            raise
        return _execute_api_call_once(arguments, force_refresh=True)


def _socket_client(force_refresh: bool = False) -> socketio.Client:
    auth, headers = socket_auth(force_refresh=force_refresh)
    client = socketio.Client(
        reconnection=False,
        logger=False,
        engineio_logger=False,
        request_timeout=30,
    )
    client.connect(
        affine_origin(),
        auth=auth,
        headers=headers or None,
        transports=["polling", "websocket"],
        wait=True,
        wait_timeout=15,
    )
    return client


def execute_lifecycle(arguments: Dict[str, Any], lifecycle: str) -> dict:
    doc_id = arguments.get("docId")
    if not isinstance(doc_id, str) or not doc_id.strip():
        raise AffineError("docId is required.")
    if lifecycle not in {"trash", "restore", "delete"}:
        raise AffineError("Invalid document lifecycle operation.")

    response: Any = None
    last_error: Optional[Exception] = None
    for attempt in range(2):
        client: Optional[socketio.Client] = None
        try:
            client = _socket_client(force_refresh=attempt == 1)
            if lifecycle == "delete":
                response = client.call(
                    "space:delete-doc",
                    {
                        "spaceType": "workspace",
                        "spaceId": workspace_id(),
                        "docId": doc_id.strip(),
                    },
                    timeout=30,
                )
            else:
                response = client.call(
                    "space:doc-lifecycle",
                    {
                        "spaceType": "workspace",
                        "spaceId": workspace_id(),
                        "docId": doc_id.strip(),
                        "lifecycle": lifecycle,
                    },
                    timeout=30,
                )
            last_error = None
            break
        except Exception as exc:
            last_error = exc
            if attempt == 0 and configured_api_auth() is None:
                continue
            break
        finally:
            try:
                if client is not None and client.connected:
                    client.disconnect()
            except Exception:
                pass

    if last_error is not None:
        raise AffineError(f"AFFiNE document lifecycle request failed: {last_error}") from last_error

    if isinstance(response, dict) and response.get("error"):
        error = response["error"]
        if isinstance(error, dict):
            message = error.get("message") or json.dumps(error, ensure_ascii=False)
        else:
            message = str(error)
        raise AffineError(f"AFFiNE rejected document lifecycle request: {message}")

    data = response.get("data") if isinstance(response, dict) and "data" in response else response
    return {
        "success": True,
        "docId": doc_id.strip(),
        "lifecycle": lifecycle,
        "result": data,
    }


def with_local_tools(response: dict) -> dict:
    if response.get("error"):
        return response
    result = response.get("result")
    if not isinstance(result, dict):
        return response
    tools = result.get("tools")
    if isinstance(tools, list):
        tools[:] = [t for t in tools if not (isinstance(t, dict) and t.get("name") in LOCAL_TOOL_NAMES)]
        tools.extend(local_tools())
    return response


def tool_result(data: Any, is_error: bool = False) -> dict:
    return {
        "content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}],
        "isError": is_error,
    }


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
        return with_local_tools(call_upstream({"jsonrpc": "2.0", "id": request_id, "method": "tools/list", "params": {}}))

    if method == "tools/call":
        params = message.get("params")
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return error_response(request_id, -32602, "Invalid params")
        if is_notification:
            return None
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            return error_response(request_id, -32602, "Invalid params")

        name = params["name"]
        try:
            if name == "api_call":
                result = tool_result(execute_api_call(arguments))
            elif name == "trash_document":
                result = tool_result(execute_lifecycle(arguments, "trash"))
            elif name == "restore_document":
                result = tool_result(execute_lifecycle(arguments, "restore"))
            elif name == "delete_document":
                result = tool_result(execute_lifecycle(arguments, "delete"))
            else:
                return call_upstream({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "tools/call",
                    "params": {"name": name, "arguments": arguments},
                })
        except AffineError as exc:
            result = tool_result(str(exc), True)
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    if is_notification:
        return None
    return error_response(request_id, -32601, "Method not found")


def validate_upstream() -> tuple[bool, set[str], dict]:
    response = call_upstream({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
    tools = (response.get("result") or {}).get("tools") or []
    names = {str(tool.get("name", "")) for tool in tools if isinstance(tool, dict)}
    return REQUIRED_TOOLS.issubset(names), names, response
