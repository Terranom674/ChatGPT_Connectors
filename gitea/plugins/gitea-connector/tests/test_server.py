import importlib.util
import io
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gitea_server", ROOT / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class FakeResponse:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, size=-1):
        return json.dumps(self.value).encode("utf-8")


class ServerTests(unittest.TestCase):
    def test_initialize_and_tool_list(self):
        initialized = server.handle_message({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "bratonien-gitea")
        listed = server.handle_message({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual(len(listed["result"]["tools"]), 32)
        annotations = {tool["name"]: tool["annotations"] for tool in listed["result"]["tools"]}
        self.assertTrue(annotations["list_repositories"]["readOnlyHint"])
        self.assertFalse(annotations["create_issue"]["readOnlyHint"])
        self.assertFalse(annotations["create_issue"]["destructiveHint"])
        self.assertTrue(annotations["delete_file"]["destructiveHint"])
        self.assertTrue(annotations["merge_pull_request"]["destructiveHint"])
        self.assertTrue(annotations["change_files"]["destructiveHint"])

    def test_missing_token_is_safe(self):
        with patch.dict(os.environ, {}, clear=True):
            result = server.handle_message({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_repositories", "arguments": {}}})
        self.assertTrue(result["result"]["isError"])
        self.assertIn("GITEA_TOKEN", result["result"]["content"][0]["text"])

    def test_repository_result_is_compact_and_token_is_header_only(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["url"] = request.full_url
            captured["authorization"] = request.get_header("Authorization")
            captured["timeout"] = timeout
            return FakeResponse([{"id": 7, "name": "demo", "full_name": "alice/demo", "owner": {"login": "alice"}, "private": True, "default_branch": "main", "updated_at": "now", "html_url": "https://git.bratonien.de/alice/demo", "internal_secret": "no"}])

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("list_repositories", {"limit": 10})
        self.assertEqual(captured["authorization"], "token secret-token")
        self.assertNotIn("secret-token", captured["url"])
        self.assertNotIn("internal_secret", result[0])
        self.assertEqual(result[0]["full_name"], "alice/demo")

    def test_rejects_path_in_owner(self):
        with self.assertRaises(server.ToolError):
            server.call_tool("get_repository", {"owner": "../admin", "repo": "demo"})

    def test_stdio_round_trip(self):
        request = json.dumps({"jsonrpc": "2.0", "id": 4, "method": "tools/list"}) + "\n"
        process = subprocess.run([sys.executable, str(ROOT / "server.py")], input=request, text=True, capture_output=True, check=True)
        response = json.loads(process.stdout)
        self.assertEqual(response["id"], 4)
        self.assertEqual(len(response["result"]["tools"]), 32)

    def test_operation_catalog_excludes_security_operations(self):
        ids = set(server.ALLOWED_OPERATIONS)
        self.assertIn("repoCreateRelease", ids)
        self.assertIn("repoDelete", ids)
        self.assertNotIn("userCreateToken", ids)
        self.assertNotIn("updateRepoSecret", ids)
        self.assertNotIn("repoAddCollaborator", ids)
        self.assertNotIn("repoCreateHook", ids)

    def test_generic_responses_redact_sensitive_user_metadata(self):
        value = {"user": {"id": 1, "login": "alice", "email": "private@example.test", "is_admin": True, "last_login": "now"}, "access_token": "never-return"}
        result = server.sanitize_response(value)
        self.assertEqual(result["user"], {"id": 1, "login": "alice"})
        self.assertNotIn("access_token", result)

    def test_compact_issue_accepts_null_collections(self):
        result = server.compact_issue({"number": 1, "labels": None, "assignees": None, "user": {"login": "alice"}})
        self.assertEqual(result["labels"], [])
        self.assertEqual(result["assignees"], [])

    def test_describe_operation_resolves_body_schema(self):
        result = server.call_tool("describe_operation", {"operation_id": "repoCreateRelease"})
        self.assertEqual(result["method"], "POST")
        self.assertIn("properties", result["bodySchema"])

    def test_execute_operation_uses_only_catalog_path_and_parameters(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["url"] = request.full_url
            captured["method"] = request.get_method()
            return FakeResponse([{"name": "v1.0.0"}])

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("execute_operation", {"operation_id": "repoListTags", "path_parameters": {"owner": "alice", "repo": "demo"}, "query_parameters": {"page": 1}})
        self.assertEqual(captured["method"], "GET")
        self.assertIn("/repos/alice/demo/tags?page=1", captured["url"])
        self.assertEqual(result[0]["name"], "v1.0.0")

    def test_execute_operation_rejects_unknown_operation(self):
        with self.assertRaises(server.ToolError):
            server.call_tool("execute_operation", {"operation_id": "userCreateToken"})

    def test_get_file_decodes_utf8_content(self):
        encoded = __import__("base64").b64encode("Lanela\n".encode()).decode()

        def fake_urlopen(request, timeout):
            return FakeResponse({"type": "file", "encoding": "base64", "name": "README.md", "path": "README.md", "sha": "abc123", "size": 7, "content": encoded})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("get_file", {"owner": "alice", "repo": "demo", "path": "README.md", "ref": "main"})
        self.assertEqual(result["content"], "Lanela\n")
        self.assertEqual(result["sha"], "abc123")

    def test_update_file_uses_put_and_base64(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["method"] = request.get_method()
            captured["body"] = json.loads(request.data)
            return FakeResponse({"content": {"path": "README.md", "sha": "newsha", "html_url": "https://git.bratonien.de/alice/demo/src/branch/main/README.md"}, "commit": {"sha": "commitsha"}})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("update_file", {"owner": "alice", "repo": "demo", "path": "README.md", "branch": "main", "sha": "oldsha", "content": "# LANELA\n", "message": "README erweitern"})
        self.assertEqual(captured["method"], "PUT")
        self.assertEqual(__import__("base64").b64decode(captured["body"]["content"]).decode(), "# LANELA\n")
        self.assertEqual(result["commit_sha"], "commitsha")

    def test_create_file_uses_post_and_base64(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["method"] = request.get_method()
            captured["body"] = json.loads(request.data)
            return FakeResponse({"content": {"path": "docs/new.md", "sha": "newsha"}, "commit": {"sha": "commitsha"}})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("create_file", {"owner": "alice", "repo": "demo", "path": "docs/new.md", "branch": "main", "content": "Neu\n", "message": "Datei anlegen"})
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(__import__("base64").b64decode(captured["body"]["content"]).decode(), "Neu\n")
        self.assertEqual(result["path"], "docs/new.md")

    def test_delete_file_uses_delete_with_current_sha(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["method"] = request.get_method()
            captured["body"] = json.loads(request.data)
            return FakeResponse({"commit": {"sha": "commitsha", "html_url": "https://git.bratonien.de/alice/demo/commit/commitsha"}})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("delete_file", {"owner": "alice", "repo": "demo", "path": "old.md", "branch": "main", "sha": "oldsha", "message": "Datei entfernen"})
        self.assertEqual(captured["method"], "DELETE")
        self.assertEqual(captured["body"]["sha"], "oldsha")
        self.assertTrue(result["deleted"])

    def test_create_issue_uses_post_and_compacts_result(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["method"] = request.get_method()
            captured["body"] = json.loads(request.data)
            return FakeResponse({"id": 12, "number": 3, "title": "Bug", "state": "open", "user": {"login": "alice"}, "labels": [], "assignees": [], "html_url": "https://git.bratonien.de/alice/demo/issues/3"})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("create_issue", {"owner": "alice", "repo": "demo", "title": "Bug", "body": "Details"})
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["body"], {"title": "Bug", "body": "Details"})
        self.assertEqual(result["number"], 3)

    def test_create_pull_request_rejects_same_branch(self):
        with self.assertRaises(server.ToolError):
            server.call_tool("create_pull_request", {"owner": "alice", "repo": "demo", "head": "main", "base": "main", "title": "PR"})

    def test_create_branch_uses_catalog_endpoint(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["url"] = request.full_url
            captured["method"] = request.get_method()
            captured["body"] = json.loads(request.data)
            return FakeResponse({"name": "feature"})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("create_branch", {"owner": "alice", "repo": "demo", "new_branch_name": "feature", "old_ref_name": "main"})
        self.assertEqual(captured["method"], "POST")
        self.assertTrue(captured["url"].endswith("/repos/alice/demo/branches"))
        self.assertEqual(captured["body"]["old_ref_name"], "main")
        self.assertEqual(result["name"], "feature")

    def test_update_issue_requires_a_change(self):
        with self.assertRaises(server.ToolError):
            server.call_tool("update_issue", {"owner": "alice", "repo": "demo", "index": 2})

    def test_merge_pull_request_binds_head_commit(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["body"] = json.loads(request.data)
            return FakeResponse({"merged": True})

        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("merge_pull_request", {"owner": "alice", "repo": "demo", "index": 4, "method": "squash", "head_commit_id": "abc123"})
        self.assertEqual(captured["body"]["Do"], "squash")
        self.assertEqual(captured["body"]["head_commit_id"], "abc123")
        self.assertTrue(result["merged"])

    def test_change_files_encodes_content_and_requires_sha(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["body"] = json.loads(request.data)
            return FakeResponse({"commit": {"sha": "commitsha"}})

        args = {"owner": "alice", "repo": "demo", "branch": "main", "message": "Mehrere Dateien", "files": [
            {"operation": "create", "path": "new.txt", "content": "Neu"},
            {"operation": "update", "path": "old.txt", "sha": "oldsha", "content": "Geändert"},
        ]}
        with patch.dict(os.environ, {"GITEA_TOKEN": "secret-token"}, clear=True), patch.object(server, "urlopen", fake_urlopen):
            result = server.call_tool("change_files", args)
        files = captured["body"]["files"]
        self.assertEqual(__import__("base64").b64decode(files[0]["content"]).decode(), "Neu")
        self.assertEqual(files[1]["sha"], "oldsha")
        self.assertEqual(result["commit"]["sha"], "commitsha")

        with self.assertRaises(server.ToolError):
            server.call_tool("change_files", {**args, "files": [{"operation": "delete", "path": "old.txt"}]})


if __name__ == "__main__":
    unittest.main()
