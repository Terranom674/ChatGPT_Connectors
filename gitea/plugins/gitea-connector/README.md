# Gitea Connector

A ChatGPT plugin for working with a self-hosted Gitea instance through the existing Streamable HTTP MCP endpoint at `https://mcp.bratonien.de/mcp`.

## Architecture

The plugin provides workflow instructions and presentation and binds the existing Streamable HTTP endpoint as a plugin MCP. It does not start, host, proxy, or provision the MCP server itself and does not use Codex STDIO.

```text
ChatGPT plugin / skills
      |
      v
callable custom Gitea MCP tools
      |
      v
public HTTPS MCP endpoint
      |
      v
reverse proxy / user's infrastructure
      |
      v
self-hosted Gitea MCP
      |
      v
self-hosted Gitea instance
```

The Gitea instance, MCP server, reverse proxy, domain, TLS certificate and credentials remain under the user's control. The plugin itself does not host Gitea, proxy traffic, store credentials or require the OpenAI model API.

## Requirements

Before using the plugin, the operator must have:

- a self-hosted Gitea instance,
- a running Gitea MCP server from this connector directory,
- the HTTPS endpoint `https://mcp.bratonien.de/mcp` reachable by ChatGPT,
- Bearer authentication configured for that endpoint,
- the plugin installed and its MCP authentication configured during installation.

A typical reverse-proxy setup is:

```text
https://mcp.bratonien.de/mcp
        -> reverse proxy
        -> http://MCP-SERVER:8000/mcp
```

## ChatGPT MCP configuration

The plugin declares a Streamable HTTP MCP server with:

- Type: `Streamable HTTP`
- URL: `https://mcp.bratonien.de/mcp`
- Header name: `Authorization`
- Header value: `Bearer YOUR_MCP_HTTP_TOKEN`

Do not enter the token itself in the field labelled `Bearer token environment variable`. That field expects the name of an environment variable. For the tested self-hosted setup, the explicit `Authorization` header is used instead.

A successful MCP handshake produces POST requests to `/mcp` with HTTP `200` and `202` responses.

## Plugin and MCP separation

This plugin contains no `.app.json` workspace binding. Its `.mcp.json` binds the existing self-hosted endpoint so ChatGPT exposes the MCP tools to the plugin. The file contains no bearer token or other secret.

## Server configuration

The MCP server itself uses:

```bash
GITEA_URL="https://git.example.com"
GITEA_TOKEN="your-gitea-token"
MCP_HTTP_TOKEN="choose-a-long-random-value"
```

`GITEA_URL` is the base URL without `/api/v1`. The Gitea token should have only the permissions needed for the desired operations.

The HTTP server exposes:

- MCP endpoint: `/mcp`
- Health endpoint: `/health`

`MCP_HTTP_TOKEN` protects `/mcp` with Bearer authentication. The health endpoint intentionally remains available for service checks.

## Scope

- Read repositories, files, branches, commits, issues, pull requests, reviews, tags, releases, packages, Actions data, and other project information.
- Create, update, move, and delete text files, including up to 50 file operations in one commit.
- Create and delete branches and tags.
- Create, update, comment on, close, review, merge, and delete supported project objects.
- Create, update, and delete releases.
- Require confirmation for writes, merges, branch changes, and deletions.
- Exclude passwords, tokens, secrets, keys, user administration, permissions, runners, and webhooks.
- Redact sensitive user and credential metadata from generic operation results.

The current operation catalog contains 221 safety-filtered Gitea project operations inherited from the tested original implementation.

## Compatibility note

The original implementation was tested against Gitea 1.24.5. Other Gitea versions may expose slightly different API operations. Test the connector against the target instance before relying on write operations in production.

## Local verification

```bash
python3 -m unittest discover -s tests -v
```

No GitHub Actions are used; verification is run manually or by the installation/runtime environment.

See [docs/architecture.md](docs/architecture.md) and [docs/tool-contracts.md](docs/tool-contracts.md).
