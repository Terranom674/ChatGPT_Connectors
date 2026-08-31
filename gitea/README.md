# Gitea Connector

MCP connector for self-hosted Gitea instances.

This directory is the canonical source of the Bratonien Gitea connector inside `Terranom674/ChatGPT_Connectors`.

## Bratonien architecture

The Gitea-specific logic stays completely inside this connector directory. The shared Proxmox/LXC host, OpenAI Secure MCP Tunnel and multi-connector routing live in:

```text
Terranom674/Proxmox_Scripts/mcp
```

The intended production architecture is:

```text
ChatGPT
   |
   | OpenAI Secure MCP Tunnel
   v
Bratonien MCP Host
   |
   +--> gitea__* -> Gitea Connector -> Gitea API
   |
   +--> manifold__* -> Manifold Connector -> Manifold API
   |
   +--> additional connectors later
```

The Bratonien MCP host does not contain Gitea API logic. This connector remains responsible for Gitea tools, the Gitea API client, its internal MCP transport and the Gitea OAuth setup helper.

## Recommended installation

First install the shared Bratonien MCP host from `Terranom674/Proxmox_Scripts/mcp`.

Then, inside that MCP LXC as root, register this connector:

```bash
git clone --depth 1 https://github.com/Terranom674/ChatGPT_Connectors.git /tmp/chatgpt-connectors
bash /tmp/chatgpt-connectors/gitea/install/register-with-bratonien-mcp.sh
```

The registration helper:

1. asks for the Gitea base URL and Gitea access token,
2. installs only the Gitea connector under `/opt/connectors/gitea`,
3. creates a dedicated internal MCP token,
4. starts the connector on `127.0.0.1:8101`,
5. registers it with the shared Bratonien MCP host as connector ID `gitea`,
6. configures the Gitea OAuth endpoints on the shared host,
7. restarts only the shared MCP host after registration,
8. verifies the connector health,
9. verifies `tools/list` through the shared host,
10. verifies the namespaced tool `gitea__list_repositories`,
11. performs one read-only repository-list smoke test with a maximum of one result.

No write, merge, delete or other destructive Gitea operation is used by the registration smoke test.

Tools are exposed by the shared host with the namespace:

```text
gitea__<tool-name>
```

## Authentication modes

The connector supports two distinct deployment modes.

### Shared Bratonien MCP host

The registration helper configures:

```text
MCP_HTTP_TOKEN=<internal connector token>
MCP_TRUST_FORWARDED_BEARER=1
MCP_OAUTH_ISSUER=
MCP_RESOURCE_URL=
MCP_BIND_ADDRESS=127.0.0.1
MCP_PORT=8101
```

In this mode the Gitea connector is not the public MCP resource and does not publish public OAuth metadata. The shared Bratonien MCP host validates the external OAuth bearer first. The validated bearer is then forwarded to this connector for the Gitea API request.

When the shared host itself performs a local/internal request using its own host token, it uses the dedicated connector token instead. The Gitea connector then falls back to its configured `GITEA_TOKEN` for the Gitea API call.

`MCP_TRUST_FORWARDED_BEARER=1` must only be used when the connector is bound to the trusted local interface behind the central host. It must not be used to expose the connector directly to the public network.

### Standalone/public mode

The legacy standalone architecture can configure:

```text
MCP_OAUTH_ISSUER=https://git.example.com
MCP_RESOURCE_URL=https://mcp.example.com/mcp
```

In that mode this connector publishes the Gitea OAuth metadata itself and accepts OAuth bearer tokens directly.

## ChatGPT OAuth setup

A fresh ChatGPT OAuth connection is a two-stage setup because ChatGPT supplies the exact callback/redirect URL only while the connection is being configured.

After the connector is registered:

1. add/connect the public Bratonien MCP endpoint in ChatGPT,
2. select OAuth,
3. copy the exact callback/redirect URL shown by ChatGPT,
4. run inside the MCP LXC:

```bash
bash /opt/connectors/gitea/install/oauth-setup.sh
```

5. paste the ChatGPT callback URL,
6. copy the returned Client ID and Client Secret into ChatGPT,
7. finish Gitea authorization and reload/rescan the MCP tools.

The helper creates the Gitea OAuth2 application through:

```text
POST /api/v1/user/applications/oauth2
```

The Client ID and Client Secret belong to the ChatGPT-to-Gitea OAuth client. They are not stored in the MCP host configuration.

## Connector configuration

The implementation lives in [`plugins/gitea-connector`](plugins/gitea-connector).

Environment variables:

- `GITEA_URL` - base URL of the Gitea instance
- `GITEA_TOKEN` - Gitea server fallback credential
- `MCP_HTTP_TOKEN` - bearer token protecting the connector MCP endpoint
- `MCP_TRUST_FORWARDED_BEARER` - allow a bearer already validated by the shared host; internal shared-host mode only
- `MCP_OAUTH_ISSUER` - standalone/public OAuth issuer; empty behind the shared host
- `MCP_RESOURCE_URL` - standalone/public MCP resource URL; empty behind the shared host
- `MCP_PORT` - host-side published connector port
- `MCP_BIND_ADDRESS` - host-side bind address; the shared-host registration uses `127.0.0.1`
- `MCP_ALLOWED_ORIGINS` - optional browser-origin allowlist

Manual Docker start:

```bash
cd plugins/gitea-connector
cp .env.example .env
# edit .env
docker compose up -d --build
```

## Tests

The connector contains dependency-free unit tests. The HTTP transport tests include the internal forwarded-bearer mode used by the shared Bratonien MCP host.

From the connector directory:

```bash
python3 -m unittest discover -s tests
```

Tests are deliberately executed manually or by the target-system installer. This repository does not use GitHub Actions.

## Legacy standalone installer

The older `install/proxmox*.sh` scripts remain in this directory for recovery/reference of the previous standalone deployment. They install a Gitea-only MCP and tunnel in one LXC.

They are no longer the canonical architecture for Bratonien. New installations should use the shared Bratonien MCP host plus `install/register-with-bratonien-mcp.sh`.

Keeping the legacy installer for now avoids destroying the last known standalone recovery path before the new multi-connector host has been exercised in production.

## Current scope

The connector provides tools for repositories, files, commits, branches, tags, issues, pull requests, reviews, merges, releases and a safety-filtered catalog of additional Gitea project operations.

Security-sensitive operations such as password, token, secret, user-administration, permission, runner and webhook management are intentionally excluded.

The original implementation was verified against Gitea 1.24.5.
