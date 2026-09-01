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

    def test_http_token_is_required(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(http_server._authorized(None))
            self.assertFalse(http_server._authorized("Bearer anything"))

    def test_http_token_uses_exact_bearer_auth(self):
        with patch.dict(os.environ, {"MCP_HTTP_TOKEN": "secret"}, clear=True):
            self.assertFalse(http_server._authorized(None))
            self.assertFalse(http_server._authorized("Basic secret"))
            self.assertFalse(http_server._authorized("Bearer wrong"))
            self.assertTrue(http_server._authorized("Bearer secret"))


if __name__ == "__main__":
    unittest.main()
