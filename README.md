# redmine_mcp_plugin

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs inside Redmine as a
plugin. It adds one endpoint, `POST /mcp`, and authenticates it with Redmine's own mechanisms. Every
tool runs as a real Redmine user and is limited by that user's permissions.

Version 0.1.0. Read-only by default.

Target platform, which is what we run:

| | |
|---|---|
| Redmine | 6.1.2 |
| Rails | 7.2.3 (pinned by Redmine 6.1.2's `Gemfile`) |
| Ruby | 3.3.11, via rbenv |

`init.rb` declares a floor of Redmine 6.1.0, which is where OAuth2 (Doorkeeper) support lands. We
develop and run against 6.1.2 and do not test anything else.

## Deployment

Redmine runs under Phusion Passenger inside nginx. The plugin is cloned as the `redmine` system
user:

```bash
sudo -u redmine git clone https://github.com/stenikgroup/redmine_mcp_plugin.git \
  /path/to/redmine/plugins/redmine_mcp_plugin
sudo systemctl restart nginx
```

No `bundle install`, no migrations, no changes to Redmine core. Passenger reloads the application
with nginx, so the restart above is the whole deployment step.

### Plugin settings

Administration → Plugins → Redmine MCP Server → Configure. The endpoint is off until you switch it
on. Our configuration:

| Setting | Value |
|---|---|
| Enabled | on |
| OAuth2 | on |
| API key | **off** |
| HTTP Basic | **off** |
| Session cookie | **off** |

OAuth2 only, deliberately. It is the only mode whose credential can be narrower than the user
holding it: a token carries scopes, and `User#allowed_to?` intersects the user's role permissions
with them. An API key carries the user's entire permission set with no scope narrowing at all, so
enabling that mode discards the one restriction we rely on the token for. HTTP Basic has the same
problem and additionally sends reusable credentials on every request; the session cookie mode
carries ambient browser credentials.

API key mode ships **on** by default (`lib/redmine_mcp_plugin/settings.rb`), so switching it off is
an explicit step, not something the defaults do for you.

### OAuth application scopes

Administration → Applications → the MCP application. Enable at least the scopes the server
advertises. Enabling more is fine — verified live, consent succeeds — but fewer fails with
`invalid_scope`, because the client requests exactly what `scopes_supported` lists. The permission
names below are the scope; the label is what the English UI shows, and several labels repeat across
sections.

| Scope | Label in Administration → Applications | Section |
|---|---|---|
| `view_project` | View projects | Project |
| `view_issues` | View Issues | Issue tracking |
| `view_wiki_pages` | View wiki | Wiki |
| `view_time_entries` | View spent time | Time tracking |
| `add_issues` | Add issues | Issue tracking |
| `edit_issues` | Edit issues | Issue tracking |
| `edit_own_issues` | Edit own issues | Issue tracking |
| `add_issue_notes` | Add notes | Issue tracking — **not** the "Add notes" under Contacts |
| `log_time` | Log spent time | Time tracking — **not** "Log spent time for other users" |
| `set_notes_private` | Set notes as private | Issue tracking |

The first four are advertised in read-only mode, which is the default, and are all an application
needs while the server stays read-only. The last six are advertised only once read-only mode is
switched off. `set_notes_private` gates no tool: `add_issue_note` checks it for `private: true`, and
a permission a tool checks at runtime must be advertised, or no token can ever carry it.

Adding a tool with a new permission changes the advertised set, and every user reconnects to get a
token that carries it. The application only needs editing if it did not already enable the scope.

## Local patches

Two changes are ours, both in this repository.

### `supported_scopes`

`app/controllers/mcp_metadata_controller.rb` enumerates the OAuth2 scopes advertised in both
discovery documents. Upstream advertised every scope Doorkeeper knows — every Redmine permission
plus `admin`, ~200 in all. Claude requests exactly what `scopes_supported` lists, so consent either
failed with `invalid_scope` or granted far more than the tools use.

Ours advertises the permissions the registered tools declare (`mcp_permissions`) and the ones they
check at runtime (`scopes`), dropping the write tools while the server is read-only, intersected
with what Doorkeeper will accept. Read-only gives `view_project`, `view_issues`, `view_wiki_pages`
and `view_time_entries`; with writes on, add `add_issues`, `add_issue_notes`, `edit_issues`,
`edit_own_issues`, `log_time` and `set_notes_private`. The OAuth application in Redmine must enable
at least these; it may enable more. The same file probes Doorkeeper for PKCE support rather than
assuming it, and advertises `S256` only — never `plain`, which MCP clients may not select.

On our instance PKCE support is confirmed: `/.well-known/oauth-authorization-server` returns
`"code_challenge_methods_supported": ["S256"]`, verified against the live server.

### Doorkeeper URL generation

Redmine's layouts, and the plugins that extend them, reference controllers relatively:
`controller: 'my'` in the account link, `controller: 'people'` in redmine_people's avatar helper.
Rails resolves a relative controller against the one in the current request's path parameters,
which inside Doorkeeper is `doorkeeper/authorizations`, so every such reference becomes
`doorkeeper/<name>` and raises `UrlGenerationError` — a 500 on the OAuth2 consent screen of any
install whose layout links to a user, which includes ours.

`lib/redmine_mcp_plugin/doorkeeper_url_options.rb` strips the `doorkeeper/` prefix from the recalled
controller in the three Doorkeeper controllers, and `init.rb` applies it in `after_initialize`.
The timing matters: plugin `init.rb` files run in a `to_prepare` block registered before the one in
which Redmine configures Doorkeeper, and touching a Doorkeeper controller before that configuration
binds it to `ActionController::Base` for the life of the process. The module is prepended, so an
install that still carries the older patch of `config/initializers/30-redmine.rb` keeps working;
that patch can be removed at the next restart.

## Authentication

Four modes, each switchable in Administration → Plugins → Redmine MCP Server. Each is a code path
Redmine core already implements. We run OAuth2 only; the other three are documented because the code
supports them.

| Mode | Plugin default | Notes |
|---|---|---|
| OAuth2 | on | Per-user access tokens from Redmine's own provider. Scopes can narrow a token below the issuing user's own permissions. |
| API key | on | The `X-Redmine-API-Key` header. Carries the user's full permissions, no scope narrowing. |
| HTTP Basic | off | Reusable credentials on every request. Refused for accounts with 2FA active, matching core. |
| Session cookie | off | For clients running in the browser. Origin checked. |

Every token mode also requires the REST API to be enabled in Administration → Settings → API.

For OAuth2, register an application under Administration → Applications, then send
`Authorization: Bearer <token>`.

### Discovery

Two documents let a client find the authorization server without being told where it is:

```
/.well-known/oauth-protected-resource        RFC 9728
/.well-known/oauth-protected-resource/mcp
/.well-known/oauth-authorization-server      RFC 8414
```

A 401 from `/mcp` carries `WWW-Authenticate: Bearer realm="Redmine", resource_metadata="..."` pointing
at the first of those. Both are served only while the endpoint and OAuth2 mode are enabled, and 404
otherwise: advertising a disabled endpoint only sends clients down a dead end.

Redmine has no dynamic client registration (RFC 7591), so no `registration_endpoint` is advertised.
Create the application by hand and give the client its id and secret.

## Permission model

Every tool declares the Redmine permission it needs. Two checks run before it does:

1. `User#allowed_to?`, which intersects the user's role permissions with the OAuth token's scopes.
2. Core's `.visible` scopes: `Issue.visible`, `Project.visible`, `Principal.visible` and so on.

Both are needed, and neither subsumes the other. The `.visible` scopes are built on
`Project.allowed_to_condition`, which calls `role.allowed_to?(permission)` with **no scope
argument** — so they honour roles but are blind to OAuth scopes. A token scoped to `view_wiki_pages`
but not `view_issues` would still see issues if `.visible` were the only check. In the other
direction, `allowed_to?` alone would return rows from projects the user is not a member of.

`User#admin?` is scope-aware too: an admin acts as an admin only when the token carries the `admin`
scope, which this server never requests. Through the plugin an admin sees and does what their
memberships grant, and nothing more.

### Tracker-level permissions

Redmine grants five issue permissions **per tracker**, not per project: `view_issues`, `add_issues`,
`edit_issues`, `add_issue_notes` and `delete_issues`. `User#allowed_to?` does not know about
trackers, so a project-level check alone would let a role granted a permission on one tracker act on
every tracker in the project.

Of the four that this plugin exercises:

- `view_issues` — handled by core. `Issue.visible_condition` applies the tracker filter in SQL, and
  every read tool goes through `Issue.visible(user)`.
- `add_issues` — `create_issue` checks `Issue#allowed_target_trackers` and **refuses** a tracker the
  caller may not use, naming it. Core silently substitutes the first permitted tracker instead,
  because core is redisplaying a form to a human who can see the result; an agent reports success to
  somebody who will not check. With no tracker named, the tool uses the only permitted one or refuses
  and lists them.
- `edit_issues` and `edit_own_issues` — `update_issue` checks `Issue#attributes_editable?`, which
  applies both per tracker, on top of the scope-aware `allowed_to?`.
- `add_issue_notes` — `add_issue_note` checks `Issue#notes_addable?`. Core applies this through
  `safe_attributes`, a path the tool does not take.

### Private notes

Notes marked private are filtered by `Journal.visible`, which is core's own rule: a journal is
visible if it is not private, or the caller wrote it, or the caller's role holds
`view_private_notes`.

That filter is built on `Project.allowed_to_condition` and is therefore **not narrowed further by
OAuth scope**. A token whose scopes omit `view_private_notes` will still see private notes if the
user's role grants it. This is deliberate on our side: roles are the access boundary we rely on, and
token scopes are a second, coarser restriction on top of them — not the thing that decides who may
read what.

Writing one is the other way round: `add_issue_note` with `private: true` checks `set_notes_private`
through the scope-aware `allowed_to?`, which is why that permission is advertised as a scope once
writes are on.

## Tools

Read-only unless marked write. Write tools are hidden from `tools/list` and refused by `tools/call`
while read-only mode is on, which is the default.

| Tool | Permission |
|---|---|
| `whoami` | none. Reports identity, auth mode and granted scopes |
| `list_projects`, `get_project` | `view_project` |
| `search_issues`, `get_issue` | `view_issues` |
| `list_queries` | `view_issues`. Saved queries, filtered by `IssueQuery.visible` |
| `list_wiki_pages`, `get_wiki_page` | `view_wiki_pages` |
| `list_enumerations` | none. Trackers, statuses, priorities, time entry activities |
| `list_users` | none. Filtered by `Principal.visible` |
| `list_time_entries` | `view_time_entries`. Totals, per-group hours and each entry's custom fields, filtered by `TimeEntry.visible` |
| `get_issue_fields` | `view_issues`. What the caller may set on an issue, before a write |
| `create_issue` (write) | `add_issues`, on the requested tracker |
| `update_issue` (write) | `edit_issues`, or `edit_own_issues` on one's own issue, on the issue's tracker |
| `add_issue_note` (write) | `add_issue_notes`, on the issue's tracker, plus `set_notes_private` for private notes |
| `log_time` (write) | `log_time`. Always for the authenticated user |

`get_issue` respects per-field custom field visibility and filters private notes by role, as above.
`list_users` uses `Principal.visible` rather than `User.all`, which honours each role's
`users_visibility` setting.

Parameters use one shape per concept across tools: an issue is `issue`, a numeric id; a project is
`project`, an identifier or numeric id; a person — `assigned_to`, `author`, `user` — is a user id from
`list_users`, or `"me"`. Filters that name a project, an issue, a version or a category through
`filters` are authorised like the named parameters, so an invisible one is refused rather than
answered with zero.

Writes refuse rather than guess, and save nothing when they refuse: `create_issue` needs `tracker`
when the project allows more than one, and `log_time` needs `activity`. `create_issue` and
`update_issue` refuse by name any field or custom field, and `update_issue` any status, that the role,
tracker or workflow does not let this user set; `log_time` does the same for custom fields. These are
the things core would drop silently and save the rest.

Arguments are checked against each tool's declared schema. A value outside a declared `enum`, below a
declared `minimum`, of the wrong type, or missing when required is refused rather than ignored.

The list tools take `limit` and `offset` and return `total_count`, `returned`, `offset` and `has_more`.
`limit` is capped by the `max_results` setting, 100 by default, so page with `offset`.

## Protocol

2026-07-28 is stateless: no `initialize` handshake and no `Mcp-Session-Id`. `server/discover` is
implemented, as that revision requires. Results carry `resultType` and server identity in `_meta`, and
list results carry `ttlMs` and `cacheScope: private` because the tool set varies per caller.

2025-11-25 and 2025-06-18 are the handshake revisions most shipped clients still speak. `initialize` is
answered for those.

One JSON response per POST, no SSE. JSON-RPC batching is refused rather than half processed. The
`Origin` header is validated on every request for DNS-rebinding protection; non-browser clients send
none and are unaffected.

### GET and DELETE on `/mcp`

The endpoint has no server-to-client stream and never issued a session, so `GET` and `DELETE` both
end in 405 — but **only for a request that has already authenticated**. Authentication is a
`before_action` and runs first, so the status a client actually sees depends on how far up the chain
it gets:

| Condition | Status |
|---|---|
| Endpoint disabled in plugin settings | 403 |
| `Origin` present and not allowed | 403 |
| No authentication mode enabled | 503 |
| No or invalid credential | 401, with `WWW-Authenticate` when OAuth2 mode is on |
| Authenticated | 405 |

So an unauthenticated `GET /mcp` returns 401, not 405. That is the intended behaviour: the endpoint
does not describe itself to anonymous callers beyond pointing them at the discovery documents.

## Client configuration

For a client that takes a fixed header, such as a `curl` test. Access tokens expire after two hours,
so this is for testing; claude.ai reads the discovery documents and runs the OAuth2 flow itself.

```json
{
  "mcpServers": {
    "redmine": {
      "type": "http",
      "url": "https://redmine.example.com/mcp",
      "headers": { "Authorization": "Bearer YOUR_OAUTH2_TOKEN" }
    }
  }
}
```

## Licence

GPL-2. See [LICENSE](LICENSE).

This project began as [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin)
and is maintained here as our own; the original copyright notices are preserved as the licence
requires.
