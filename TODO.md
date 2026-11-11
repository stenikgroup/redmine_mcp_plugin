# TODO

Tools that were considered and postponed. Every tool the plugin ships maps to a
Redmine OAuth scope (a role permission) and, where one exists, to a REST API
action. The entries below are held back because one of the two is missing or
because they need the `admin` scope.

Checked against Redmine `7.0-stable`: `lib/redmine/preparation.rb` for the
scopes, `accept_api_auth` in the controllers for the REST API actions.

## Postponed: no REST API equivalent yet

These have an OAuth scope but no REST API action to model the parameters and
validations on. Revisit when core exposes them.

| Tool | Scope | REST API status |
|---|---|---|
| `list_documents`, `get_document` | `view_documents` | Documents resource arrives in Redmine 7.1 |
| `create_document` | `add_documents` | Documents resource arrives in Redmine 7.1 |
| `update_document` | `edit_documents` | Documents resource arrives in Redmine 7.1 |
| `delete_document` | `delete_documents` | Documents resource arrives in Redmine 7.1 |
| `comment_news` | `comment_news` | No API action on comments |
| `save_query` (create or update a saved query) | `save_queries`, `manage_public_queries` | Queries are read-only (`index` only) |

## Postponed: no REST API action

| Tool | Scope | Note |
|---|---|---|
| Delete one version of a wiki page | `delete_wiki_pages` | `destroy_version` is a web action only |

## Postponed: needs a binary transport

`add_issue_attachment` and `add_file` take the file as text, so only text files can be sent. Images,
PDFs and archives need a way to pass bytes, which the tools do not have yet.

## Postponed: requires the `admin` scope

Redmine has no fine-grained permission for these; they are open to
administrators only, so a token needs the global `admin` scope. Left out until
there is a clear need and a decision on exposing administration over MCP.

| Tool | REST API resource |
|---|---|
| `archive_project`, `unarchive_project` | Projects (`archive`, `unarchive`) |
| User management (create, update, lock, delete) | Users |
| Group management (create, update, delete, members) | Groups |
| Role listing and details | Roles |
| Custom field listing | Custom Fields |

## Not planned

- Repository: `view_changesets`, `browse_repository`, `commit_access`,
  `manage_related_issues`, `manage_repository`.
- Forums: no REST API (`view_messages`, `add_messages`, `manage_boards`, ...).
- Calendar and Gantt: `view_calendar`, `view_gantt`.
- Webhooks and CSV imports: `use_webhooks`, `import_issues`,
  `import_time_entries`.
