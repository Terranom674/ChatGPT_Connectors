# Manifold Connector

MCP connector for administering a self-hosted Manifold instance from ChatGPT and other MCP clients.

The connector integrates Manifold with the shared Bratonien MCP host and exposes Manifold functions under the `manifold__` namespace.

## Features

- Project management
- Text and text-section management
- Resource and resource-collection management
- Ingestions and reingestion workflows
- Journals, volumes and issues
- Reading groups and memberships
- Users, user groups and permissions
- Comments and annotations
- Site settings, search and statistics
- Project exports
- Tus file uploads
- Administrative operations supported by Manifold

The Manifold base URL is configurable and is not hardcoded in the connector.

## Requirements

The connector is intended for an existing Bratonien MCP installation.

Required on the MCP LXC:

- Docker with Docker Compose
- Python 3
- `curl`
- `tar`
- `openssl`

A Manifold user with sufficient permissions is also required. The connector authenticates with that account and uses the permissions assigned to it in Manifold.

## Installation

Run the installer from the Proxmox host shell or from the shell of the existing MCP LXC:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Terranom674/ChatGPT_Connectors/main/manifold/install/register-with-bratonien-mcp.sh)
```

When started on a Proxmox host, the installer locates the existing Bratonien MCP LXC automatically and continues the installation there.

During installation you will be asked for:

- Manifold base URL
- Manifold user e-mail address
- Manifold password

Example base URL:

```text
https://chroniken.bratonien.de
```

The installer stores the configured base URL locally as `MANIFOLD_URL`, so changing the Manifold domain later does not require changes to the connector code.

## Authentication

The connector authenticates against Manifold using:

```text
POST /api/v1/tokens
```

The returned JWT is used for subsequent API requests and is refreshed automatically when authentication expires or is rejected.

Credentials remain on the MCP server and are not stored in the ChatGPT app configuration.

## MCP integration

The connector is registered on the existing Bratonien MCP host as:

```text
manifold
```

Tools are therefore exposed with names such as:

```text
manifold__list_projects
manifold__create_project
manifold__update_text
manifold__list_users
manifold__update_settings
```

The public MCP endpoint remains:

```text
https://mcp.bratonien.de/mcp
```

## Repository structure

```text
install/
  register-with-bratonien-mcp.sh

plugins/manifold-connector/
  operations.py
  management_surface.py
  server.py
  http_server.py
  Dockerfile
  docker-compose.yml
  .env.example
  .mcp.json
  .codex-plugin/
```

`operations.py` contains the supported Manifold API operations. `management_surface.py` defines the stable set of operations exposed to MCP clients. `server.py` handles Manifold authentication and API requests, while `http_server.py` provides the MCP HTTP endpoint used by the central Bratonien MCP host.

## Configuration

The connector uses the following environment variables:

| Variable | Description |
| --- | --- |
| `MANIFOLD_URL` | Base URL of the Manifold instance |
| `MANIFOLD_EMAIL` | Manifold account used by the connector |
| `MANIFOLD_PASSWORD` | Password of the Manifold account |
| `MCP_HTTP_TOKEN` | Internal token between the central MCP host and this connector |
| `MCP_BIND_ADDRESS` | Local bind address, normally `127.0.0.1` |
| `MCP_PORT` | Local connector port, normally `8102` |
| `MCP_CONTAINER_NAME` | Docker container name |

## Security

The Manifold credentials and internal MCP token are stored only on the MCP server. The connector listens on the local interface by default and is intended to be accessed through the central Bratonien MCP host rather than exposed directly to the internet.

Access to Manifold is limited by the permissions of the configured Manifold account.

## License

No license has been specified for this repository.
