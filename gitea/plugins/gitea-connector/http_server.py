#!/usr/bin/env python3
"""Minimal stateless Streamable HTTP transport for the Gitea MCP server."""

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional

import entrypoint
import server


MAX_REQUEST_SIZE = 2_000_000
MCP_PATH = "/mcp"
HEALTH_PATH = "/health"
OAUTH_METADATA_PATHS = {
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-protected-resource/mcp",
    "/mcp/.well-known/oauth-protected-resource",
}
OAUTH_SERVER_METADATA_PATHS = {
    "/.well-known/oauth-authorization-server",
    "/.well-known/oauth-authorization-server/mcp",
    "/mcp/.well-known/oauth-authorization-server",
    "/.well-known/openid-configuration",
    "/.well-known/openid-configuration/mcp",
    "/mcp/.well-known/openid-configuration",
}


def _allowed_origins():
    raw = os.environ.get("MCP_ALLOWED_ORIGINS", "")
    return {value.strip() for value in raw.split(",") if value.strip()}


def _oauth_issuer() -> str:
    return os.environ.get("MCP_OAUTH_ISSUER", "").strip().rstrip("/")


def _resource_url() -> str:
    return os.environ.get("MCP_RESOURCE_URL", "").strip() or "https://mcp.bratonien.de/mcp"


def _trust_forwarded_bearer() -> bool:
    raw = os.environ.get("MCP_TRUST_FORWARDED_BEARER", "").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def _authorization(header: Optional[str]):
    """Return (authorized, OAuth token). None means server/fallback authentication."""
    expected = os.environ.get("MCP_HTTP_TOKEN", "").strip()
    if not header or not header.startswith("Bearer "):
        return (not expected and not _oauth_issuer() and not _trust_forwarded_bearer()), None
    token = header[7:].strip()
    if not token:
        return False, None
    if expected and hmac.compare_digest(token, expected):
        return True, None
    if _oauth_issuer() or _trust_forwarded_bearer():
        return True, token
    return False, None


def _authorized(header: Optional[str]) -> bool:
    return _authorization(header)[0]


def _oauth_metadata():
    return {
        "resource": _resource_url(),
        "authorization_servers": [_oauth_issuer()],
        "scopes_supported": [
            "write:repository", "write:issue", "read:user",
            "read:organization", "read:package", "read:notification",
        ],
        "resource_documentation": "https://github.com/Terranom674/ChatGPT_Connectors/tree/main/gitea",
    }


def _oauth_server_metadata():
    issuer = _oauth_issuer()
    return {
        "issuer": issuer,
        "authorization_endpoint": issuer + "/login/oauth/authorize",
        "token_endpoint": issuer + "/login/oauth/access_token",
        "userinfo_endpoint": issuer + "/login/oauth/userinfo",
        "jwks_uri": issuer + "/login/oauth/keys",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "token_endpoint_auth_methods_supported": ["client_secret_post"],
        "code_challenge_methods_supported": ["S256"],
        "scopes_supported": _oauth_metadata()["scopes_supported"],
    }


def _log_mcp_method(message, response) -> None:
    """Log protocol progress without request arguments, headers, or result data."""
    method = message.get("method") if isinstance(message, dict) else None
    if not isinstance(method, str):
        method = "invalid"
    details = []
    if method == "tools/list" and isinstance(response, dict):
        tools = ((response.get("result") or {}).get("tools"))
        if isinstance(tools, list):
            details.append("tools=%d" % len(tools))
    elif method == "tools/call":
        name = ((message.get("params") or {}).get("name"))
        if isinstance(name, str):
            details.append("tool=%s" % name)
    suffix = " " + " ".join(details) if details else ""
    print("MCP method=%s%s" % (method, suffix), file=sys.stderr, flush=True)


class MCPHandler(BaseHTTPRequestHandler):
    server_version = "GiteaMCP/1.1"

    def log_message(self, format, *args):
        super().log_message(format, *args)

    def _send_json(self, status: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _origin_allowed(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        return origin in _allowed_origins()

    def _check_common_security(self) -> bool:
        if not self._origin_allowed():
            self._send_json(403, {"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": "Origin is not allowed."}})
            return False
        if not _authorized(self.headers.get("Authorization")):
            body = json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32001, "message": "Authentication required."}}, separators=(",", ":")).encode("utf-8")
            self.send_response(401)
            if _oauth_issuer():
                self.send_header("WWW-Authenticate", 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource"' % _resource_url().split("/mcp", 1)[0])
            else:
                self.send_header("WWW-Authenticate", "Bearer")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return False
        return True

    def do_GET(self):
        if self.path in OAUTH_SERVER_METADATA_PATHS:
            if not _oauth_issuer():
                self._send_json(404, {"error": "not found"})
                return
            self._send_json(200, _oauth_server_metadata())
            return
        if self.path in OAUTH_METADATA_PATHS:
            if not _oauth_issuer():
                self._send_json(404, {"error": "not found"})
                return
            self._send_json(200, _oauth_metadata())
            return
        if self.path == HEALTH_PATH:
            self._send_json(200, {"status": "ok"})
            return
        if self.path != MCP_PATH:
            self._send_json(404, {"error": "not found"})
            return
        if not self._check_common_security():
            return
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        if self.path != MCP_PATH:
            self._send_json(404, {"error": "not found"})
            return
        if not self._check_common_security():
            return
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path != MCP_PATH:
            self._send_json(404, {"error": "not found"})
            return
        if not self._check_common_security():
            return

        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            self._send_json(415, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Content-Type must be application/json."}})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_SIZE:
            self._send_json(413, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid request size."}})
            return

        try:
            message = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            return

        if not isinstance(message, dict):
            self._send_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}})
            return

        authorized, oauth_token = _authorization(self.headers.get("Authorization"))
        if not authorized:
            return
        context_token = server.CURRENT_GITEA_OAUTH_TOKEN.set(oauth_token)
        try:
            response = server.handle_message(message)
        finally:
            server.CURRENT_GITEA_OAUTH_TOKEN.reset(context_token)
        _log_mcp_method(message, response)
        if response is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self._send_json(200, response)


def main() -> None:
    entrypoint.configure_server()
    host = os.environ.get("MCP_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = int(os.environ.get("MCP_PORT", "8000"))
    httpd = ThreadingHTTPServer((host, port), MCPHandler)
    print(f"Gitea MCP HTTP server listening on http://{host}:{port}{MCP_PATH}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
