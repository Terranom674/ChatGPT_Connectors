#!/usr/bin/env python3
"""Dependency-free MCP server for controlled Gitea reads and writes."""

import base64
import json
import os
import sys
from contextvars import ContextVar
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


SERVER_NAME = "bratonien-gitea"
SERVER_VERSION = "1.0.0"
GITEA_ORIGIN = "https://git.bratonien.de"
API_BASE = GITEA_ORIGIN + "/api/v1"
MAX_PAGE_SIZE = 50
CURRENT_GITEA_OAUTH_TOKEN = ContextVar("current_gitea_oauth_token", default=None)


with (Path(__file__).resolve().parent / "operations.json").open(encoding="utf-8") as operation_file:
    OPERATION_CATALOG = json.load(operation_file)
ALLOWED_OPERATIONS = OPERATION_CATALOG["operations"]


class ToolError(Exception):
    """A safe error that can be shown to the model."""


def string_schema(description: str) -> Dict[str, Any]:
    return {"type": "string", "minLength": 1, "description": description}


PAGE_PROPERTIES = {
    "page": {"type": "integer", "minimum": 1, "default": 1},
    "limit": {"type": "integer", "minimum": 1, "maximum": MAX_PAGE_SIZE, "default": 20},
}


def object_schema(properties: Dict[str, Any], required: Optional[List[str]] = None) -> Dict[str, Any]:
    schema: Dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


READ_ANNOTATIONS = {
    "readOnlyHint": True,
    "destructiveHint": False,
    "idempotentHint": True,
    "openWorldHint": False,
}

WRITE_ANNOTATIONS = {
    "readOnlyHint": False,
    "destructiveHint": False,
    "idempotentHint": False,
    "openWorldHint": True,
}

DELETE_ANNOTATIONS = {
    "readOnlyHint": False,
    "destructiveHint": True,
    "idempotentHint": False,
    "openWorldHint": True,
}


TOOLS = [
    {
        "name": "list_repositories",
        "title": "List Gitea repositories",
        "description": "List repositories visible to the authenticated user on git.bratonien.de.",
        "inputSchema": object_schema({**PAGE_PROPERTIES}),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "get_repository",
        "title": "Get a Gitea repository",
        "description": "Get one repository by its explicit owner and repository name.",
        "inputSchema": object_schema({"owner": string_schema("Repository owner."), "repo": string_schema("Repository name.")}, ["owner", "repo"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "list_branches",
        "title": "List repository branches",
        "description": "List branches in one repository on git.bratonien.de.",
        "inputSchema": object_schema({"owner": string_schema("Repository owner."), "repo": string_schema("Repository name."), **PAGE_PROPERTIES}, ["owner", "repo"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "list_commits",
        "title": "List repository commits",
        "description": "List commits in one repository, optionally filtered by branch, SHA, or path.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "sha": string_schema("Optional branch name or commit SHA."), "path": string_schema("Optional repository path."),
            **PAGE_PROPERTIES,
        }, ["owner", "repo"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "list_issues",
        "title": "List repository issues",
        "description": "List issues in one repository. Pull requests are excluded from the result.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "state": {"type": "string", "enum": ["open", "closed", "all"]},
            "labels": {"type": "string", "description": "Comma-separated label names."}, **PAGE_PROPERTIES,
        }, ["owner", "repo"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "get_issue",
        "title": "Get a repository issue",
        "description": "Get one issue by repository owner, repository name, and issue number.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "index": {"type": "integer", "minimum": 1, "description": "Issue number."},
        }, ["owner", "repo", "index"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "list_pull_requests",
        "title": "List repository pull requests",
        "description": "List pull requests in one repository on git.bratonien.de.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "state": {"type": "string", "enum": ["open", "closed", "all"]},
            "sort": {"type": "string", "enum": ["oldest", "recentupdate", "recentclose", "leastupdate", "mostcomment", "leastcomment", "priority"]},
            **PAGE_PROPERTIES,
        }, ["owner", "repo"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "get_pull_request",
        "title": "Get a repository pull request",
        "description": "Get one pull request by repository owner, repository name, and pull request number.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "index": {"type": "integer", "minimum": 1, "description": "Pull request number."},
        }, ["owner", "repo", "index"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "get_file",
        "title": "Get a repository file",
        "description": "Read one existing UTF-8 text file from an explicit branch or commit.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "path": string_schema("Repository-relative file path."), "ref": string_schema("Branch name or commit SHA."),
        }, ["owner", "repo", "path", "ref"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "create_issue",
        "title": "Create a Gitea issue",
        "description": "Create an issue after the user confirms the exact repository, title, and body.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "title": {"type": "string", "minLength": 1, "maxLength": 255},
            "body": {"type": "string", "maxLength": 100000},
            "assignees": {"type": "array", "items": string_schema("Gitea username."), "maxItems": 10},
            "label_ids": {"type": "array", "items": {"type": "integer", "minimum": 1}, "maxItems": 20},
        }, ["owner", "repo", "title"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "comment_on_issue",
        "title": "Comment on a Gitea issue",
        "description": "Add a comment to an issue or pull request after the user confirms the exact target and text.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "index": {"type": "integer", "minimum": 1},
            "body": {"type": "string", "minLength": 1, "maxLength": 100000},
        }, ["owner", "repo", "index", "body"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "create_pull_request",
        "title": "Create a Gitea pull request",
        "description": "Create a pull request after the user confirms its repository, branches, title, and body.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "head": string_schema("Existing source branch."), "base": string_schema("Existing target branch."),
            "title": {"type": "string", "minLength": 1, "maxLength": 255},
            "body": {"type": "string", "maxLength": 100000},
            "assignees": {"type": "array", "items": string_schema("Gitea username."), "maxItems": 10},
            "reviewers": {"type": "array", "items": string_schema("Gitea username."), "maxItems": 10},
            "label_ids": {"type": "array", "items": {"type": "integer", "minimum": 1}, "maxItems": 20},
        }, ["owner", "repo", "head", "base", "title"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "update_file",
        "title": "Update a repository file",
        "description": "Replace one existing UTF-8 text file after the user confirms the target, complete content, and commit message.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "path": string_schema("Repository-relative path of an existing file."),
            "branch": string_schema("Existing branch to update."),
            "sha": string_schema("Current file SHA returned by get_file."),
            "content": {"type": "string", "maxLength": 1000000, "description": "Complete replacement content as UTF-8 text."},
            "message": {"type": "string", "minLength": 1, "maxLength": 255, "description": "Commit message."},
        }, ["owner", "repo", "path", "branch", "sha", "content", "message"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "create_file",
        "title": "Create a repository file",
        "description": "Create one new UTF-8 text file after the user confirms the target, complete content, and commit message.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "path": string_schema("Repository-relative path of the new file."),
            "branch": string_schema("Existing branch in which to create the file."),
            "content": {"type": "string", "maxLength": 1000000, "description": "Complete file content as UTF-8 text."},
            "message": {"type": "string", "minLength": 1, "maxLength": 255, "description": "Commit message."},
        }, ["owner", "repo", "path", "branch", "content", "message"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "delete_file",
        "title": "Delete a repository file",
        "description": "Delete one existing file after the user confirms the exact target and commit message.",
        "inputSchema": object_schema({
            "owner": string_schema("Repository owner."), "repo": string_schema("Repository name."),
            "path": string_schema("Repository-relative path of the existing file."),
            "branch": string_schema("Existing branch from which to delete the file."),
            "sha": string_schema("Current file SHA returned by get_file."),
            "message": {"type": "string", "minLength": 1, "maxLength": 255, "description": "Commit message."},
        }, ["owner", "repo", "path", "branch", "sha", "message"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "list_available_operations",
        "title": "List available Gitea operations",
        "description": "List permitted non-security-sensitive Gitea API operations, optionally filtered by category or text.",
        "inputSchema": object_schema({
            "category": {"type": "string", "enum": ["repository", "issue", "notification", "package", "miscellaneous"]},
            "search": {"type": "string", "maxLength": 100},
            "method": {"type": "string", "enum": ["GET", "POST", "PUT", "PATCH", "DELETE"]},
        }),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "describe_operation",
        "title": "Describe a Gitea operation",
        "description": "Show the exact path, method, parameters, and request-body schema for one permitted operation.",
        "inputSchema": object_schema({"operation_id": string_schema("Operation ID returned by list_available_operations.")}, ["operation_id"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "execute_operation",
        "title": "Execute a permitted Gitea operation",
        "description": "Execute one allowlisted Gitea operation. Any write or deletion requires explicit user confirmation first.",
        "inputSchema": object_schema({
            "operation_id": string_schema("Permitted operation ID."),
            "path_parameters": {"type": "object", "additionalProperties": {"type": ["string", "integer"]}},
            "query_parameters": {"type": "object", "additionalProperties": True},
            "body": {"type": "object", "additionalProperties": True},
        }, ["operation_id"]),
        "annotations": DELETE_ANNOTATIONS,
    },
]

REPO_TOOL_PROPERTIES = {"owner": string_schema("Repository owner."), "repo": string_schema("Repository name.")}
INDEX_SCHEMA = {"type": "integer", "minimum": 1}

TOOLS.extend([
    {
        "name": "create_branch", "title": "Create a branch",
        "description": "Create a branch from an existing branch, tag, or commit after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "new_branch_name": string_schema("New branch name."), "old_ref_name": string_schema("Existing source branch, tag, or commit SHA.")}, ["owner", "repo", "new_branch_name", "old_ref_name"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "delete_branch", "title": "Delete a branch",
        "description": "Delete an existing branch after explicit confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "branch": string_schema("Existing branch name.")}, ["owner", "repo", "branch"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "create_tag", "title": "Create a tag",
        "description": "Create a Git tag on an existing branch or commit after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "tag_name": string_schema("New tag name."), "target": string_schema("Existing branch or commit SHA."), "message": {"type": "string", "maxLength": 10000}}, ["owner", "repo", "tag_name", "target"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "delete_tag", "title": "Delete a tag",
        "description": "Delete an existing Git tag after explicit confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "tag": string_schema("Existing tag name.")}, ["owner", "repo", "tag"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "update_issue", "title": "Update an issue",
        "description": "Update an issue title, body, state, or milestone after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "index": INDEX_SCHEMA, "title": {"type": "string", "minLength": 1, "maxLength": 255}, "body": {"type": "string", "maxLength": 100000}, "state": {"type": "string", "enum": ["open", "closed"]}, "milestone": {"type": "integer", "minimum": 0}}, ["owner", "repo", "index"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "delete_issue", "title": "Delete an issue",
        "description": "Permanently delete an issue after explicit confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "index": INDEX_SCHEMA}, ["owner", "repo", "index"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "update_pull_request", "title": "Update a pull request",
        "description": "Update a pull request title, body, base, state, or milestone after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "index": INDEX_SCHEMA, "title": {"type": "string", "minLength": 1, "maxLength": 255}, "body": {"type": "string", "maxLength": 100000}, "base": string_schema("Existing target branch."), "state": {"type": "string", "enum": ["open", "closed"]}, "milestone": {"type": "integer", "minimum": 0}}, ["owner", "repo", "index"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "merge_pull_request", "title": "Merge a pull request",
        "description": "Merge a pull request at an explicitly confirmed head commit.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "index": INDEX_SCHEMA, "method": {"type": "string", "enum": ["merge", "rebase", "rebase-merge", "squash", "fast-forward-only"]}, "head_commit_id": string_schema("Confirmed current head commit SHA."), "title": {"type": "string", "maxLength": 255}, "message": {"type": "string", "maxLength": 100000}, "delete_branch_after_merge": {"type": "boolean", "default": False}}, ["owner", "repo", "index", "method", "head_commit_id"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "review_pull_request", "title": "Review a pull request",
        "description": "Submit an approval, comment, or change request after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "index": INDEX_SCHEMA, "event": {"type": "string", "enum": ["APPROVED", "COMMENT", "REQUEST_CHANGES"]}, "body": {"type": "string", "maxLength": 100000}, "commit_id": string_schema("Reviewed head commit SHA.")}, ["owner", "repo", "index", "event", "commit_id"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "list_releases", "title": "List releases",
        "description": "List repository releases.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, **PAGE_PROPERTIES}, ["owner", "repo"]),
        "annotations": READ_ANNOTATIONS,
    },
    {
        "name": "create_release", "title": "Create a release",
        "description": "Create a release for a tag after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "tag_name": string_schema("Existing or new tag name."), "target_commitish": string_schema("Target branch or commit."), "name": {"type": "string", "maxLength": 255}, "body": {"type": "string", "maxLength": 100000}, "draft": {"type": "boolean", "default": False}, "prerelease": {"type": "boolean", "default": False}}, ["owner", "repo", "tag_name", "target_commitish"]),
        "annotations": WRITE_ANNOTATIONS,
    },
    {
        "name": "update_release", "title": "Update a release",
        "description": "Update an existing release after confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "id": INDEX_SCHEMA, "tag_name": string_schema("Tag name."), "target_commitish": string_schema("Target branch or commit."), "name": {"type": "string", "maxLength": 255}, "body": {"type": "string", "maxLength": 100000}, "draft": {"type": "boolean"}, "prerelease": {"type": "boolean"}}, ["owner", "repo", "id"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "delete_release", "title": "Delete a release",
        "description": "Permanently delete a release after explicit confirmation.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "id": INDEX_SCHEMA}, ["owner", "repo", "id"]),
        "annotations": DELETE_ANNOTATIONS,
    },
    {
        "name": "change_files", "title": "Change multiple files",
        "description": "Create, update, move, or delete multiple text files in one confirmed commit.",
        "inputSchema": object_schema({**REPO_TOOL_PROPERTIES, "branch": string_schema("Existing branch."), "message": {"type": "string", "minLength": 1, "maxLength": 255}, "files": {"type": "array", "minItems": 1, "maxItems": 50, "items": object_schema({"operation": {"type": "string", "enum": ["create", "update", "delete"]}, "path": string_schema("Destination or existing repository-relative path."), "from_path": string_schema("Existing path when moving a file."), "sha": string_schema("Current SHA required for update or delete."), "content": {"type": "string", "maxLength": 1000000}}, ["operation", "path"])}}, ["owner", "repo", "branch", "message", "files"]),
        "annotations": DELETE_ANNOTATIONS,
    },
])


def validate_segment(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ToolError("%s must be a non-empty string." % field)
    value = value.strip()
    if len(value) > 255 or value in (".", "..") or "/" in value or "\\" in value:
        raise ToolError("%s is invalid." % field)
    return value


def page_params(arguments: Dict[str, Any]) -> Dict[str, Any]:
    page = arguments.get("page", 1)
    limit = arguments.get("limit", 20)
    if not isinstance(page, int) or isinstance(page, bool) or page < 1:
        raise ToolError("page must be an integer greater than zero.")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_PAGE_SIZE:
        raise ToolError("limit must be between 1 and %d." % MAX_PAGE_SIZE)
    return {"page": page, "limit": limit}


def compact_user(value: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(value, dict):
        return None
    return {"id": value.get("id"), "login": value.get("login"), "full_name": value.get("full_name")}


def compact_repo(repo: Dict[str, Any], detailed: bool = False) -> Dict[str, Any]:
    result = {
        "id": repo.get("id"), "owner": (repo.get("owner") or {}).get("login"), "name": repo.get("name"),
        "full_name": repo.get("full_name"), "private": repo.get("private"), "default_branch": repo.get("default_branch"),
        "updated_at": repo.get("updated_at"), "html_url": repo.get("html_url"),
    }
    if detailed:
        result.update({
            "description": repo.get("description"), "archived": repo.get("archived"), "empty": repo.get("empty"),
            "has_issues": repo.get("has_issues"), "has_pull_requests": repo.get("has_pull_requests"),
        })
    return result


def compact_issue(issue: Dict[str, Any], detailed: bool = False) -> Dict[str, Any]:
    result = {
        "id": issue.get("id"), "number": issue.get("number"), "title": issue.get("title"), "state": issue.get("state"),
        "author": compact_user(issue.get("user")), "labels": [x.get("name") for x in (issue.get("labels") or []) if isinstance(x, dict)],
        "assignees": [compact_user(x) for x in (issue.get("assignees") or []) if isinstance(x, dict)],
        "created_at": issue.get("created_at"), "updated_at": issue.get("updated_at"), "closed_at": issue.get("closed_at"),
        "html_url": issue.get("html_url"),
    }
    if detailed:
        result.update({"body": issue.get("body"), "milestone": issue.get("milestone")})
    return result


def compact_pull(pull: Dict[str, Any], detailed: bool = False) -> Dict[str, Any]:
    def ref(value: Any) -> Optional[Dict[str, Any]]:
        if not isinstance(value, dict):
            return None
        return {"ref": value.get("ref"), "sha": value.get("sha"), "repo": (value.get("repo") or {}).get("full_name")}

    result = {
        "id": pull.get("id"), "number": pull.get("number"), "title": pull.get("title"), "state": pull.get("state"),
        "draft": pull.get("draft"), "author": compact_user(pull.get("user")), "head": ref(pull.get("head")), "base": ref(pull.get("base")),
        "mergeable": pull.get("mergeable"), "merged": pull.get("merged"), "created_at": pull.get("created_at"),
        "updated_at": pull.get("updated_at"), "closed_at": pull.get("closed_at"), "merged_at": pull.get("merged_at"),
        "html_url": pull.get("html_url"),
    }
    if detailed:
        result.update({
            "body": pull.get("body"), "labels": [x.get("name") for x in (pull.get("labels") or []) if isinstance(x, dict)],
            "assignees": [compact_user(x) for x in (pull.get("assignees") or []) if isinstance(x, dict)],
            "requested_reviewers": [compact_user(x) for x in (pull.get("requested_reviewers") or []) if isinstance(x, dict)],
            "merge_base": pull.get("merge_base"),
        })
    return result


def api_request(path: str, method: str = "GET", params: Optional[Dict[str, Any]] = None, body: Optional[Dict[str, Any]] = None) -> Any:
    oauth_token = CURRENT_GITEA_OAUTH_TOKEN.get()
    token = oauth_token or os.environ.get("GITEA_TOKEN", "").strip()
    if not token:
        raise ToolError("GITEA_TOKEN is not configured for the connector.")
    url = API_BASE + path
    if params:
        clean = {key: value for key, value in params.items() if value is not None}
        if clean:
            url += "?" + urlencode(clean)
    authorization = ("bearer " if oauth_token else "token ") + token
    headers = {"Accept": "application/json", "Authorization": authorization, "User-Agent": SERVER_NAME + "/" + SERVER_VERSION}
    payload = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        payload = json.dumps(body).encode("utf-8")
    request = Request(url, data=payload, headers=headers, method=method)
    try:
        with urlopen(request, timeout=20) as response:
            raw = response.read(2000001)
            if len(raw) > 2000000:
                raise ToolError("Gitea returned more than the connector's 2 MB response limit.")
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except HTTPError as exc:
        messages = {401: "Gitea rejected the configured token.", 403: "The Gitea account is not allowed to perform this operation.", 404: "The requested Gitea resource was not found."}
        raise ToolError(messages.get(exc.code, "Gitea returned HTTP %d." % exc.code))
    except URLError:
        raise ToolError("git.bratonien.de could not be reached.")
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ToolError("Gitea returned an invalid JSON response.")


def api_get(path: str, params: Optional[Dict[str, Any]] = None) -> Any:
    return api_request(path, "GET", params=params)


def api_post(path: str, body: Dict[str, Any]) -> Any:
    return api_request(path, "POST", body=body)


def api_put(path: str, body: Dict[str, Any]) -> Any:
    return api_request(path, "PUT", body=body)


def api_delete(path: str, body: Dict[str, Any]) -> Any:
    return api_request(path, "DELETE", body=body)


def required_text(arguments: Dict[str, Any], field: str, maximum: int) -> str:
    value = arguments.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ToolError("%s must be a non-empty string." % field)
    if len(value) > maximum:
        raise ToolError("%s exceeds the maximum length of %d characters." % (field, maximum))
    return value


def optional_text(arguments: Dict[str, Any], field: str, maximum: int) -> Optional[str]:
    value = arguments.get(field)
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > maximum:
        raise ToolError("%s must be a string with at most %d characters." % (field, maximum))
    return value


def repo_path(arguments: Dict[str, Any], suffix: str = "") -> str:
    owner = quote(validate_segment(arguments.get("owner"), "owner"), safe="")
    repo = quote(validate_segment(arguments.get("repo"), "repo"), safe="")
    return "/repos/%s/%s%s" % (owner, repo, suffix)


def file_path(arguments: Dict[str, Any]) -> str:
    value = validate_repo_file_path(arguments.get("path"))
    return "/contents/" + "/".join(quote(part, safe="") for part in value.split("/"))


def validate_repo_file_path(value: Any) -> str:
    if not isinstance(value, str) or not value or value.startswith("/") or value.endswith("/") or "\\" in value:
        raise ToolError("path must be a repository-relative file path.")
    parts = value.split("/")
    if any(not part or part in (".", "..") for part in parts):
        raise ToolError("path must be a repository-relative file path.")
    if len(value) > 4096:
        raise ToolError("path exceeds the maximum length of 4096 characters.")
    return value


def positive_index(arguments: Dict[str, Any], field: str = "index") -> int:
    value = arguments.get(field)
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ToolError("%s must be an integer greater than zero." % field)
    return value


def selected_fields(arguments: Dict[str, Any], names: List[str]) -> Dict[str, Any]:
    return {name: arguments[name] for name in names if name in arguments and arguments[name] is not None}


def resolve_schema(schema: Any, seen: Optional[set] = None) -> Any:
    if not isinstance(schema, dict):
        return schema
    reference = schema.get("$ref")
    if reference and reference.startswith("#/definitions/"):
        name = reference.rsplit("/", 1)[-1]
        seen = set() if seen is None else set(seen)
        if name in seen:
            return {"$ref": reference}
        seen.add(name)
        return resolve_schema(OPERATION_CATALOG.get("definitions", {}).get(name, schema), seen)
    result = {}
    for key, value in schema.items():
        if key == "properties" and isinstance(value, dict):
            result[key] = {name: resolve_schema(item, seen) for name, item in value.items()}
        elif key == "items":
            result[key] = resolve_schema(value, seen)
        else:
            result[key] = value
    return result


def operation_details(operation_id: Any) -> Dict[str, Any]:
    if not isinstance(operation_id, str) or operation_id not in ALLOWED_OPERATIONS:
        raise ToolError("operation_id is not in the permitted Gitea operation catalog.")
    details = dict(ALLOWED_OPERATIONS[operation_id])
    if details.get("bodySchema"):
        details["bodySchema"] = resolve_schema(details["bodySchema"])
    details["operation_id"] = operation_id
    return details


REDACTED_RESPONSE_KEYS = {
    "authorization", "password", "passwd", "token", "secret", "login_name", "source_id",
    "email", "is_admin", "last_login", "prohibit_login", "permissions",
}


def sanitize_response(value: Any) -> Any:
    if isinstance(value, list):
        return [sanitize_response(item) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            lowered = str(key).casefold()
            if lowered in REDACTED_RESPONSE_KEYS or any(word in lowered for word in ("password", "token", "secret")):
                continue
            result[key] = sanitize_response(item)
        return result
    return value


def execute_catalog_operation(arguments: Dict[str, Any]) -> Any:
    details = operation_details(arguments.get("operation_id"))
    supplied_path = arguments.get("path_parameters") or {}
    supplied_query = arguments.get("query_parameters") or {}
    body = arguments.get("body")
    if not isinstance(supplied_path, dict) or not isinstance(supplied_query, dict):
        raise ToolError("path_parameters and query_parameters must be objects.")
    path = details["path"]
    allowed_query = set()
    for parameter in details.get("parameters", []):
        location = parameter.get("in")
        name = parameter.get("name")
        if location == "path":
            if name not in supplied_path:
                raise ToolError("Missing path parameter: %s" % name)
            value = supplied_path[name]
            if not isinstance(value, (str, int)) or isinstance(value, bool):
                raise ToolError("Path parameter %s must be text or an integer." % name)
            path = path.replace("{%s}" % name, quote(str(value), safe=""))
        elif location == "query":
            allowed_query.add(name)
            if parameter.get("required") and name not in supplied_query:
                raise ToolError("Missing query parameter: %s" % name)
        elif location == "body" and parameter.get("required") and not isinstance(body, dict):
            raise ToolError("This operation requires a body object.")
    unexpected = set(supplied_query) - allowed_query
    if unexpected:
        raise ToolError("Unsupported query parameter(s): %s" % ", ".join(sorted(unexpected)))
    if body is not None and not isinstance(body, dict):
        raise ToolError("body must be an object.")
    return sanitize_response(api_request(path, details["method"], params=supplied_query, body=body))


def catalog_call(operation_id: str, arguments: Dict[str, Any], path_names: List[str], body: Optional[Dict[str, Any]] = None, query: Optional[Dict[str, Any]] = None) -> Any:
    return execute_catalog_operation({
        "operation_id": operation_id,
        "path_parameters": {name: arguments[name] for name in path_names},
        "query_parameters": query or {},
        **({"body": body} if body is not None else {}),
    })


def call_tool(name: str, arguments: Dict[str, Any]) -> Any:
    if not isinstance(arguments, dict):
        raise ToolError("Tool arguments must be an object.")
    if name == "list_repositories":
        return [compact_repo(item) for item in api_get("/user/repos", page_params(arguments))]
    if name == "list_available_operations":
        category = arguments.get("category")
        method = arguments.get("method")
        search = arguments.get("search", "")
        if not isinstance(search, str) or len(search) > 100:
            raise ToolError("search must be text with at most 100 characters.")
        needle = search.casefold()
        result = []
        for operation_id, details in ALLOWED_OPERATIONS.items():
            if category and details.get("tag") != category:
                continue
            if method and details.get("method") != method:
                continue
            if needle and needle not in (operation_id + " " + details.get("summary", "") + " " + details.get("path", "")).casefold():
                continue
            result.append({"operation_id": operation_id, "method": details.get("method"), "category": details.get("tag"), "summary": details.get("summary"), "path": details.get("path")})
        return {"count": len(result), "operations": result}
    if name == "describe_operation":
        return operation_details(arguments.get("operation_id"))
    if name == "execute_operation":
        return execute_catalog_operation(arguments)
    if name == "get_repository":
        return compact_repo(api_get(repo_path(arguments)), detailed=True)
    if name == "list_branches":
        data = api_get(repo_path(arguments, "/branches"), page_params(arguments))
        return [{"name": x.get("name"), "commit_id": (x.get("commit") or {}).get("id"), "protected": x.get("protected"), "user_can_push": x.get("user_can_push"), "user_can_merge": x.get("user_can_merge")} for x in data]
    if name == "list_commits":
        params = {**page_params(arguments), "sha": arguments.get("sha"), "path": arguments.get("path")}
        data = api_get(repo_path(arguments, "/commits"), params)
        return [{
            "sha": x.get("sha"), "message": ((x.get("commit") or {}).get("message")),
            "author": (x.get("commit") or {}).get("author"), "committer": (x.get("commit") or {}).get("committer"),
            "html_url": x.get("html_url"),
        } for x in data]
    if name == "list_issues":
        params = {**page_params(arguments), "state": arguments.get("state", "open"), "labels": arguments.get("labels"), "type": "issues"}
        data = api_get(repo_path(arguments, "/issues"), params)
        return [compact_issue(x) for x in data if not x.get("pull_request")]
    if name == "get_issue":
        index = arguments.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or index < 1:
            raise ToolError("index must be an integer greater than zero.")
        data = api_get(repo_path(arguments, "/issues/%d" % index))
        if data.get("pull_request"):
            raise ToolError("The requested number belongs to a pull request, not an issue.")
        return compact_issue(data, detailed=True)
    if name == "list_pull_requests":
        params = {**page_params(arguments), "state": arguments.get("state", "open"), "sort": arguments.get("sort")}
        return [compact_pull(x) for x in api_get(repo_path(arguments, "/pulls"), params)]
    if name == "get_pull_request":
        index = arguments.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or index < 1:
            raise ToolError("index must be an integer greater than zero.")
        return compact_pull(api_get(repo_path(arguments, "/pulls/%d" % index)), detailed=True)
    if name == "get_file":
        ref = validate_segment(arguments.get("ref"), "ref")
        data = api_get(repo_path(arguments, file_path(arguments)), {"ref": ref})
        if data.get("type") != "file" or data.get("encoding") != "base64":
            raise ToolError("The requested path is not a readable text file.")
        try:
            content = base64.b64decode(data.get("content", ""), validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            raise ToolError("The requested file is not valid UTF-8 text.")
        return {"name": data.get("name"), "path": data.get("path"), "sha": data.get("sha"), "size": data.get("size"), "content": content, "html_url": data.get("html_url"), "last_commit_sha": data.get("last_commit_sha")}
    if name == "create_issue":
        payload = {
            "title": required_text(arguments, "title", 255),
            "body": optional_text(arguments, "body", 100000),
            "assignees": arguments.get("assignees"),
            "labels": arguments.get("label_ids"),
        }
        return compact_issue(api_post(repo_path(arguments, "/issues"), {k: v for k, v in payload.items() if v is not None}), detailed=True)
    if name == "comment_on_issue":
        index = arguments.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or index < 1:
            raise ToolError("index must be an integer greater than zero.")
        data = api_post(repo_path(arguments, "/issues/%d/comments" % index), {"body": required_text(arguments, "body", 100000)})
        return {"id": data.get("id"), "body": data.get("body"), "author": compact_user(data.get("user")), "created_at": data.get("created_at"), "html_url": data.get("html_url")}
    if name == "create_pull_request":
        head = validate_segment(arguments.get("head"), "head")
        base = validate_segment(arguments.get("base"), "base")
        if head == base:
            raise ToolError("head and base must be different branches.")
        payload = {
            "head": head, "base": base,
            "title": required_text(arguments, "title", 255),
            "body": optional_text(arguments, "body", 100000),
            "assignees": arguments.get("assignees"),
            "reviewers": arguments.get("reviewers"),
            "labels": arguments.get("label_ids"),
        }
        return compact_pull(api_post(repo_path(arguments, "/pulls"), {k: v for k, v in payload.items() if v is not None}), detailed=True)
    if name == "update_file":
        branch = validate_segment(arguments.get("branch"), "branch")
        sha = validate_segment(arguments.get("sha"), "sha")
        content = arguments.get("content")
        if not isinstance(content, str) or len(content) > 1000000:
            raise ToolError("content must be UTF-8 text with at most 1000000 characters.")
        payload = {
            "branch": branch,
            "sha": sha,
            "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
            "message": required_text(arguments, "message", 255),
        }
        data = api_put(repo_path(arguments, file_path(arguments)), payload)
        file_data = data.get("content") or {}
        commit = data.get("commit") or {}
        return {"path": file_data.get("path"), "sha": file_data.get("sha"), "commit_sha": commit.get("sha"), "html_url": file_data.get("html_url") or commit.get("html_url")}
    if name == "create_file":
        branch = validate_segment(arguments.get("branch"), "branch")
        content = arguments.get("content")
        if not isinstance(content, str) or len(content) > 1000000:
            raise ToolError("content must be UTF-8 text with at most 1000000 characters.")
        payload = {
            "branch": branch,
            "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
            "message": required_text(arguments, "message", 255),
        }
        data = api_post(repo_path(arguments, file_path(arguments)), payload)
        file_data = data.get("content") or {}
        commit = data.get("commit") or {}
        return {"path": file_data.get("path"), "sha": file_data.get("sha"), "commit_sha": commit.get("sha"), "html_url": file_data.get("html_url") or commit.get("html_url")}
    if name == "delete_file":
        payload = {
            "branch": validate_segment(arguments.get("branch"), "branch"),
            "sha": validate_segment(arguments.get("sha"), "sha"),
            "message": required_text(arguments, "message", 255),
        }
        data = api_delete(repo_path(arguments, file_path(arguments)), payload)
        commit = data.get("commit") or {}
        return {"path": arguments.get("path"), "deleted": True, "commit_sha": commit.get("sha"), "html_url": commit.get("html_url")}
    if name == "create_branch":
        body = {"new_branch_name": validate_segment(arguments.get("new_branch_name"), "new_branch_name"), "old_ref_name": validate_segment(arguments.get("old_ref_name"), "old_ref_name")}
        return catalog_call("repoCreateBranch", arguments, ["owner", "repo"], body)
    if name == "delete_branch":
        validate_segment(arguments.get("branch"), "branch")
        return catalog_call("repoDeleteBranch", arguments, ["owner", "repo", "branch"])
    if name == "create_tag":
        body = {"tag_name": validate_segment(arguments.get("tag_name"), "tag_name"), "target": validate_segment(arguments.get("target"), "target")}
        message = optional_text(arguments, "message", 10000)
        if message is not None:
            body["message"] = message
        return catalog_call("repoCreateTag", arguments, ["owner", "repo"], body)
    if name == "delete_tag":
        validate_segment(arguments.get("tag"), "tag")
        return catalog_call("repoDeleteTag", arguments, ["owner", "repo", "tag"])
    if name == "update_issue":
        positive_index(arguments)
        body = selected_fields(arguments, ["title", "body", "state", "milestone"])
        if not body:
            raise ToolError("At least one issue field must be supplied.")
        return compact_issue(catalog_call("issueEditIssue", arguments, ["owner", "repo", "index"], body), detailed=True)
    if name == "delete_issue":
        positive_index(arguments)
        catalog_call("issueDelete", arguments, ["owner", "repo", "index"])
        return {"number": arguments["index"], "deleted": True}
    if name == "update_pull_request":
        positive_index(arguments)
        body = selected_fields(arguments, ["title", "body", "base", "state", "milestone"])
        if not body:
            raise ToolError("At least one pull-request field must be supplied.")
        return compact_pull(catalog_call("repoEditPullRequest", arguments, ["owner", "repo", "index"], body), detailed=True)
    if name == "merge_pull_request":
        positive_index(arguments)
        body = {
            "Do": arguments.get("method"),
            "head_commit_id": validate_segment(arguments.get("head_commit_id"), "head_commit_id"),
            "delete_branch_after_merge": bool(arguments.get("delete_branch_after_merge", False)),
        }
        if arguments.get("method") not in ("merge", "rebase", "rebase-merge", "squash", "fast-forward-only"):
            raise ToolError("method is invalid.")
        if "title" in arguments:
            body["MergeTitleField"] = optional_text(arguments, "title", 255)
        if "message" in arguments:
            body["MergeMessageField"] = optional_text(arguments, "message", 100000)
        return catalog_call("repoMergePullRequest", arguments, ["owner", "repo", "index"], body)
    if name == "review_pull_request":
        positive_index(arguments)
        if arguments.get("event") not in ("APPROVED", "COMMENT", "REQUEST_CHANGES"):
            raise ToolError("event is invalid.")
        body = {"event": arguments["event"], "commit_id": validate_segment(arguments.get("commit_id"), "commit_id")}
        if "body" in arguments:
            body["body"] = optional_text(arguments, "body", 100000)
        return catalog_call("repoCreatePullReview", arguments, ["owner", "repo", "index"], body)
    if name == "list_releases":
        return catalog_call("repoListReleases", arguments, ["owner", "repo"], query=page_params(arguments))
    if name == "create_release":
        body = selected_fields(arguments, ["tag_name", "target_commitish", "name", "body", "draft", "prerelease"])
        validate_segment(arguments.get("tag_name"), "tag_name")
        validate_segment(arguments.get("target_commitish"), "target_commitish")
        return catalog_call("repoCreateRelease", arguments, ["owner", "repo"], body)
    if name == "update_release":
        positive_index(arguments, "id")
        body = selected_fields(arguments, ["tag_name", "target_commitish", "name", "body", "draft", "prerelease"])
        if not body:
            raise ToolError("At least one release field must be supplied.")
        return catalog_call("repoEditRelease", arguments, ["owner", "repo", "id"], body)
    if name == "delete_release":
        positive_index(arguments, "id")
        catalog_call("repoDeleteRelease", arguments, ["owner", "repo", "id"])
        return {"id": arguments["id"], "deleted": True}
    if name == "change_files":
        branch = validate_segment(arguments.get("branch"), "branch")
        message = required_text(arguments, "message", 255)
        files = arguments.get("files")
        if not isinstance(files, list) or not 1 <= len(files) <= 50:
            raise ToolError("files must contain between 1 and 50 operations.")
        encoded_files = []
        for item in files:
            if not isinstance(item, dict) or item.get("operation") not in ("create", "update", "delete"):
                raise ToolError("Each file operation must be create, update, or delete.")
            operation = item["operation"]
            converted = {"operation": operation, "path": validate_repo_file_path(item.get("path"))}
            if item.get("from_path") is not None:
                converted["from_path"] = validate_repo_file_path(item["from_path"])
            if operation in ("update", "delete"):
                converted["sha"] = validate_segment(item.get("sha"), "sha")
            if operation in ("create", "update"):
                content = item.get("content")
                if not isinstance(content, str) or len(content) > 1000000:
                    raise ToolError("File content must be text with at most 1000000 characters.")
                converted["content"] = base64.b64encode(content.encode("utf-8")).decode("ascii")
            encoded_files.append(converted)
        return catalog_call("repoChangeFiles", arguments, ["owner", "repo"], {"branch": branch, "message": message, "files": encoded_files})
    raise ToolError("Unknown tool: %s" % name)


def success(request_id: Any, result: Any) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def failure(request_id: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handle_message(message: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    request_id = message.get("id")
    method = message.get("method")
    if request_id is None:
        return None
    if method == "initialize":
        requested = (message.get("params") or {}).get("protocolVersion", "2025-06-18")
        return success(request_id, {
            "protocolVersion": requested,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": "Access git.bratonien.de through dedicated tools and a strict catalog of non-security-sensitive operations. Never request or expose passwords, tokens, secrets, keys, or user administration. Use describe_operation before execute_operation. Before POST, PUT, PATCH, or DELETE, show the exact target and complete change and obtain explicit confirmation. Destructive actions and merges always require explicit confirmation. Do not retry ambiguous writes.",
        })
    if method == "ping":
        return success(request_id, {})
    if method == "tools/list":
        return success(request_id, {"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params") or {}
        try:
            data = call_tool(params.get("name"), params.get("arguments") or {})
            return success(request_id, {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}], "structuredContent": {"data": data}})
        except ToolError as exc:
            return success(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
        except Exception:
            return success(request_id, {"content": [{"type": "text", "text": "The connector encountered an internal error."}], "isError": True})
    return failure(request_id, -32601, "Method not found")


def main() -> None:
    for line in sys.stdin:
        try:
            message = json.loads(line)
            response = handle_message(message)
        except (json.JSONDecodeError, TypeError):
            response = failure(None, -32700, "Parse error")
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":"), ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
