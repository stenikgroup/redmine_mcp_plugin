# redmine_mcp_plugin

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs inside Redmine as a
plugin. It adds one endpoint, `POST /mcp`, and authenticates it with Redmine's own mechanisms. Every
tool runs as a real Redmine user and is limited by that user's permissions.

Version 0.3.0. Read-only by default. See [CHANGELOG.md](CHANGELOG.md).

> [!WARNING]
> **This fork carries security fixes that the upstream projects do not have.** If you run
> [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin) or
> [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin) with OAuth2,
> switch to this fork or port the fixes. The four flaws, and where each upstream stands, are in
> [docs/security.md](docs/security.md).

## What an agent can do

51 tools, each gated on the Redmine permission that covers the same act in the web interface. The
write and delete columns are hidden until read-only mode is switched off.

| Domain | Read | Write | Delete |
|---|---|---|---|
| Projects | `list_projects`, `get_project`, `list_memberships` | `create_project`, `update_project`, `close_project`, `reopen_project`, `create_version`, `update_version`, `create_issue_category`, `update_issue_category`, `update_membership` | `delete_project`, `delete_version`, `delete_issue_category`, `delete_membership` |
| Issues | `search_issues`, `get_issue`, `list_queries`, `get_issue_fields` | `create_issue`, `update_issue`, `copy_issue`, `add_issue_note`, `update_issue_note`, `update_issue_relations`, `update_issue_checklists` | `delete_issue` |
| Time | `list_time_entries` | `log_time`, `update_time_entry` | `delete_time_entry` |
| Wiki | `list_wiki_pages`, `get_wiki_page`, `list_wiki_page_versions` | `update_wiki_page` | `delete_wiki_page` |
| News | `list_news`, `get_news` | `create_news`, `update_news` | `delete_news` |
| Files | `get_attachment`, `list_files` | `add_issue_attachment`, `add_file` | `delete_attachment` |
| Reference | `whoami`, `search`, `list_enumerations`, `list_users` | | |

The permission behind each tool is in [docs/tools.md](docs/tools.md). Tools that were considered and
postponed are in [TODO.md](TODO.md).

## Requirements

| Redmine | Rails | Ruby |
|---|---|---|
| 6.1.2 | 7.2.3 | 3.3 |
| 7.0.2 | 8.1.4 | 3.3 |

Redmine 6.1.0 is the floor: it is where OAuth2 (Doorkeeper) support lands. What was checked, and
how, is in [docs/installation.md](docs/installation.md#compatibility).

## Quick start

1. Clone the plugin and restart. No `bundle install`, no migrations, no changes to Redmine core.

   ```bash
   sudo -u redmine git clone https://github.com/herewithme/redmine_mcp_plugin.git \
     /path/to/redmine/plugins/redmine_mcp_plugin
   sudo systemctl restart nginx
   ```

2. Enable the REST API in Administration → Settings → API.
3. Switch the endpoint on in Administration → Plugins → Redmine MCP Server → Configure. Keep OAuth2
   and switch API key mode off: it ships on, and a key carries its user's full permissions.
4. Register an application in Administration → Applications and enable the scopes listed in
   [docs/scopes.md](docs/scopes.md). Fewer than the server advertises fails with `invalid_scope`.
5. Point the client at `https://redmine.example.com/mcp`. claude.ai reads the discovery documents
   and runs the OAuth2 flow itself; a fixed-header configuration for testing is in
   [docs/authentication.md](docs/authentication.md#client-configuration).

The server stays read-only until you switch read-only mode off on the same settings page.

## Documentation

| You are | Read |
|---|---|
| Installing or administering | [Installation and settings](docs/installation.md), [Authentication](docs/authentication.md), [OAuth application scopes](docs/scopes.md) |
| Using the tools through an agent | [Tools](docs/tools.md), [Tool conventions](docs/tool-conventions.md) |
| Writing an extension or a client | [Extensions](docs/extensions.md), [Protocol](docs/protocol.md) |
| Maintaining or auditing the plugin | [Permission model](docs/permissions.md), [Internals](docs/internals.md), [Security notice](docs/security.md) |

Changes per version are in [CHANGELOG.md](CHANGELOG.md).

## A fork of a fork

This repository, [herewithme/redmine_mcp_plugin](https://github.com/herewithme/redmine_mcp_plugin),
is the third link in a chain:

1. [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin), by João
   Figueira: the original plugin - the `/mcp` endpoint on Redmine's own authentication and
   permissions, schema validation, paging and OAuth2 discovery.
2. [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin), by Stenik
   (Stoyan Tinchev), forked from the first: write tools, every issue field, relations, news,
   attachments, checklists and tags, narrowed OAuth2 scopes, the Doorkeeper fix and extensions.
3. This fork, by Be API (Amaury Balmer), forked from the second: Redmine 7.0 compatibility, a
   working test suite, custom field values checked before a write, and **security fixes the first
   two do not have** (see [docs/security.md](docs/security.md)). See the changelog.

## Licence

GPL-2. See [LICENSE](LICENSE).

This project began as [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin),
continued as [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin), and
is maintained here; the original copyright notices are preserved as the licence requires.
