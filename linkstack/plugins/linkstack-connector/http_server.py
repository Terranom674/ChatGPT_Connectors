#!/usr/bin/env python3
"""Minimal stateless Streamable HTTP transport for the LinkStack connector."""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import server

MAX_BODY = 2_000_000


def expected_token() -> str:
    return os.environ.get("MCP_HTTP_TOKEN", "").strip()


def authorized(handler: BaseHTTPRequestHandler) -> bool:
    token = expected_token()
    if not token:
        return False
    return handler.headers.get("Authorization", "") == "Bearer " + token


class Handler(BaseHTTPRequestHandler):
    server_version = "BratonienLinkStackMCP/0.1"

    def send_json(self, status: int, data) -> None:
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok"})
            return
        if self.path == "/mcp":
            self.send_json(401 if not authorized(self) else 405, {"error": "unauthorized" if not authorized(self) else "method_not_allowed"})
            return
        self.send_json(404, {"error": "not_found"})

    def do_DELETE(self):
        if self.path != "/mcp":
            self.send_json(404, {"error": "not_found"})
            return
        if not authorized(self):
            self.send_json(401, {"error": "unauthorized"})
            return
        self.send_json(405, {"error": "method_not_allowed"})

    def do_POST(self):
        if self.path != "/mcp":
            self.send_json(404, {"error": "not_found"})
            return
        if not authorized(self):
            self.send_json(401, {"error": "unauthorized"})
            return
        if "application/json" not in self.headers.get("Content-Type", ""):
            self.send_json(415, {"error": "application_json_required"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, {"error": "invalid_content_length"})
            return
        if length <= 0 or length > MAX_BODY:
            self.send_json(413 if length > MAX_BODY else 400, {"error": "invalid_body_size"})
            return
        try:
            message = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid_json"})
            return
        if not isinstance(message, dict):
            self.send_json(400, {"error": "json_rpc_object_required"})
            return
        self.send_json(200, server.handle_message(message))


def main() -> None:
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "8000"))
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"LinkStack MCP connector listening on http://{host}:{port}/mcp", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
