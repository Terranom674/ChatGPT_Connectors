from __future__ import annotations

"""Stable LinkStack REST operation catalog for the Bratonien MCP connector."""

API = "/api/v1"

READ_ANNOTATIONS = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": True}
WRITE_ANNOTATIONS = {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": True}
DELETE_ANNOTATIONS = {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False, "openWorldHint": True}
ACTION_ANNOTATIONS = {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False, "openWorldHint": True}


def string_schema(description: str = ""):
    value = {"type": "string"}
    if description:
        value["description"] = description
    return value


def integer_schema(description: str = ""):
    value = {"type": "integer"}
    if description:
        value["description"] = description
    return value


def object_schema(properties=None, required=None):
    value = {"type": "object", "properties": properties or {}, "additionalProperties": False}
    if required:
        value["required"] = required
    return value


QUERY_SCHEMA = {"type": "object", "description": "Optional query parameters passed to LinkStack.", "additionalProperties": True}
BODY_SCHEMA = {"description": "Optional JSON-compatible request body passed to LinkStack unchanged."}
HEADERS_SCHEMA = {"type": "object", "description": "Optional additional request headers. Authorization, Host and Cookie are managed by the connector.", "additionalProperties": {"type": "string"}}


def operation(name, method, path, description, *, params=(), body=False, annotation=None):
    properties = {key: schema for key, schema in params}
    properties["query"] = QUERY_SCHEMA
    properties["headers"] = HEADERS_SCHEMA
    if body:
        properties["body"] = BODY_SCHEMA
        properties["body_base64"] = string_schema("Optional raw request body encoded as base64. Mutually exclusive with body.")
    required = [key for key, _ in params]
    if annotation is None:
        annotation = READ_ANNOTATIONS if method in {"GET", "HEAD"} else DELETE_ANNOTATIONS if method == "DELETE" else WRITE_ANNOTATIONS
    return {"name": name, "method": method, "path": path, "description": description, "inputSchema": object_schema(properties, required), "annotations": annotation}


ID = ("id", integer_schema("Numeric LinkStack object id."))
NAME = ("name", string_schema("LinkStack theme name."))
KIND = ("kind", string_schema("Asset kind."))
GROUP = ("group", string_schema("Settings group."))

OPERATIONS = [
    operation("status", "GET", API + "/status", "Read the Bratonien LinkStack API status."),
    operation("system_status", "GET", API + "/system/status", "Read LinkStack system status."),
    operation("system_capabilities", "GET", API + "/system/capabilities", "Read LinkStack API capabilities."),
    operation("system_extended_capabilities", "GET", API + "/system/extended-capabilities", "Read extended LinkStack capabilities."),
    operation("system_diagnostics", "GET", API + "/system/diagnostics", "Read LinkStack diagnostics."),

    operation("get_profile", "GET", API + "/profile", "Read the LinkStack profile."),
    operation("update_profile", "PATCH", API + "/profile", "Update the LinkStack profile.", body=True),
    operation("get_profile_data", "GET", API + "/profile/data", "Read supported LinkStack profile data."),
    operation("update_profile_data", "PATCH", API + "/profile/data", "Update supported LinkStack profile data.", body=True),
    operation("get_profile_preferences", "GET", API + "/profile/preferences", "Read LinkStack profile preferences."),
    operation("update_profile_preferences", "PATCH", API + "/profile/preferences", "Update LinkStack profile preferences.", body=True),

    operation("list_themes", "GET", API + "/themes", "List LinkStack themes."),
    operation("get_theme", "GET", API + "/theme", "Read the active LinkStack theme."),
    operation("activate_theme", "POST", API + "/themes/{name}/activate", "Activate a LinkStack theme.", params=(NAME,), body=True),
    operation("update_themes", "POST", API + "/themes/update", "Run LinkStack's global theme update.", body=True, annotation=ACTION_ANNOTATIONS),
    operation("update_named_theme", "POST", API + "/themes/{name}/update", "Request an individual theme update. LinkStack 4.8.6 intentionally returns 409 because it has no native per-theme updater.", params=(NAME,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("delete_theme", "DELETE", API + "/themes/{name}", "Delete a LinkStack theme when allowed.", params=(NAME,)),

    operation("list_assets", "GET", API + "/assets", "List LinkStack profile assets."),
    operation("upload_asset", "POST", API + "/assets", "Upload or replace a LinkStack asset.", body=True),
    operation("delete_asset", "DELETE", API + "/assets/{kind}", "Delete a LinkStack asset.", params=(KIND,)),
    operation("list_social_icons", "GET", API + "/social-icons", "List LinkStack social icons."),
    operation("create_social_icon", "POST", API + "/social-icons", "Create a LinkStack social icon.", body=True),
    operation("update_social_icon", "PATCH", API + "/social-icons/{id}", "Update a LinkStack social icon.", params=(ID,), body=True),
    operation("delete_social_icon", "DELETE", API + "/social-icons/{id}", "Delete a LinkStack social icon.", params=(ID,)),

    operation("list_links", "GET", API + "/links", "List LinkStack links and blocks."),
    operation("create_link", "POST", API + "/links", "Create a LinkStack link or supported block.", body=True),
    operation("get_link", "GET", API + "/links/{id}", "Read one LinkStack link or block.", params=(ID,)),
    operation("update_link", "PATCH", API + "/links/{id}", "Update one LinkStack link or block without changing its type.", params=(ID,), body=True),
    operation("delete_link", "DELETE", API + "/links/{id}", "Delete one LinkStack link or block.", params=(ID,)),
    operation("reorder_links", "POST", API + "/links/reorder", "Reorder LinkStack links.", body=True),
    operation("pin_link", "POST", API + "/links/{id}/pin", "Pin a LinkStack link.", params=(ID,), body=True),
    operation("unpin_link", "POST", API + "/links/{id}/unpin", "Unpin a LinkStack link.", params=(ID,), body=True),
    operation("style_link", "PATCH", API + "/links/{id}/style", "Update LinkStack link styling.", params=(ID,), body=True),
    operation("delete_link_favicon", "DELETE", API + "/links/{id}/favicon", "Delete a cached LinkStack link favicon.", params=(ID,)),
    operation("list_link_types", "GET", API + "/link-types", "List available LinkStack link and block types."),
    operation("list_buttons", "GET", API + "/buttons", "List LinkStack buttons."),

    operation("get_pages", "GET", API + "/pages", "Read LinkStack pages."),
    operation("update_pages", "PATCH", API + "/pages", "Update LinkStack pages.", body=True),
    operation("get_settings", "GET", API + "/settings/{group}", "Read a typed LinkStack settings group.", params=(GROUP,)),
    operation("update_settings", "PATCH", API + "/settings/{group}", "Update a typed LinkStack settings group.", params=(GROUP,), body=True),
    operation("get_domains", "GET", API + "/domains", "Read LinkStack domain settings."),
    operation("update_domains", "PATCH", API + "/domains", "Update LinkStack domain settings.", body=True),
    operation("get_mail", "GET", API + "/mail", "Read LinkStack mail settings."),
    operation("update_mail", "PATCH", API + "/mail", "Update LinkStack mail settings.", body=True),
    operation("test_mail", "POST", API + "/mail/test", "Send a LinkStack test mail.", body=True, annotation=ACTION_ANNOTATIONS),
    operation("get_security", "GET", API + "/security", "Read LinkStack security settings."),
    operation("update_security", "PATCH", API + "/security", "Update LinkStack security settings.", body=True),
    operation("get_maintenance", "GET", API + "/maintenance", "Read LinkStack maintenance state."),
    operation("update_maintenance", "PATCH", API + "/maintenance", "Update LinkStack maintenance state.", body=True, annotation=ACTION_ANNOTATIONS),
    operation("get_logging", "GET", API + "/logging", "Read LinkStack logging settings."),
    operation("update_logging", "PATCH", API + "/logging", "Update LinkStack logging/debug settings.", body=True),
    operation("get_advanced_config", "GET", API + "/advanced-config", "Read the supported LinkStack advanced configuration fields."),
    operation("update_advanced_config", "PATCH", API + "/advanced-config", "Update supported LinkStack advanced configuration fields.", body=True),

    operation("analytics_summary", "GET", API + "/analytics/summary", "Read LinkStack analytics summary."),
    operation("analytics_links", "GET", API + "/analytics/links", "Read LinkStack link analytics."),
    operation("analytics_dimensions", "GET", API + "/analytics/dimensions", "Read LinkStack analytics dimensions."),
    operation("analytics_instance", "GET", API + "/analytics/instance", "Read LinkStack instance analytics."),

    operation("list_users", "GET", API + "/users", "List LinkStack users."),
    operation("create_user", "POST", API + "/users", "Create a LinkStack user.", body=True),
    operation("get_user", "GET", API + "/users/{id}", "Read one LinkStack user.", params=(ID,)),
    operation("update_user", "PATCH", API + "/users/{id}", "Update one LinkStack user.", params=(ID,), body=True),
    operation("delete_user", "DELETE", API + "/users/{id}", "Delete one LinkStack user when allowed.", params=(ID,)),
    operation("set_user_status", "POST", API + "/users/{id}/status", "Change a LinkStack user's status.", params=(ID,), body=True),
    operation("verify_user", "POST", API + "/users/{id}/verify", "Verify a LinkStack user.", params=(ID,), body=True),
    operation("unverify_user", "POST", API + "/users/{id}/unverify", "Remove LinkStack user verification.", params=(ID,), body=True),
    operation("disable_user", "POST", API + "/users/{id}/disable", "Disable a LinkStack user.", params=(ID,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("enable_user", "POST", API + "/users/{id}/enable", "Enable a LinkStack user.", params=(ID,), body=True),
    operation("set_user_role", "POST", API + "/users/{id}/role", "Change a LinkStack user's role.", params=(ID,), body=True),
    operation("list_roles", "GET", API + "/roles", "List LinkStack roles."),

    operation("export_user", "GET", API + "/export/users/{id}", "Export one LinkStack user through the controlled API export.", params=(ID,)),
    operation("import_users", "POST", API + "/import/users", "Import LinkStack user data through the controlled API import.", body=True, annotation=ACTION_ANNOTATIONS),
    operation("list_backups", "GET", API + "/backups", "List Bratonien LinkStack API snapshots."),
    operation("create_backup", "POST", API + "/backups", "Create a controlled LinkStack API snapshot.", body=True, annotation=ACTION_ANNOTATIONS),
    operation("delete_backup", "DELETE", API + "/backups/{id}", "Delete a LinkStack API snapshot.", params=(ID,)),
    operation("restore_backup", "POST", API + "/backups/{id}/restore", "Restore a controlled LinkStack API snapshot.", params=(ID,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("submit_report", "POST", API + "/reports", "Submit a LinkStack report using LinkStack's native report mail flow.", body=True),

    operation("list_api_applications", "GET", API + "/api-applications", "List LinkStack API applications."),
    operation("create_api_application", "POST", API + "/api-applications", "Create a LinkStack API application.", body=True),
    operation("get_api_application", "GET", API + "/api-applications/{id}", "Read one LinkStack API application.", params=(ID,)),
    operation("update_api_application", "PATCH", API + "/api-applications/{id}", "Update a LinkStack API application.", params=(ID,), body=True),
    operation("delete_api_application", "DELETE", API + "/api-applications/{id}", "Delete a LinkStack API application when allowed.", params=(ID,)),
    operation("set_api_application_permissions", "PUT", API + "/api-applications/{id}/permissions", "Replace fine-grained permissions for a LinkStack API application.", params=(ID,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("list_api_tokens", "GET", API + "/api-tokens", "List LinkStack API token metadata."),
    operation("create_api_token", "POST", API + "/api-applications/{id}/tokens", "Create a LinkStack API token. The full token is returned only once by LinkStack.", params=(ID,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("rotate_api_token", "POST", API + "/api-tokens/{id}/rotate", "Rotate a LinkStack API token.", params=(ID,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("revoke_api_token", "POST", API + "/api-tokens/{id}/revoke", "Revoke a LinkStack API token.", params=(ID,), body=True, annotation=ACTION_ANNOTATIONS),
    operation("get_audit", "GET", API + "/audit", "Read the LinkStack API audit log."),
]

OPERATION_BY_NAME = {op["name"]: op for op in OPERATIONS}
