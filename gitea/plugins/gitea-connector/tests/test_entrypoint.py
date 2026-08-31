import importlib
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

entrypoint = importlib.import_module("entrypoint")


class EntrypointTests(unittest.TestCase):
    def test_requires_gitea_url(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(SystemExit) as exc:
                entrypoint.configured_origin()
        self.assertIn("GITEA_URL is required", str(exc.exception))

    def test_accepts_https_origin(self):
        with patch.dict(os.environ, {"GITEA_URL": "https://git.example.com/"}, clear=True):
            self.assertEqual(entrypoint.configured_origin(), "https://git.example.com")

    def test_accepts_instance_below_path(self):
        with patch.dict(os.environ, {"GITEA_URL": "https://example.com/gitea/"}, clear=True):
            self.assertEqual(entrypoint.configured_origin(), "https://example.com/gitea")

    def test_oauth_security_scheme_is_added_to_every_tool(self):
        original_tools = [dict(tool) for tool in entrypoint.server.TOOLS]
        original_handle = entrypoint.server.handle_message
        try:
            with patch.dict(os.environ, {"GITEA_URL": "https://git.example.com", "MCP_OAUTH_ISSUER": "https://git.example.com"}, clear=True):
                entrypoint.configure_server()
            self.assertTrue(entrypoint.server.TOOLS)
            for tool in entrypoint.server.TOOLS:
                self.assertEqual(tool["securitySchemes"], [{"type": "oauth2", "scopes": entrypoint.OAUTH_SCOPES}])
        finally:
            entrypoint.server.TOOLS[:] = original_tools
            entrypoint.server.handle_message = original_handle

    def test_rejects_credentials_in_url(self):
        with patch.dict(os.environ, {"GITEA_URL": "https://user:secret@git.example.com"}, clear=True):
            with self.assertRaises(SystemExit) as exc:
                entrypoint.configured_origin()
        self.assertIn("credentials", str(exc.exception))

    def test_rejects_non_http_scheme(self):
        with patch.dict(os.environ, {"GITEA_URL": "file:///tmp/gitea"}, clear=True):
            with self.assertRaises(SystemExit):
                entrypoint.configured_origin()

    def test_rejects_query_and_fragment(self):
        for value in ("https://git.example.com?x=1", "https://git.example.com/#test"):
            with self.subTest(value=value), patch.dict(os.environ, {"GITEA_URL": value}, clear=True):
                with self.assertRaises(SystemExit):
                    entrypoint.configured_origin()


if __name__ == "__main__":
    unittest.main()
