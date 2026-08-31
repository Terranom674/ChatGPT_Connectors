from __future__ import annotations

import re
from typing import Any, Dict, List

READ_ANNOTATIONS = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}
WRITE_ANNOTATIONS = {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": False}
DELETE_ANNOTATIONS = {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": True, "openWorldHint": False}

QUERY_SCHEMA = {"type": "object", "description": "Optional Manifold query parameters. Use API parameter names exactly, including filter[...] and page[...] keys.", "additionalProperties": True}
BODY_SCHEMA = {"description": "Optional JSON-compatible request body passed to Manifold unchanged."}
HEADERS_SCHEMA = {"type": "object", "description": "Optional request headers. Authorization, Host and Cookie are managed by the connector.", "additionalProperties": {"type": "string"}}

OPERATIONS: List[Dict[str, Any]] = []
OPERATION_BY_NAME: Dict[str, Dict[str, Any]] = {}


def object_schema(properties: Dict[str, Any], required=None, additional=False) -> Dict[str, Any]:
    value = {"type": "object", "properties": properties, "additionalProperties": additional}
    if required:
        value["required"] = required
    return value


def string_schema(description: str) -> Dict[str, Any]:
    return {"type": "string", "minLength": 1, "description": description}


def annotations(method: str) -> Dict[str, Any]:
    if method in {"GET", "HEAD", "OPTIONS"}:
        return READ_ANNOTATIONS
    if method == "DELETE":
        return DELETE_ANNOTATIONS
    return WRITE_ANNOTATIONS


def add(name: str, method: str, path: str, description: str, *, body=False, query=True, headers=False, raw_body=False) -> None:
    if name in OPERATION_BY_NAME:
        raise RuntimeError(f"Duplicate operation name: {name}")
    params = re.findall(r"\{([a-zA-Z0-9_]+)\}", path)
    properties: Dict[str, Any] = {p: string_schema(f"Path parameter {p}.") for p in params}
    if query:
        properties["query"] = QUERY_SCHEMA
    if body:
        properties["body"] = BODY_SCHEMA
    if headers:
        properties["headers"] = HEADERS_SCHEMA
    if raw_body:
        properties["body_base64"] = {"type": "string", "description": "Optional raw request body encoded as base64. Mutually exclusive with body."}
    op = {"name": name, "method": method, "path": path, "description": description, "inputSchema": object_schema(properties, params), "annotations": annotations(method)}
    OPERATIONS.append(op)
    OPERATION_BY_NAME[name] = op


def resource(singular: str, plural: str, path: str, actions=("index", "show", "create", "update", "destroy")) -> None:
    if "index" in actions:
        add(f"list_{plural}", "GET", path, f"List Manifold {plural}.")
    if "show" in actions:
        add(f"get_{singular}", "GET", path + "/{id}", f"Get one Manifold {singular}.")
    if "create" in actions:
        add(f"create_{singular}", "POST", path, f"Create a Manifold {singular}.", body=True)
    if "update" in actions:
        add(f"update_{singular}", "PATCH", path + "/{id}", f"Update a Manifold {singular}.", body=True)
    if "destroy" in actions:
        add(f"delete_{singular}", "DELETE", path + "/{id}", f"Delete a Manifold {singular}.", body=True)


def nested(context: str, singular: str, plural: str, path: str, actions=("index", "show", "create", "update", "destroy")) -> None:
    ps, pp = f"{context}_{singular}", f"{context}_{plural}"
    label = context.replace("_", " ")
    if "index" in actions:
        add(f"list_{pp}", "GET", path, f"List {plural} for the selected {label}.")
    if "show" in actions:
        add(f"get_{ps}", "GET", path + "/{id}", f"Get one {singular} for the selected {label}.")
    if "create" in actions:
        add(f"create_{ps}", "POST", path, f"Create a {singular} for the selected {label}.", body=True)
    if "update" in actions:
        add(f"update_{ps}", "PATCH", path + "/{id}", f"Update a {singular} for the selected {label}.", body=True)
    if "destroy" in actions:
        add(f"delete_{ps}", "DELETE", path + "/{id}", f"Delete a {singular} for the selected {label}.", body=True)


API = "/api/v1"

add("health", "GET", "/up", "Read Manifold application health.", query=False)
add("api_health", "GET", "/api/up", "Read Manifold API health.", query=False)
add("ping", "GET", API + "/ping", "Ping the Manifold API.", query=False)
add("head_ping", "HEAD", API + "/ping", "HEAD request against the Manifold API ping endpoint.", query=False)
add("get_proxy_ingestion_source", "GET", "/api/proxy/ingestion_sources/{id}", "Read an ingestion source through Manifold's proxy API.")

for plural in ("annotations", "comments", "reading_groups", "users"):
    add(f"bulk_delete_{plural}", "DELETE", API + f"/bulk_delete/{plural}", f"Bulk-delete Manifold {plural}.", body=True)

resource("action_callout", "action_callouts", API + "/action_callouts", ("show", "update", "destroy"))
resource("contact", "contacts", API + "/contacts", ("create",))
resource("content_block", "content_blocks", API + "/content_blocks", ("show", "update", "destroy"))
resource("email_confirmation", "email_confirmations", API + "/email_confirmations", ("show", "update"))
resource("test_mail", "test_mails", API + "/test_mails", ("create",))
resource("page", "pages", API + "/pages")
resource("reading_group_kind", "reading_group_kinds", API + "/reading_group_kinds")
resource("reading_group_membership", "reading_group_memberships", API + "/reading_group_memberships", ("show", "create", "update", "destroy"))
add("activate_reading_group_membership", "POST", API + "/reading_group_memberships/{id}/activate", "Activate a reading-group membership.", body=True)
add("archive_reading_group_membership", "POST", API + "/reading_group_memberships/{id}/archive", "Archive a reading-group membership.", body=True)
add("list_public_reading_groups", "GET", API + "/public_reading_groups", "List public reading groups.")

resource("reading_group", "reading_groups", API + "/reading_groups")
add("lookup_reading_groups", "GET", API + "/reading_groups/lookup", "Look up reading groups.")
add("clone_reading_group", "POST", API + "/reading_groups/{id}/clone", "Clone a reading group.", body=True)
add("join_reading_group", "POST", API + "/reading_groups/{id}/join", "Join a reading group.", body=True)
rg = API + "/reading_groups/{reading_group_id}/relationships"
nested("reading_group", "annotation", "annotations", rg + "/annotations", ("index",))
nested("reading_group", "reading_group_category", "reading_group_categories", rg + "/reading_group_categories")
nested("reading_group", "reading_group_membership", "reading_group_memberships", rg + "/reading_group_memberships", ("index",))
for singular, plural in (("project", "projects"), ("journal_issue", "journal_issues"), ("resource", "resources"), ("resource_collection", "resource_collections"), ("text", "texts"), ("text_section", "text_sections")):
    nested("reading_group", singular, plural, rg + f"/{plural}", ("index",))

resource("operation", "operations", API + "/operations", ("create",))
resource("entitlement", "entitlements", API + "/entitlements", ("index", "show", "create", "destroy"))
resource("entitlement_import", "entitlement_imports", API + "/entitlement_imports", ("index", "show", "create", "destroy"))
resource("pending_entitlement", "pending_entitlements", API + "/pending_entitlements", ("index", "show", "create", "destroy"))
resource("entitlement_target", "entitlement_targets", API + "/entitlement_targets", ("index",))
resource("export_target", "export_targets", API + "/export_targets")
resource("project_exportation", "project_exportations", API + "/project_exportations", ("index", "show", "create", "destroy"))
resource("feature", "features", API + "/features")
resource("subject", "subjects", API + "/subjects")
resource("category", "categories", API + "/categories", ("show", "update", "destroy"))
resource("maker", "makers", API + "/makers")
resource("ingestion", "ingestions", API + "/ingestions", ("show", "update"))
add("reset_ingestion", "POST", API + "/ingestions/{id}/reset", "Reset an ingestion.", body=True)
add("process_ingestion", "POST", API + "/ingestions/{id}/process", "Process an ingestion.", body=True)
add("reingest_ingestion", "POST", API + "/ingestions/{id}/reingest", "Reingest an ingestion.", body=True)
nested("ingestion", "ingestion_message", "ingestion_messages", API + "/ingestions/{ingestion_id}/relationships/ingestion_messages", ("index",))
resource("stylesheet", "stylesheets", API + "/stylesheets", ("show", "update", "destroy"))
resource("tag", "tags", API + "/tags", ("index",))
resource("event", "events", API + "/events", ("destroy",))
add("search_results", "GET", API + "/search_results", "Search Manifold and return search results.")
add("get_statistics", "GET", API + "/statistics", "Read Manifold statistics.")
add("get_settings", "GET", API + "/settings", "Read Manifold settings.")
add("update_settings", "PATCH", API + "/settings", "Update Manifold settings.", body=True)
resource("journal_issue", "journal_issues", API + "/journal_issues", ("index", "show", "update", "destroy"))
resource("journal_volume", "journal_volumes", API + "/journal_volumes", ("show", "update", "destroy"))
resource("ingestion_source", "ingestion_sources", API + "/ingestion_sources", ("show", "update", "destroy"))
resource("annotation", "annotations", API + "/annotations", ("index", "show", "update", "destroy"))
resource("collaborator", "collaborators", API + "/collaborators")
add("list_collaborator_roles", "GET", API + "/collaborators/roles", "List Manifold collaborator roles.")

resource("text", "texts", API + "/texts")
add("toggle_text_export_epub_v3", "PUT", API + "/texts/{id}/export_epub_v3", "Toggle EPUB v3 export for a text.", body=True)
nested("text", "ingestion", "ingestions", API + "/texts/{text_id}/ingestions", ("create",))
tr = API + "/texts/{text_id}/relationships"
nested("text", "text_section", "text_sections", tr + "/text_sections", ("index", "show", "create"))
nested("text", "stylesheet", "stylesheets", tr + "/stylesheets", ("create",))
nested("text", "relationship_ingestion", "relationship_ingestions", tr + "/ingestions", ("create",))
nested("text", "ingestion_source", "ingestion_sources", tr + "/ingestion_sources", ("index", "create"))
nested("text", "collaborator", "collaborators", tr + "/collaborators", ("index", "show"))
add("create_text_collaborators_from_roles", "POST", tr + "/collaborators/create_from_roles", "Create text collaborators from roles.", body=True)
add("update_text_collaborators_from_roles", "POST", tr + "/collaborators/update_from_roles", "Update text collaborators from roles.", body=True)
add("delete_text_collaborators", "DELETE", tr + "/collaborators/destroy", "Delete text collaborators through the collection action.", body=True)
ts = tr + "/text_sections"
add("update_text_text_section", "PATCH", ts + "/{id}", "Update a text section in a text relationship.", body=True)
add("delete_text_text_section", "DELETE", ts + "/{id}", "Delete a text section in a text relationship.", body=True)
nested("text_section", "annotation", "annotations", ts + "/{text_section_id}/annotations", ("index",))
nested("text_section", "resource", "resources", ts + "/{text_section_id}/resources", ("index",))
nested("text_section", "resource_collection", "resource_collections", ts + "/{text_section_id}/resource_collections", ("index",))

resource("comment", "comments", API + "/comments", ("index", "show", "update", "destroy"))
for owner in ("comments", "annotations"):
    owner_id = owner[:-1] + "_id"
    base = API + f"/{owner}/{{{owner_id}}}/relationships/flags"
    singular_owner = owner[:-1]
    add(f"create_{singular_owner}_flag", "POST", base, f"Create a flag for a Manifold {singular_owner}.", body=True)
    add(f"delete_{singular_owner}_flag", "DELETE", base, f"Delete the current flag for a Manifold {singular_owner}.", body=True)
    add(f"resolve_all_{singular_owner}_flags", "DELETE", base + "/resolve_all", f"Resolve all flags for a Manifold {singular_owner}.", body=True)
nested("annotation", "comment", "comments", API + "/annotations/{annotation_id}/relationships/comments")

resource("resource", "resources", API + "/resources", ("show", "update", "destroy"))
rr = API + "/resources/{resource_id}/relationships"
nested("resource", "comment", "comments", rr + "/comments")
nested("resource", "text_track", "text_tracks", rr + "/text_tracks")
nested("resource", "annotation", "annotations", rr + "/annotations", ("index",))

resource("resource_collection", "resource_collections", API + "/resource_collections", ("show", "update", "destroy"))
rcr = API + "/resource_collections/{resource_collection_id}/relationships"
nested("resource_collection", "collection_resource", "collection_resources", rcr + "/collection_resources", ("index", "show"))
nested("resource_collection", "resource", "resources", rcr + "/resources", ("index",))
nested("resource_collection", "annotation", "annotations", rcr + "/annotations", ("index",))

resource("project_collection", "project_collections", API + "/project_collections")
pcr = API + "/project_collections/{project_collection_id}/relationships"
nested("project_collection", "collection_project", "collection_projects", pcr + "/collection_projects", ("index", "create", "update", "destroy"))
nested("project_collection", "project", "projects", pcr + "/projects", ("index",))

resource("text_section", "text_sections", API + "/text_sections", ("update", "destroy"))
nested("text_section_relationship", "annotation", "annotations", API + "/text_sections/{text_section_id}/relationships/annotations", ("create", "update"))

resource("journal", "journals", API + "/journals")
jr = API + "/journals/{journal_id}/relationships"
for singular, plural in (("action_callout", "action_callouts"), ("entitlement", "entitlements"), ("journal_issue", "journal_issues"), ("journal_volume", "journal_volumes")):
    nested("journal", singular, plural, jr + f"/{plural}", ("index", "create"))
nested("journal", "permission", "permissions", jr + "/permissions")

resource("project", "projects", API + "/projects")
nested("project", "ingestion", "ingestions", API + "/projects/{project_id}/ingestions", ("create",))
pr = API + "/projects/{project_id}/relationships"
for singular, plural, actions in (
    ("action_callout", "action_callouts", ("index", "create")),
    ("entitlement", "entitlements", ("index", "create")),
    ("project_exportation", "project_exportations", ("index",)),
    ("content_block", "content_blocks", ("index", "create")),
    ("uncollected_resource", "uncollected_resources", ("index",)),
    ("resource", "resources", ("index", "create")),
    ("resource_collection", "resource_collections", ("index", "create")),
    ("event", "events", ("index",)),
    ("resource_import", "resource_imports", ("show", "create", "update")),
    ("collaborator", "collaborators", ("index", "show")),
    ("text_category", "text_categories", ("index", "show", "create")),
    ("text", "texts", ("create",)),
    ("relationship_ingestion", "relationship_ingestions", ("create",)),
    ("version", "versions", ("index",)),
    ("permission", "permissions", ("index", "show", "create", "update", "destroy")),
):
    route_plural = "ingestions" if plural == "relationship_ingestions" else plural
    nested("project", singular, plural, pr + f"/{route_plural}", actions)
add("create_project_collaborators_from_roles", "POST", pr + "/collaborators/create_from_roles", "Create project collaborators from roles.", body=True)
add("update_project_collaborators_from_roles", "POST", pr + "/collaborators/update_from_roles", "Update project collaborators from roles.", body=True)
add("delete_project_collaborators", "DELETE", pr + "/collaborators/destroy", "Delete project collaborators through the collection action.", body=True)

add("create_token", "POST", API + "/tokens", "Call Manifold's token-creation endpoint.", body=True)
resource("user", "users", API + "/users")
add("whoami", "GET", API + "/users/whoami", "Return the Manifold user associated with the connector credentials.")
nested("user", "annotation", "annotations", API + "/users/{user_id}/relationships/annotations", ("index",))
nested("user", "reading_group_membership", "reading_group_memberships", API + "/users/{user_id}/relationships/reading_group_memberships", ("index",))

add("get_me", "GET", API + "/me", "Read the current Manifold user resource.")
add("update_me", "PATCH", API + "/me", "Update the current Manifold user resource.", body=True)
add("delete_me", "DELETE", API + "/me", "Delete the current Manifold user resource.", body=True)
mer = API + "/me/relationships"
nested("me", "annotated_text", "annotated_texts", mer + "/annotated_texts", ("index",))
nested("me", "favorite", "favorites", mer + "/favorites", ("index", "show", "create", "destroy"))
nested("me", "reading_group", "reading_groups", mer + "/reading_groups", ("index",))
nested("me", "favorite_project", "favorite_projects", mer + "/favorite_projects", ("index",))
nested("me", "annotation", "annotations", mer + "/annotations", ("index",))
add("get_me_collection", "GET", mer + "/collection", "Read the current user's collection.")
for singular, plural in (("project", "projects"), ("journal_issue", "journal_issues"), ("resource", "resources"), ("resource_collection", "resource_collections"), ("text", "texts"), ("text_section", "text_sections")):
    nested("me", singular, plural, mer + f"/{plural}", ("index",))

add("create_notification_unsubscribe", "POST", API + "/notification_preferences/relationships/unsubscribe", "Create a notification-preference unsubscribe action.", body=True)

resource("user_group", "user_groups", API + "/user_groups")
ugr = API + "/user_groups/{user_group_id}/relationships"
nested("user_group", "user_group_membership", "user_group_memberships", ugr + "/user_group_memberships", ("index", "create", "destroy"))
nested("user_group", "user_group_entitleable", "user_group_entitleables", ugr + "/user_group_entitleables", ("index", "create", "destroy"))

add("create_analytics_event", "POST", API + "/analytics/events", "Create an analytics event.", body=True)
add("get_analytics_report", "GET", API + "/analytics/reports", "Read an analytics report.")
resource("password", "passwords", API + "/passwords", ("create", "update"))
add("admin_reset_password", "POST", API + "/passwords/admin_reset_password", "Administratively reset a Manifold password.", body=True)

add("tus_options", "OPTIONS", "/api/files", "Query Tus upload capabilities.", query=False, headers=True)
add("tus_create_upload", "POST", "/api/files", "Create a Tus upload.", query=False, headers=True, raw_body=True)
add("tus_head_upload", "HEAD", "/api/files/{upload_id}", "Read Tus upload state.", query=False, headers=True)
add("tus_patch_upload", "PATCH", "/api/files/{upload_id}", "Append bytes to a Tus upload.", query=False, headers=True, raw_body=True)
add("tus_delete_upload", "DELETE", "/api/files/{upload_id}", "Delete/terminate a Tus upload when supported.", query=False, headers=True)

# Compatibility fallback. Named tools above mirror the routes present in Manifold's api/config/routes.rb.
add("api_call", "POST", "/", "Call a same-origin Manifold endpoint not represented by a named tool. Use only for compatibility gaps.", body=True, headers=True, raw_body=True)

TOOLS = [{"name": op["name"], "title": op["name"].replace("_", " ").title(), "description": op["description"], "inputSchema": op["inputSchema"], "annotations": op["annotations"]} for op in OPERATIONS]

API_CALL_SCHEMA = object_schema({
    "method": {"type": "string", "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"], "description": "HTTP method."},
    "path": string_schema("Root-relative path on the configured Manifold instance."),
    "query": QUERY_SCHEMA,
    "headers": HEADERS_SCHEMA,
    "body": BODY_SCHEMA,
    "body_base64": {"type": "string", "description": "Optional raw request body encoded as base64. Mutually exclusive with body."},
}, ["method", "path"])
for tool in TOOLS:
    if tool["name"] == "api_call":
        tool["inputSchema"] = API_CALL_SCHEMA
        tool["annotations"] = WRITE_ANNOTATIONS
        break
