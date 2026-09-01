#!/usr/bin/env python3
"""Minimal stateless Streamable HTTP transport for the internal Gitea connector."""

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import entrypoint
import server

MAX_REQUEST_SIZE = 2_000_000
MCP_PATH = "/mcp"
HEALTH_PATH = "/health"


def _authorized(header) -> bool:
    expected = os.environ.get("MCP_HTTP_TOKEN", "").strip()
    if not expected or not header or not header.startswith("Bearer "):
        return False
    return hmac.compare_digest(header[7:].strip(), expected)


def _log_mcp_method(message, response) -> None:
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
    server_version = "BratonienGiteaMCP/1.2"

    def _send_json(self, status: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check_auth(self) -> bool:
        if _authorized(self.headers.get("Authorization")):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def do_GET(self):
        if self.path == HEALTH_PATH:
            self._send_json(200, {"status": "ok"})
            return
        if self.path != MCP_PATH:
            self._send_json(404, {"error": "not_found"})
            return
        if not self._check_auth():
            return
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        if self.path != MCP_PATH:
            self._send_json(404, {"error": "not_found"})
            return
        if not self._check_auth():
            return
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path != MCP_PATH:
            self._send_json(404, {"error": "not_found"})
            return
        if not self._check_auth():
            return
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            self._send_json(415, {"error": "application_json_required"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_SIZE:
            self._send_json(413 if length > MAX_REQUEST_SIZE else 400, {"error": "invalid_body_size"})
            return
        try:
            message = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid_json"})
            return
        if not isinstance(message, dict):
            self._send_json(400, {"error": "json_rpc_object_required"})
            return
        response = server.handle_message(message)
        _log_mcp_method(message, response)
        if response is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send_json(200, response)


def main() -> None:
    entrypoint.configure_server()
    host = os.environ.get("MCP_HOST", "0.0.0.0").strip() or "0.0.0.0"
    port = int(os.environ.get("MCP_PORT", "8000"))
    httpd = ThreadingHTTPServer((host, port), MCPHandler)
    print(f"Gitea MCP connector listening on http://{host}:{port}{MCP_PATH}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
