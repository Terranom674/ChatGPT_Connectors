# Privacy Policy for Gitea Connector

**Effective date:** August 11, 2026

Gitea Connector lets authorized users work with repositories and related project data on a self-hosted Gitea instance through a Streamable HTTP MCP server.

## Data processed

When you use the plugin, it processes only the information needed to perform the action you request. Depending on the tool, this may include repository owners and names, file paths and contents, branches, commits, issues, pull requests, reviews, comments, tags, releases, and other project data returned by or sent to Gitea.

Authentication credentials are sent in the authorization header to the MCP endpoint. The plugin does not include or store bearer tokens in its distributed files.

## How data is used

Data is used only to:

- authenticate access to the MCP server;
- perform the Gitea operation requested by the user;
- return the requested result to ChatGPT; and
- protect, operate, and troubleshoot the service.

The MCP server logs the MCP method name and, for tool calls, the selected tool name. It does not intentionally log tool arguments, authorization headers, or tool results. Standard HTTP access logs may contain technical request metadata such as timestamp, path, status code, and source address.

## Data sharing

Requested data is exchanged between ChatGPT, the Gitea Connector MCP server, and the configured self-hosted Gitea instance as necessary to complete the requested operation. Data may also be processed by infrastructure providers used to host or secure the service. The plugin does not sell personal data.

OpenAI processes information submitted through ChatGPT under OpenAI's own terms and privacy policies. Data stored in Gitea remains subject to the policies and controls of the relevant Gitea operator.

## Retention and security

Repository and project data is not intentionally persisted by the connector beyond the systems involved in completing the request. Operational and security logs may be retained according to the server operator's infrastructure configuration.

Access to the MCP endpoint is protected by bearer authentication. Users should not include secrets or credentials in prompts, repository content, issues, comments, or other tool inputs unless strictly necessary and authorized.

## User choices

Users control which actions they request. Write and destructive operations require explicit confirmation. Users may stop using the plugin at any time and may contact the operator regarding access, correction, or deletion requests where applicable.

## Contact

For privacy questions or requests, open an issue in `Terranom674/ChatGPT_Connectors`.

## Changes

This policy may be updated when the plugin's functionality or data practices change. The effective date above will be updated when material changes are published.
