import importlib.util
import io
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("gitea_http_server", ROOT / "http_server.py")
http_server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(http_server)


class HttpServerTests(unittest.TestCase):
    def test_protocol_logging_omits_arguments_and_reports_tool_count(self):
        message = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {"secret": "never-log"}}
        response = {"jsonrpc": "2.0", "id": 2, "result": {"tools": [{"name": "one"}, {"name": "two"}]}}
        output = io.StringIO()
        with patch("sys.stderr", output):
            http_server._log_mcp_method(message, response)
        self.assertEqual(output.getvalue(), "MCP method=tools/list tools=2\n")
        self.assertNotIn("never-log", output.getvalue())

    def test_http_token_is_optional(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(http_server._authorized(None))

    def test_http_token_uses_bearer_auth(self):
        with patch.dict(os.environ, {"MCP_HTTP_TOKEN": "secret"}, clear=True):
            self.assertFalse(http_server._authorized(None))
            self.assertFalse(http_server._authorized("Bearer wrong"))
            self.assertTrue(http_server._authorized("Bearer secret"))

    def test_oauth_token_is_accepted_when_issuer_is_configured(self):
        with patch.dict(os.environ, {"MCP_HTTP_TOKEN": "legacy", "MCP_OAUTH_ISSUER": "https://git.example.com"}, clear=True):
            self.assertEqual(http_server._authorization("Bearer oauth-token"), (True, "oauth-token"))
            self.assertEqual(http_server._authorization("Bearer legacy"), (True, None))

    def test_forwarded_bearer_mode_accepts_non_internal_token_without_public_oauth_metadata(self):
        with patch.dict(
            os.environ,
            {"MCP_HTTP_TOKEN": "internal", "MCP_TRUST_FORWARDED_BEARER": "1"},
            clear=True,
        ):
            self.assertEqual(http_server._authorization("Bearer forwarded-oauth"), (True, "forwarded-oauth"))
            self.assertEqual(http_server._authorization("Bearer internal"), (True, None))
            self.assertEqual(http_server._oauth_issuer(), "")

    def test_forwarded_bearer_mode_still_requires_a_bearer(self):
        with patch.dict(
            os.environ,
            {"MCP_HTTP_TOKEN": "internal", "MCP_TRUST_FORWARDED_BEARER": "1"},
            clear=True,
        ):
            self.assertFalse(http_server._authorized(None))
            self.assertFalse(http_server._authorized("Basic abc"))

    def test_oauth_metadata_describes_gitea_resource(self):
        with patch.dict(os.environ, {"MCP_OAUTH_ISSUER": "https://git.example.com", "MCP_RESOURCE_URL": "https://mcp.example.com/mcp"}, clear=True):
            metadata = http_server._oauth_metadata()
            self.assertEqual(metadata["resource"], "https://mcp.example.com/mcp")
            self.assertEqual(metadata["authorization_servers"], ["https://git.example.com"])

    def test_oauth_server_metadata_points_to_gitea(self):
        with patch.dict(os.environ, {"MCP_OAUTH_ISSUER": "https://git.example.com"}, clear=True):
            metadata = http_server._oauth_server_metadata()
            self.assertEqual(metadata["issuer"], "https://git.example.com")
            self.assertEqual(metadata["authorization_endpoint"], "https://git.example.com/login/oauth/authorize")
            self.assertEqual(metadata["token_endpoint"], "https://git.example.com/login/oauth/access_token")
            self.assertIn("client_secret_post", metadata["token_endpoint_auth_methods_supported"])

    def test_allowed_origins_are_explicit(self):
        with patch.dict(os.environ, {"MCP_ALLOWED_ORIGINS": "https://example.com, https://chat.example"}, clear=True):
            self.assertEqual(
                http_server._allowed_origins(),
                {"https://example.com", "https://chat.example"},
            )


if __name__ == "__main__":
    unittest.main()
