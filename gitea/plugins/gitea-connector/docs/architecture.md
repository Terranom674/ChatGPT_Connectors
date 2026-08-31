# Architecture

## Goal

The plugin provides reusable Gitea workflows for ChatGPT while keeping the user's Gitea instance, MCP server, endpoint, and credentials under the user's control.

The plugin is bound to the existing Bratonien MCP endpoint but must not depend on a repository owner, Gitea deployment name, or MCP display name.

## ChatGPT deployment model

The plugin binds the existing Gitea MCP endpoint as a Streamable HTTP plugin MCP. It does not create, start, host, proxy, or provision the server and does not use Codex STDIO.

```text
ChatGPT
  -> Gitea Connector plugin
    -> bundled workflow skills
      -> already configured callable Gitea MCP tools
        -> Streamable HTTP MCP endpoint
          -> self-hosted Gitea MCP
            -> self-hosted Gitea /api/v1
```

The plugin contains a `.mcp.json` that points to `https://mcp.bratonien.de/mcp` and no workspace-specific `.app.json` binding. Authentication remains installation-specific and no token is stored in the plugin.

## Connection boundary

The plugin must use only the Gitea-related MCP tools exposed by its configured plugin MCP.

It must not:

- invent or provision another MCP server,
- create a Codex stdio MCP configuration,
- fall back to GitHub for private Gitea data,
- ask the model to handle Gitea or MCP credentials directly.

If no suitable Gitea MCP tools are callable, the plugin should report that its plugin MCP authentication or connection must be checked in ChatGPT.

## MCP server boundary

The self-hosted MCP server is responsible for the actual Gitea API connection and authentication. A typical deployment exposes a Streamable HTTP endpoint over HTTPS, directly or through the operator's own reverse proxy or secure tunnel.

The MCP implementation in this connector directory uses the configured Gitea base URL and access token on the server side. Those credentials are not plugin inputs and must not be returned through MCP tools.

## Safety boundary

- Repository-specific operations require explicit owner and repository inputs where the MCP tool requires them.
- Pagination and upstream API validation are enforced by the MCP server.
- Authorization headers, tokens, internal errors, and unnecessary personal data are redacted by the MCP implementation.
- Read, write, and destructive operations remain distinct.
- Passwords, token management, secrets, keys, user administration, permissions, runners, and webhooks remain excluded.
- Consequential writes such as merges, deletions, and branch changes require explicit confirmation when no product-level confirmation is already provided.
- Ambiguous writes must not be retried automatically.

## Compatibility

The original operation catalog was verified against Gitea 1.24.5. Gitea API surfaces can vary between releases, so operators should validate the self-hosted MCP against their target Gitea version before relying on consequential write workflows.

## Separation from Codex stdio support

The connector may contain MCP server implementation files useful for self-hosting and development, but the ChatGPT plugin does not bind or launch them through Codex stdio. It connects only to the declared remote Streamable HTTP endpoint.
