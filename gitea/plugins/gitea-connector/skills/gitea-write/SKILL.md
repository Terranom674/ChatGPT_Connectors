---
name: gitea-write
description: Perform explicit, confirmed Gitea project writes through the plugin's self-hosted Gitea MCP connection.
---

# Gitea Write

Use the callable write tools exposed by the plugin's self-hosted Gitea MCP connection only for explicit user-requested changes.

The plugin does not start, host, or provision an MCP server. Use the Gitea-related tools exposed by its declared remote Streamable HTTP MCP connection.

## Required workflow

1. Verify that the required Gitea MCP tools are callable in the current session.
2. Resolve and read the exact repository and target first.
3. For catalog operations, call `describe_operation` before execution.
4. Prepare the complete final change.
5. Show the exact repository, target, operation, and content to the user and obtain confirmation when the product/tool does not already provide the required confirmation step.
6. Perform exactly one write call after confirmation.
7. Report the returned stable identifier and URL when provided.

If the Gitea MCP tools are not callable in the current session, tell the user to check the installed plugin MCP connection and authentication in ChatGPT. Do not create or substitute a Codex stdio MCP, GitHub connector, or public web request for the requested Gitea write.

## Safety

- Never request, display, or return a Gitea access token or MCP bearer token.
- Do not attempt to change the Gitea server or MCP connection from the plugin.
- Never infer a repository, branch, issue number, pull-request number, title, or body for a write.
- Immediately before updating or deleting a file, call `get_file` and use its current SHA.
- Before a multi-file commit, read every file that will be updated or deleted and use its current SHA.
- Before merging a pull request, read the pull request and bind the confirmed merge to its current head commit SHA.
- Creating files is allowed only at a confirmed new path; deleting files requires explicit confirmation of that exact path.
- Merges, closing, branch changes, and deletions are allowed only after explicit confirmation.
- Never manage passwords, tokens, secrets, keys, users, permissions, runners, webhooks, or administrator functions.
- Do not retry a write automatically after an ambiguous timeout or transport failure.
