from __future__ import annotations

"""Stable MCP surface for Manifold administration and automation."""

from operations import API, DELETE_ANNOTATIONS, OPERATIONS, QUERY_SCHEMA, READ_ANNOTATIONS, WRITE_ANNOTATIONS, object_schema, string_schema

# Manifold exposes resource and resource-collection creation through project
# relationships, but show/update/destroy as top-level member routes. Keep those
# member routes explicit in the stable management surface.
_missing_member_routes = (
    ("get_resource", "GET", API + "/resources/{id}", "Get one Manifold resource.", False, READ_ANNOTATIONS),
    ("update_resource", "PATCH", API + "/resources/{id}", "Update a Manifold resource.", True, WRITE_ANNOTATIONS),
    ("delete_resource", "DELETE", API + "/resources/{id}", "Delete a Manifold resource.", True, DELETE_ANNOTATIONS),
    ("get_resource_collection", "GET", API + "/resource_collections/{id}", "Get one Manifold resource collection.", False, READ_ANNOTATIONS),
    ("update_resource_collection", "PATCH", API + "/resource_collections/{id}", "Update a Manifold resource collection.", True, WRITE_ANNOTATIONS),
    ("delete_resource_collection", "DELETE", API + "/resource_collections/{id}", "Delete a Manifold resource collection.", True, DELETE_ANNOTATIONS),
)

for name, method, path, description, body, annotation in _missing_member_routes:
    if any(op["name"] == name for op in OPERATIONS):
        continue
    properties = {"id": string_schema("Path parameter id."), "query": QUERY_SCHEMA}
    if body:
        properties["body"] = {"description": "Optional JSON-compatible request body passed to Manifold unchanged."}
    OPERATIONS.append({
        "name": name,
        "method": method,
        "path": path,
        "description": description,
        "inputSchema": object_schema(properties, ["id"]),
        "annotations": annotation,
    })

EXCLUDED_TOOLS = {
    "health",
    "api_health",
    "head_ping",
    "get_proxy_ingestion_source",
    "create_token",
    "delete_me",
}

OPERATIONS = [op for op in OPERATIONS if op["name"] not in EXCLUDED_TOOLS]
OPERATION_BY_NAME = {op["name"]: op for op in OPERATIONS}
TOOLS = [
    {
        "name": op["name"],
        "title": op["name"].replace("_", " ").title(),
        "description": op["description"],
        "inputSchema": op["inputSchema"],
        "annotations": op["annotations"],
    }
    for op in OPERATIONS
]

REQUIRED_MANAGEMENT_TOOLS = {
    "whoami", "ping", "search_results", "get_statistics",
    "list_projects", "get_project", "create_project", "update_project", "delete_project",
    "list_texts", "get_text", "create_text", "update_text", "delete_text",
    "create_project_text", "create_text_text_section", "update_text_section", "delete_text_section",
    "create_project_ingestion", "get_ingestion", "update_ingestion", "process_ingestion", "reset_ingestion", "reingest_ingestion",
    "create_project_resource", "get_resource", "update_resource", "delete_resource",
    "create_project_resource_collection", "get_resource_collection", "update_resource_collection", "delete_resource_collection",
    "tus_create_upload", "tus_head_upload", "tus_patch_upload",
    "list_journals", "get_journal", "create_journal", "update_journal", "delete_journal",
    "create_journal_journal_issue", "create_journal_journal_volume",
    "list_reading_groups", "get_reading_group", "create_reading_group", "update_reading_group", "delete_reading_group",
    "clone_reading_group", "join_reading_group",
    "list_comments", "get_comment", "update_comment", "delete_comment",
    "list_annotations", "get_annotation", "update_annotation", "delete_annotation",
    "list_users", "get_user", "create_user", "update_user", "delete_user",
    "list_user_groups", "get_user_group", "create_user_group", "update_user_group", "delete_user_group",
    "list_project_permissions", "create_project_permission", "update_project_permission", "delete_project_permission",
    "admin_reset_password", "get_settings", "update_settings",
    "list_project_exportations", "create_project_exportation", "api_call",
}

_missing = REQUIRED_MANAGEMENT_TOOLS.difference(OPERATION_BY_NAME)
if _missing:
    raise RuntimeError("Management surface is incomplete: " + ", ".join(sorted(_missing)))
