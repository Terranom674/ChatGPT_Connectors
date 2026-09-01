from __future__ import annotations

"""Stable MCP surface for complete LinkStack administration through the Bratonien API."""

from operations import OPERATION_BY_NAME, OPERATIONS

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
    "status", "system_status", "system_capabilities", "system_extended_capabilities", "system_diagnostics",
    "get_profile", "update_profile", "get_profile_data", "update_profile_data", "get_profile_preferences", "update_profile_preferences",
    "list_themes", "get_theme", "activate_theme", "update_themes", "update_named_theme", "delete_theme",
    "list_assets", "upload_asset", "delete_asset", "list_social_icons", "create_social_icon", "update_social_icon", "delete_social_icon",
    "list_links", "create_link", "get_link", "update_link", "delete_link", "reorder_links", "pin_link", "unpin_link", "style_link", "delete_link_favicon", "list_link_types", "list_buttons",
    "get_pages", "update_pages", "get_settings", "update_settings", "get_domains", "update_domains", "get_mail", "update_mail", "test_mail",
    "get_security", "update_security", "get_maintenance", "update_maintenance", "get_logging", "update_logging", "get_advanced_config", "update_advanced_config",
    "analytics_summary", "analytics_links", "analytics_dimensions", "analytics_instance",
    "list_users", "create_user", "get_user", "update_user", "delete_user", "set_user_status", "verify_user", "unverify_user", "disable_user", "enable_user", "set_user_role", "list_roles",
    "export_user", "import_users", "list_backups", "create_backup", "delete_backup", "restore_backup", "submit_report",
    "list_api_applications", "create_api_application", "get_api_application", "update_api_application", "delete_api_application", "set_api_application_permissions",
    "list_api_tokens", "create_api_token", "rotate_api_token", "revoke_api_token", "get_audit", "api_call",
}

_missing = REQUIRED_MANAGEMENT_TOOLS.difference(set(OPERATION_BY_NAME) | {"api_call"})
if _missing:
    raise RuntimeError("LinkStack management surface is incomplete: " + ", ".join(sorted(_missing)))
