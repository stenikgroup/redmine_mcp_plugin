# redmine_mcp_plugin

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs inside Redmine as a
plugin. It adds one endpoint, `POST /mcp`, and authenticates it with Redmine's own mechanisms. Every
tool runs as a real Redmine user and is limited by that user's permissions.

Version 0.3.0. Read-only by default. See [CHANGELOG.md](CHANGELOG.md).

> [!WARNING]
> **This fork carries security fixes that the upstream projects do not have.** Version 0.3.0 fixes
> four vulnerabilities found by a security audit, all rated low. Three of them come from upstream
> code and are still there: if you run
> [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin) or
> [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin) with OAuth2,
> switch to this fork or port the fixes.
>
> | Fixed in 0.3.0 | joaoperfig, `2375a2d` | stenikgroup, `12374fe` |
> |---|---|---|
> | A token scoped to a write permission without the matching view permission (`edit_issues` or `add_issue_notes` without `view_issues`, `manage_news` without `view_news`) could act on a record it may not read, and read it back in the reply | **Present** in `add_issue_note`, without the read-back | **Present** in every issue and news write tool, with the read-back |
> | `get_issue` returned other users' private notes to a token without `view_private_notes` | **Present** | **Present** |
> | A refused custom field value named fields the caller may not read: another object type's, or one restricted to other roles | Not applicable: no tool sets custom fields | **Present** |
> | An excluded custom field could still be filtered on through a chained key such as `cf_N.status` | Not applicable: field exclusion is this fork's | Not applicable |
>
> Each upstream was checked by reading its code at the commit named, its latest on 2026-11-06. The
> stenikgroup code is identical to the code in which this fork reproduced the flaws before fixing
> them. The fixes and their regression tests are listed in the changelog under 0.3.0.

## A fork of a fork

This repository, [herewithme/redmine_mcp_plugin](https://github.com/herewithme/redmine_mcp_plugin),
is the third link in a chain:

1. [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin), by João
   Figueira: the original plugin - the `/mcp` endpoint on Redmine's own authentication and
   permissions, schema validation, paging and OAuth2 discovery.
2. [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin), by Stenik
   (Stoyan Tinchev), forked from the first: write tools, every issue field, relations, news,
   attachments, checklists and tags, narrowed OAuth2 scopes, the Doorkeeper fix and extensions.
   Most of this README is theirs, and "we" and "our" in it describe their deployment.
3. This fork, by Be API (Amaury Balmer), forked from the second: Redmine 7.0 compatibility, a
   working test suite, custom field values checked before a write, and **security fixes the first
   two do not have** (see the notice above). See the changelog.

## Compatibility

Checked with version 0.2.0 on 2026-10-27:

| Redmine | Rails | Ruby |
|---|---|---|
| 6.1.2 | 7.2.3 | 3.3 |
| 7.0.2 | 8.1.4 | 3.3 |

On each, the test suite passes and every tool was exercised live, over an API key and over a scoped
OAuth2 token. Rails is the version each Redmine pins in its `Gemfile`. `init.rb` declares a floor of
Redmine 6.1.0, which is where OAuth2 (Doorkeeper) support lands. Redmine 7.0 removed
`Issue#addable_watcher_users`; the plugin rebuilds that list itself from core scopes that exist on
both versions.

Be API runs this fork in production on Redmine trunk, with Rails 8.1.4 and Ruby 3.2.3. The test
suite is not run there: trunk and Ruby 3.2 are covered by live use only, and a core removal reaches
trunk before any release.

Before this fork, stenikgroup developed and ran the plugin on Redmine 6.1.2 with Ruby 3.3.11.

## Deployment

Redmine runs under Phusion Passenger inside nginx. The plugin is cloned as the `redmine` system
user:

```bash
sudo -u redmine git clone https://github.com/herewithme/redmine_mcp_plugin.git \
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

#### Excluded custom fields

The same page lists every custom field, grouped by type. A checked field is hidden from every MCP
client, whatever the user may see of it in Redmine:

- left out of every reply that carries custom fields (`get_issue`, `get_project`, `list_projects`,
  `list_time_entries`, `get_issue_fields`, `list_enumerations`, the state a write echoes back) and
  of the issue history;
- refused as a value to set, like a field the user may not edit, and named in the refusal by id
  only. A required excluded field therefore blocks a create through MCP, with core's own "cannot be
  blank";
- unknown to `search_issues` and `list_time_entries` as a filter, sort or grouping, including
  `issue.cf_N` and `project.cf_N`, and in any position of a chained filter: `cf_N.status`,
  `cf_N.cf_M` and `cf_M.cf_N` are all unknown. A saved query that sorts or groups on it runs unsorted or
  ungrouped on that field; a filter it stores still applies.

`search` still matches the field's text when the field is searchable: clear its Searchable flag too.
To hide a field from some roles everywhere, Redmine's own field visibility is the right tool, and the
plugin honours it already. The setting is for what an agent should not read even when its user may.

### OAuth application scopes

Administration → Applications → the MCP application. Enable at least the scopes the server
advertises. Enabling more is fine - verified live, consent succeeds - but fewer fails with
`invalid_scope`, because the client requests exactly what `scopes_supported` lists. The permission
names below are the scope; the label is what the English UI shows, and several labels repeat across
sections.

| Scope | Label in Administration → Applications | Section |
|---|---|---|
| `view_project` | View projects | Project |
| `view_issues` | View Issues | Issue tracking |
| `view_issue_watchers` | View watchers list | Issue tracking |
| `view_private_notes` | View private notes | Issue tracking |
| `view_wiki_pages` | View wiki | Wiki |
| `view_time_entries` | View spent time | Time tracking |
| `view_news` | View news | News |
| `view_members` | View project members | Project |
| `search_project` | Search projects | Project |
| `view_wiki_edits` | View wiki history | Wiki |
| `view_files` | View files | Files |
| `view_documents` | View documents | Documents - read by `search` only |
| `view_changesets` | View changesets | Repository - read by `search` only |
| `view_messages` | View messages | Forums - read by `search` only |
| `view_checklists` | View checklist | Issue tracking, with redmine_checklists installed |
| `add_issues` | Add issues | Issue tracking |
| `edit_issues` | Edit issues | Issue tracking |
| `edit_own_issues` | Edit own issues | Issue tracking |
| `add_issue_notes` | Add notes | Issue tracking - **not** the "Add notes" under Contacts |
| `log_time` | Log spent time | Time tracking |
| `log_time_for_other_users` | Log spent time for other users | Time tracking |
| `edit_time_entries` | Edit time logs | Time tracking |
| `edit_own_time_entries` | Edit own time logs | Time tracking |
| `copy_issues` | Copy issues | Issue tracking |
| `edit_wiki_pages` | Edit wiki pages | Wiki |
| `rename_wiki_pages` | Rename wiki pages | Wiki |
| `protect_wiki_pages` | Protect wiki pages | Wiki |
| `manage_files` | Manage files | Files |
| `delete_issues` | Delete issues | Issue tracking |
| `delete_project` | Delete the project | Project |
| `delete_wiki_pages` | Delete wiki pages | Wiki |
| `delete_wiki_pages_attachments` | Delete attachments | Wiki |
| `set_notes_private` | Set notes as private | Issue tracking |
| `edit_own_issue_notes` | Edit own notes | Issue tracking |
| `edit_issue_notes` | Edit notes | Issue tracking |
| `manage_subtasks` | Manage subtasks | Issue tracking |
| `add_issue_watchers` | Add watchers | Issue tracking |
| `delete_issue_watchers` | Delete watchers | Issue tracking |
| `set_issues_private` | Set issues public or private | Issue tracking |
| `set_own_issues_private` | Set own issues public or private | Issue tracking |
| `manage_issue_relations` | Manage issue relations | Issue tracking |
| `manage_news` | Manage news | News |
| `add_project` | Create project | Project |
| `add_subprojects` | Create subprojects | Project |
| `edit_project` | Edit project | Project |
| `close_project` | Close / reopen the project | Project |
| `select_project_publicity` | Set project public or private | Project |
| `select_project_modules` | Select project modules | Project |
| `manage_members` | Manage members | Project |
| `manage_versions` | Manage versions | Project |
| `manage_categories` | Manage issue categories | Issue tracking |
| `done_checklists` | Done checklist items | Issue tracking, with redmine_checklists installed |
| `edit_checklists` | Edit checklist items | Issue tracking, with redmine_checklists installed |
| `create_tags` | Create tags | Issue tracking, with redmineup_tags installed |
| `edit_tags` | Edit tags | Issue tracking, with redmineup_tags installed |

The `view_` rows are advertised in read-only mode, which is the default, and are all an application
needs while the server stays read-only. The others are advertised only once read-only mode is
switched off. The checklist and tag rows exist only while that plugin is installed; the server reads
this per request, so installing or removing one of those plugins changes the advertised set the way
adding a tool does. Several scopes gate no tool but one parameter, or one part of a reply:
`set_notes_private` for `private_notes: true`, `manage_subtasks` for `parent`, `add_issue_watchers`
and `delete_issue_watchers` for watchers, `set_issues_private` and `set_own_issues_private` for
`is_private`, `view_issue_watchers`, `view_private_notes` and `view_checklists` for what `get_issue` includes, `edit_tags`
and `create_tags` for tags, `select_project_publicity` for `is_public`, `select_project_modules` for
`enabled_modules`, and `manage_members` for `inherit_members` on a project. A permission a tool checks at runtime must be advertised, or no token can
ever carry it.

Adding a tool with a new permission changes the advertised set, and every user reconnects to get a
token that carries it. The application only needs editing if it did not already enable the scope.
An extension adds the permissions of its tools in the same way; see Extensions.

## Local patches

Two changes came from the stenikgroup fork and are not in the original plugin.

### `supported_scopes`

`app/controllers/mcp_metadata_controller.rb` enumerates the OAuth2 scopes advertised in both
discovery documents. Upstream advertised every scope Doorkeeper knows - every Redmine permission
plus `admin`, ~200 in all. Claude requests exactly what `scopes_supported` lists, so consent either
failed with `invalid_scope` or granted far more than the tools use.

Ours advertises the permissions the tools on `/mcp` declare (`mcp_permissions`) and the ones they
check at runtime (`scopes`), an extension's tools included, dropping the write tools while the server
is read-only and the tools and scopes of plugins that are not installed, intersected with what
Doorkeeper will accept.
Read-only gives `view_project`, `view_issues`, `view_issue_watchers`, `view_private_notes`, `view_wiki_pages`,
`view_time_entries`, `view_news`, `view_members`, `search_project`, `view_wiki_edits`, `view_files`,
`view_documents`, `view_changesets` and `view_messages`; with writes on, add `add_issues`, `add_issue_notes`,
`edit_issues`, `edit_own_issues`, `edit_own_issue_notes`, `log_time`, `set_notes_private`,
`manage_subtasks`, `add_issue_watchers`, `delete_issue_watchers`, `set_issues_private`,
`set_own_issues_private`, `manage_issue_relations`, `manage_news`, `add_project`, `add_subprojects`,
`edit_project`, `close_project`, `select_project_publicity`, `select_project_modules`, `manage_members`,
`manage_versions`, `manage_categories`, `edit_issue_notes`, `edit_time_entries`, `edit_own_time_entries`,
`log_time_for_other_users`, `copy_issues`, `edit_wiki_pages`, `rename_wiki_pages`, `protect_wiki_pages`,
`manage_files`, `delete_issues`, `delete_project`, `delete_wiki_pages` and `delete_wiki_pages_attachments`. With redmine_checklists installed, `view_checklists`
joins the read-only set and `done_checklists` and `edit_checklists` the write set; with
redmineup_tags, `create_tags` and `edit_tags` join the write set. The OAuth application in
Redmine must enable at least these; it may enable more. The same file probes Doorkeeper for PKCE support rather than
assuming it, and advertises `S256` only - never `plain`, which MCP clients may not select.

On our instance PKCE support is confirmed: `/.well-known/oauth-authorization-server` returns
`"code_challenge_methods_supported": ["S256"]`, verified against the live server.

### Doorkeeper URL generation

Redmine's layouts, and the plugins that extend them, reference controllers relatively:
`controller: 'my'` in the account link, `controller: 'people'` in redmine_people's avatar helper.
Rails resolves a relative controller against the one in the current request's path parameters,
which inside Doorkeeper is `doorkeeper/authorizations`, so every such reference becomes
`doorkeeper/<name>` and raises `UrlGenerationError` - a 500 on the OAuth2 consent screen of any
install whose layout links to a user, which includes ours.

`lib/redmine_mcp_plugin/doorkeeper_url_options.rb` makes a relative controller absolute in every
URL the three Doorkeeper controllers and their views build, as core's menus already do with
`use_absolute_controller`, and `init.rb` applies it in `after_initialize`. The recalled controller
itself is left alone: URLs built from it alone, such as the sudo mode password form's
`form_tag({})`, must still point at the Doorkeeper route. An earlier version stripped the
`doorkeeper/` prefix from the recall instead, and clicking Authorize with sudo mode on returned a
500 (`No route matches {:action=>"create", :controller=>"authorizations"}`).

The timing matters: plugin `init.rb` files run in a `to_prepare` block registered before the one in
which Redmine configures Doorkeeper, and touching a Doorkeeper controller before that configuration
binds it to `ActionController::Base` for the life of the process.

The first versions of this README asked administrators to patch Redmine's
`config/initializers/30-redmine.rb` by hand to strip the `doorkeeper/` prefix. That patch was never
part of Redmine: neither 6.1.5, 7.0.2 nor trunk (checked 2026-11-11) carry it, and none of them fix the
relative controllers either, so the plugin's module is still needed on Redmine 7. The core patch, on
the other hand, is no longer needed with plugin 0.2.1 or later, and can be removed: revert the file to
the version Redmine ships, restart, then open the OAuth2 consent screen and click Authorize with sudo
mode on. Until it is removed, the module puts back the recalled controller the patch strips, so an
install that still carries it keeps working. Our own instance never carried it.

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

When the request presented a bearer token that is expired, revoked, unknown or owned by a locked
user, the challenge adds `error="invalid_token"` and an `error_description` (RFC 6750 3.1), which
tells the client to refresh its token rather than ask the user to authorize again. A request with no
token gets no error code. Each refused token is logged at `warn`, so it shows even when Redmine logs
nothing below that level:

```
[redmine_mcp_plugin] OAuth2 token refused (expired): token=42 user=5 app=1 created_at=... expires_in=7200 revoked_at=
```

An expired token is refused about every two hours per connected user, before the client refreshes
it: those lines are expected. A user who had to reconnect shows as a token that is refused and then
never followed by a new one for the same user and application in `oauth_access_tokens`.

Redmine has no dynamic client registration (RFC 7591), so no `registration_endpoint` is advertised.
Create the application by hand and give the client its id and secret.

## Permission model

Every tool declares the Redmine permission it needs. Two checks run before it does:

1. `User#allowed_to?`, which intersects the user's role permissions with the OAuth token's scopes.
2. Core's `.visible` scopes: `Issue.visible`, `Project.visible`, `Principal.visible` and so on.

Both are needed, and neither subsumes the other. The `.visible` scopes are built on
`Project.allowed_to_condition`, which calls `role.allowed_to?(permission)` with **no scope
argument** - so they honour roles but are blind to OAuth scopes. A token scoped to `view_wiki_pages`
but not `view_issues` would still see issues if `.visible` were the only check. In the other
direction, `allowed_to?` alone would return rows from projects the user is not a member of.

A write tool checks its own permission (`edit_issues`, `add_issue_notes`, `manage_news`), not the
read one, so `.visible` would be the only read check on the record it writes to and reads back.
Every tool that takes an issue or a news id therefore also calls the scope-aware `Issue#visible?` or
`News#visible?`: a token scoped to `edit_issues` without `view_issues` gets "No visible issue", as
core's REST API answers 403. For news this is stricter than core, which updates a news item under
`manage_news` alone.

`User#admin?` is scope-aware too: an admin acts as an admin only when the token carries the `admin`
scope, which this server never requests. Through the plugin an admin sees and does what their
memberships grant, and nothing more.

### Tracker-level permissions

Redmine grants five issue permissions **per tracker**, not per project: `view_issues`, `add_issues`,
`edit_issues`, `add_issue_notes` and `delete_issues`. `User#allowed_to?` does not know about
trackers, so a project-level check alone would let a role granted a permission on one tracker act on
every tracker in the project.

Of the four that this plugin exercises:

- `view_issues` - handled by core. `Issue.visible_condition` applies the tracker filter in SQL, and
  every read tool goes through `Issue.visible(user)`.
- `add_issues` - `create_issue` checks `Issue#allowed_target_trackers` and **refuses** a tracker the
  caller may not use, naming it. Core silently substitutes the first permitted tracker instead,
  because core is redisplaying a form to a human who can see the result; an agent reports success to
  somebody who will not check. With no tracker named, the tool uses the only permitted one or refuses
  and lists them.
- `edit_issues` and `edit_own_issues` - `update_issue` checks `Issue#attributes_editable?`, which
  applies both per tracker, on top of the scope-aware `allowed_to?`.
- `add_issue_notes` - `add_issue_note` checks `Issue#notes_addable?`. Core applies this through
  `safe_attributes`, a path the tool does not take.

### Private notes

Notes marked private follow core's rule: a journal is visible if it is not private, or the caller
wrote it, or the caller holds `view_private_notes`. `get_issue` applies `Journal.visible`, then
checks `view_private_notes` through the scope-aware `allowed_to?`, as core's issue page and REST API
do.

`Journal.visible` alone is not enough: it is SQL built on `Project.allowed_to_condition`, which reads
roles and ignores OAuth scopes. A token whose scopes omit `view_private_notes` therefore gets no
private note written by someone else, even when the user's role grants it. That is why
`view_private_notes` is advertised as a scope, read-only mode included.

Writing one is the other way round: `add_issue_note` and `update_issue_note` with `private_notes: true`
check `set_notes_private` through the scope-aware `allowed_to?`, which is why that permission is
advertised as a scope once writes are on.

### Notes and time of other users

`update_issue_note` and `update_time_entry` follow core's pair of permissions: `edit_own_issue_notes`
or `edit_own_time_entries` for what the caller wrote or logged, `edit_issue_notes` or
`edit_time_entries` for anyone's. Up to 0.3.0 `update_issue_note` refused other people's notes
whatever the role; that rule is lifted, and a token is kept to its owner's notes and time by leaving
`edit_issue_notes` and `edit_time_entries` out of its scopes. The refusal then names the missing
permission. The journal is found through `Journal.visible`, the right through
`Journal#editable_by?` and `TimeEntry#editable_by?`, and a note saved blank is refused because
Redmine would delete it. Both tools tell the agent to say whose note or entry it is and to get
confirmation before changing someone else's.

`log_time` and `update_time_entry` take `user`. Anyone but the caller needs
`log_time_for_other_users` and must be able to log time on the project, the two causes core reports
alike as "User is invalid".

## Tools

Read-only unless marked write. Write tools are hidden from `tools/list` and refused by `tools/call`
while read-only mode is on, which is the default.

| Tool | Permission |
|---|---|
| `whoami` | none. Reports identity, auth mode and granted scopes |
| `list_projects`, `get_project` | `view_project`. Project custom fields follow core's per-role visibility: always on `get_project`, on `list_projects` with `include_custom_fields` |
| `search_issues`, `get_issue` | `view_issues`. `get_issue` adds the attachments, the subtasks the caller can see, the relations whose other issue the caller can see, the watchers under `view_issue_watchers`, the checklist under `view_checklists`, and the tags |
| `get_attachment` | `view_issues`, through core's `Attachment#visible?`. Metadata, and the content of a text file within `file_max_size_displayed` |
| `list_queries` | `view_issues`. Saved queries, filtered by `IssueQuery.visible` |
| `list_wiki_pages`, `get_wiki_page` | `view_wiki_pages`. `get_wiki_page` with `version` reads an earlier version, under `view_wiki_edits` as in core |
| `list_wiki_page_versions` | `view_wiki_edits`. The page's history, newest first, without the text |
| `list_files` | `view_files`, with the Files module on. The project's files and those of its versions, as core's `/projects/:id/files.json` |
| `search` | `search_project`. Core's search box: issues, news, documents, changesets, wiki pages, forum messages and projects, each only under its own `view_` permission |
| `list_news`, `get_news` | `view_news`. Filtered by `News.visible`; with a project, that project's own news, as core's index |
| `list_enumerations` | none. Trackers, statuses, priorities, time entry activities; with `project`, that project's activities and, for a caller with `log_time` there, the time entry custom fields with their required flag and allowed values |
| `list_users` | none. Filtered by `Principal.visible` |
| `list_memberships` | `view_members`. Users and groups with their roles, inherited ones marked, as core's `/projects/:id/memberships.json`; with `manage_members`, the roles the caller may give |
| `list_time_entries` | `view_time_entries`. Totals, per-group hours and each entry's custom fields, filtered by `TimeEntry.visible` |
| `get_issue_fields` | `view_issues`. What the caller may set on an issue, before a write; with `issue` and `tracker`, what it would be under that tracker, refused as `update_issue` refuses the move |
| `create_issue` (write) | `add_issues`, on the requested tracker, plus `manage_subtasks` for `parent`, `add_issue_watchers` for `watcher_users`, `set_issues_private` or `set_own_issues_private` for `is_private`, `edit_tags` for `tag_list` and `create_tags` for a tag that does not exist yet |
| `update_issue` (write) | `edit_issues`, or `edit_own_issues` on one's own issue, on the issue's tracker, plus the per-field permissions of `create_issue` and `delete_issue_watchers` for `remove_watcher_users`. Watching or unwatching oneself needs none, as core's Watch link |
| `add_issue_note` (write) | `add_issue_notes`, on the issue's tracker, plus `set_notes_private` for private notes |
| `update_issue_note` (write) | `edit_own_issue_notes` for a note the caller wrote, `edit_issue_notes` for anyone's, plus `set_notes_private` to change privacy |
| `add_issue_attachment` (write) | `edit_issues`, `edit_own_issues` or `add_issue_notes`, as core's `attachments_addable?`. A text file within `attachment_max_size` and the extension lists; saved with a journal, so watchers are mailed as for an issue update |
| `update_issue_checklists` (write) | `edit_checklists` to add or rename, `done_checklists` or `edit_checklists` to tick or untick. Present only with redmine_checklists |
| `update_issue_relations` (write) | `manage_issue_relations` on the issue's project, as core's relation form. Every relation type core has |
| `log_time` (write) | `log_time`, plus `log_time_for_other_users` when `user` names someone else |
| `update_time_entry` (write) | `edit_own_time_entries` for the caller's own entry, `edit_time_entries` for anyone's, plus `view_time_entries` to read it and `log_time_for_other_users` to change whose it is. `issue` or `project` moves the entry, under `log_time` on the issue's project as in core |
| `copy_issue` (write) | `copy_issues` on the source project and `add_issues` on the target's tracker, plus the per-field permissions of `create_issue`. Copies the fields, custom fields, parent and attachments, the watchers under `add_issue_watchers`, the subtasks on request, and links the copy as core does |
| `create_news` (write) | `manage_news`. Publishes at once and, when `news_added` is a notified event, emails project members and news watchers; the tool tells the agent to get explicit confirmation first |
| `update_news` (write) | `manage_news`. Editing sends no email |
| `update_wiki_page` (write) | `edit_wiki_pages`. Creates the page or replaces its text, keeping the history; `version` refuses an edit made meanwhile, as core's 409. A protected page needs `protect_wiki_pages`, and `parent_title` on an existing page `rename_wiki_pages`. Watchers are mailed as for an edit in the browser |
| `add_file` (write) | `manage_files`, with the Files module on. A text file, on the project or on one of its versions; mails members when `file_added` is a notified event, as core |
| `delete_issue` (write) | `delete_issues`, on the issue's tracker. Subtasks go with it. With time logged, `time_entries` must say `destroy`, `nullify` or `reassign`, as core's form asks |
| `delete_time_entry` (write) | `edit_own_time_entries` for the caller's own entry, `edit_time_entries` for anyone's, as core |
| `delete_news` (write) | `manage_news` |
| `delete_wiki_page` (write) | `delete_wiki_pages`, plus `protect_wiki_pages` for a protected page. With child pages, `children` must say `nullify`, `destroy` or `reassign`, as core's form asks |
| `delete_attachment` (write) | The container's rule, as core's `Attachment#deletable?`: `edit_issues` or `edit_own_issues` on an issue, where the removal is journaled, `manage_files` on a project or a version, `delete_wiki_pages_attachments` on a wiki page |
| `delete_version` (write) | `manage_versions`. Refused, with the cause, for a version that issues target, that has files, or that a custom field refers to, as core's `Version#deletable?` |
| `delete_issue_category` (write) | `manage_categories`. Its issues lose the category or take `reassign_to` |
| `delete_membership` (write) | `manage_members`. Refused for an inherited role or a role outside the caller's managed roles, as core's `Member#deletable?` |
| `delete_project` (write) | `delete_project`, and an administrator when the project has subprojects, as core's `Project#deletable?`. `confirm` repeats the identifier, as the web form. Core deletes in a background job and mails the user |
| `create_project` (write) | `add_project` for a root project, `add_subprojects` on the parent for a subproject, plus `select_project_publicity` for `is_public`, `select_project_modules` for `enabled_modules` and `manage_members` for `inherit_members`. A non-administrator becomes a member with the default role, as in core |
| `update_project` (write) | `edit_project`, plus the per-field permissions of `create_project`, and `add_subprojects` or `add_project` to move it. The identifier cannot be changed |
| `close_project`, `reopen_project` (write) | `close_project`. Subprojects follow, as in core |
| `create_version`, `update_version` (write) | `manage_versions`. `sharing` within core's `allowed_sharings`. The saved version is read back only under `view_issues`; without it the write is acknowledged by id |
| `create_issue_category`, `update_issue_category` (write) | `manage_categories`, with the issue tracking module on. The default assignee is any user or group, as core's API. Read back only under `view_issues` |
| `update_membership` (write) | `manage_members`. Adds any user or group, or replaces a member's roles, among the roles the caller may manage; inherited roles are left alone |

These tools add no rule of their own to Redmine's: a tool does what its permission allows in core,
and an administrator who does not want one leaves its scope off the OAuth application.

The project structure tools refuse what core would drop in silence, naming the parameter: a field
the role or the token may not set, a parent the caller may not extend, a `sharing` outside
`allowed_sharings`, a role outside the caller's managed roles, an unknown module or tracker. A write
on a closed project says the project is closed, where core's permission check only says no. Archiving a project needs
an administrator; see [TODO.md](TODO.md).

### Deleting

Nine tools delete, and no plugin setting switches them on or off. Each is gated on the permission
Redmine has for that deletion, which is also its OAuth scope: an administrator who does not want
agents to delete leaves `delete_issues`, `delete_project`, `delete_wiki_pages` and
`delete_wiki_pages_attachments` unticked on the OAuth application, and a token without the scope
does not even list the tool. Five deletions share the scope of the matching edit, because Redmine
grants them together: a version with `manage_versions`, a category with `manage_categories`, a
member with `manage_members`, a news item with `manage_news`, a time entry with the two
`edit_time_entries` permissions. Read-only mode, which is the default, hides all of them.

Where core's web form asks a question and its API answers it silently, the tool asks: what becomes
of the time logged on a deleted issue, and of the child pages of a deleted wiki page. Every one is
annotated destructive and tells the agent to get explicit confirmation first.

`search` runs core's own fetcher. Core keeps, for one project, the types the user may view there; its
queries then go through `.visible` scopes, which read roles and not a token's scopes, so the tool
also leaves out every type whose `view_` scope the token lacks. `searched_types` says what was
searched. An excerpt is cut at 500 characters.

`get_issue` respects per-field custom field visibility and filters private notes by role and token scope, as above.
Its history reads as the issue page's: a custom field by its name, a reference without `_id` (`status`,
`assigned_to`, `parent`, `child`), a checklist change as the items added, removed, done, undone and
renamed, shown only under `view_checklists` as the plugin's own history does, and no journal with
neither notes nor a detail the caller may see.

Every custom field row gives its `format` and its stored `value`, which is what the write tools take;
an `enumeration`, `user` or `version` field also names that id in `label`, `null` for a user outside
`Principal.visible`, a version whose issues the caller may not see, or a target deleted since.

`list_users` uses `Principal.visible` rather than `User.all`, which honours each role's
`users_visibility` setting.

Parameter names follow one rule: content fields keep Redmine's attribute names (`subject`,
`description`, `notes`, `custom_field_values`, `tag_list`, `relation_type`, `delay`); a reference to a record is Redmine's name
without `_id` or `_ids` (`issue`, `project`, `news`, `journal`, `parent`, `assigned_to`, `query`,
`category`, `fixed_version`, `watcher_users`, `attachment`, `checklist`); only `filters` keeps
Redmine's query field names verbatim; a null value means not sent, never "clear it".

Parameters use one shape per concept across tools: an issue is `issue`, a numeric id; a project is
`project`, an identifier or numeric id; a news item is `news`; a person - `assigned_to`, `author`, `user` - is a user id from
`list_users`, or `"me"`; `parent` is an issue id; `category` and `fixed_version` are a name or an id
from `get_issue_fields`; the string `"none"` clears an optional date or reference (`parent`, `category`,
`fixed_version`, `assigned_to`, `start_date`, `due_date`). Filters that name a project, an issue, a version or a category through
`filters` are authorised like the named parameters, so an invisible one is refused rather than
answered with zero.

Writes refuse rather than guess, and save nothing when they refuse: `create_issue` needs `tracker`
when the project allows more than one, and `log_time` needs `activity`. `create_issue` and
`update_issue` run every per-field check before refusing, then refuse once, naming each blocked
parameter with its cause: a field, custom field, status, watcher or tag that the role,
tracker, workflow, a setting or a plugin permission does not let this user set, and for a missing
permission the label to ask for, in the caller's language, as in "is_private (needs Set issues public
or private)". The refusal
stays the uniform "You do not have permission to do that" when the caller may not use the tool or
edit the issue at all. These are
the things core would drop silently and save the rest. A `parent` that is invisible, circular, or
outside the cross-project subtasks setting is refused by cause, where core would say only "Parent task
is invalid".

Custom field values are checked before the save, on `create_issue`, `update_issue` and `log_time`
alike, so a wrong one costs one refusal that teaches the fix rather than core's bare "is not included
in the list" or "cannot be blank". A field the caller may not set is refused by name when the
caller may read it on that record, and by id otherwise, so a refusal names no field that is excluded,
of another type, or hidden from the caller's roles. For a format
with a list of values (list, key/value list, user, version, bool), a value is the stored one (the
option, the id, `1` or `0`); a label that names exactly one value is accepted in its place, case
aside, as are `"me"` for a user field and `true`/`false` for a bool, and the value already stored
stays accepted, as core keeps it. Anything else is refused with the field's name, its id and up to
25 accepted values with their labels. A required field left blank is refused the same way, with its
choices, exactly when core would refuse it: on a new issue or time entry every required field is
checked, as core validates them all; on an update, a field a workflow rule requires is checked at
every save, with the rules of the status being set rather than the stored one, and a field required
by its own flag once a custom field is sent or the tracker changes, since core rechecks the flag
only then. An update that changes none of that saves as core does, blank field included. Required
means the field's own flag or, on an issue, a workflow rule for this user on this tracker and
status. The choices come from the same core call as `get_issue_fields` and `list_enumerations`
report, so the refusal and the listing never disagree.

`create_issue` and `update_issue` take every field of core's issue form: the standard attributes,
custom fields, watchers, and with the plugins below tags; checklist items only through
`update_issue_checklists`. Each parameter maps to one
core attribute through one table in `lib/redmine_mcp_plugin/tool.rb`, and `get_issue_fields` reports
that table filtered by core's `safe_attribute?`, so what it lists is what a write accepts. The core
safe attributes left out, each for a reason: `project_id` (moving an issue is another act),
`notes` and `private_notes` (the note tools), `custom_fields` (the array form of
`custom_field_values`), `lock_version` (a form concern), `deleted_attachment_ids` (nothing here
deletes). On `update_issue` a new `tracker` is applied before anything else, as core's form does, so
the status and the custom fields are checked against the new tracker; the journal is opened before
that, as core's update does, so the tracker change is journaled. `done_ratio` is refused when Redmine
computes it from the status. Watchers are added and removed explicitly; nothing replaces the list.
Every write reply is read back from the database after the save and the plugins' hooks, so it never
claims a value that is not stored.

Attachments: `get_issue` lists them, `get_attachment` reads a text file within
`file_max_size_displayed` and reports a binary or larger file as omitted, and `add_issue_attachment`
adds a text file through core's token path, so `attachment_max_size` and the extension lists apply.
It saves the attachment with a journal, and Redmine mails the watchers when `issue_updated` or
`issue_attachment_added` is a notified event. Binary attachments, and deleting anything, are out of
scope.

Relations: `get_issue` lists them as the issue page does, seen from the issue (`blocks` on one side is
`blocked` on the other), only those whose other issue the caller can see, with `delay` only on
`precedes` and `follows`. `update_issue_relations` removes, then adds, in one transaction, each entry
through core's own path and validations and against what the entries before it leave; any refusal
rolls everything back and names every entry with core's message in the caller's language. A `delay`
on another type is refused, where core would drop it, and a duplicate only the unique index catches
reads "has already been taken", as in core's form. `remove` takes the other issue and removes every
relation with it: core allows one relation each way, so a pair can hold two. Each change is journaled
once on both issues, and a `precedes` reschedules the following issue, as in core. `create_issue` and
`update_issue` take no relations, for the reason they take no checklist items. The relation filters
of `search_issues` are core's: issue ids for `=` and `!`, a project for `=p`, `=!p` and `!p`. Core
reads one value for `=` and `!`, so a list of ids is joined into it rather than cut to its first.

Plugins: checklists (redmine_checklists) and tags (redmineup_tags) exist for the agent only while the
plugin is installed. `Redmine::Plugin.installed?` is read per request, not at boot, because plugins
load alphabetically and this one boots before redmineup_tags. Without the plugin the
`update_issue_checklists` tool, the `tag_list`, `add_tag_list` and `remove_tag_list`
parameters and the five plugin scopes are absent from the served list and the advertised scopes.
`create_issue` takes no checklist items and refuses a `checklists` argument as unknown: offered one,
the agent turned a description's bullets into items on every issue it created. Items are added with
`update_issue_checklists`, which the agent is told to use only when the user asks.
With its own `issue_done_ratio` setting on, redmine_checklists recomputes `done_ratio` from the items
with a journal-less update on every edit and tick, once the issue has items; `done_ratio` is refused
then, and `get_issue_fields` reports it as
`done_ratio_computed_from`. Closing an issue with open items under `block_issue_closing` fails the
plugin's own validation, which the tool reports. `update_issue_checklists` sends each item's subject
with a tick, since the plugin's nested attributes drop an item hash without one, and reads the items
back inside its transaction: a change that did not take rolls everything back and is named.
Both plugins journal through controller hooks. The tools call the two listeners directly with the
keys each reads: the tags listener gets the issue and its real tag list, which it checks for
presence; the checklists listener gets the issue and its journal. `Redmine::Hook.call_hook` is not
used, since it would wake every listener on those hooks with a params object that is not a
request's. The tags filter `issue_tags` registers no operators, so `search_issues` offers it the
`list_optional` set, which is what the plugin's statement handles.

### Text formatting

No markup is hard-coded. When `tools/list` is served the plugin reads `Setting.text_formatting` and
appends "Rendered as Textile." (or CommonMark Markdown, or plain text) to every parameter Redmine
passes through its text formatter: issue `description` and `notes`, news `description`. Parameters
Redmine prints as they are say "Plain text.": issue `subject`, news `title` and `summary`, time entry
`comments`. `get_issue_fields` flags each custom field `rendered` when its text formatting is on. Both
suffixes end with the company dash rule, a plain "-" only, and the rendered one says a spaced hyphen is
safe, so the agent does not reach for an em dash to avoid Textile strikethrough. The `initialize`
instructions also carry a syntax guide for the format in force, but claude.ai does not pass server
instructions to the model (verified live: a fresh chat reports none), so on claude.ai the parameter
descriptions are all the agent reads. The guide stays for clients that do pass them.

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
end in 405 - but **only for a request that has already authenticated**. Authentication is a
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

## Extensions

Another Redmine plugin can add tools to `/mcp`. They are served with this plugin's own: the same URL,
OAuth application and claude.ai connector, listed per user in the same way, and their permissions join
the advertised scopes. Nothing about that plugin's domain lives here. The plugin adds its tools from its
`init.rb`:

```ruby
# Without redmine_mcp_plugin, or with one older than add_tools, the tools are neither loaded nor served.
mcp = defined?(RedmineMcpPlugin::Endpoint) && RedmineMcpPlugin::Endpoint.respond_to?(:add_tools)
unless mcp
  Rails.autoloaders.main.ignore(File.join(__dir__, 'lib', 'redmine_mcp_plugin_invoices'))
  Rails.logger.error('[redmine_mcp_plugin_invoices] not served: redmine_mcp_plugin is absent or too old')
end

Redmine::Plugin.register :redmine_mcp_plugin_invoices do
  # ...
end

if mcp
  RedmineMcpPlugin::Endpoint.add_tools(:redmine_mcp_plugin_invoices) do
    next [] unless Redmine::Plugin.installed?(:redmine_contacts_invoices)

    [RedmineMcpPluginInvoices::Tools::ListInvoices, RedmineMcpPluginInvoices::Tools::GetInvoice]
  end
end
```

The first argument names the extension in log lines. The block returns its tools, each a
`RedmineMcpPlugin::Tool` subclass; an empty list adds nothing. It is called once, after every plugin has
loaded, so plugins may load in any order and the classes and permissions it names exist by then. The
tools follow this plugin's in `tools/list`. Each tool's `permission` and `scopes` are the extension's
OAuth scopes, advertised as this plugin's are; there is no separate list.

An extension never stops Redmine or `/mcp`. Each of these is logged at boot, and that extension's tools
are left out while `/mcp` serves everything else:

- the block is missing, raises (a misspelt class, say), or returns anything but a list of `Tool`
  subclasses;
- a tool name that this plugin or an earlier extension already serves, or that the list repeats;
- a `permission` or `scopes` entry that is not a Redmine permission, for a tool whose plugin is installed.

For example: `[redmine_mcp_plugin] redmine_mcp_plugin_invoices adds no tools to /mcp: ArgumentError: tool
name list_users is taken`. Extensions are added in the order Redmine loads plugins, which is
alphabetical, so the first to take a name keeps it. A syntax error in an extension's `lib/` still stops
Redmine, as in any plugin, because Redmine eager-loads every plugin's `lib/`.

An extension's tools share everything else with this plugin's:

- **Settings.** The enabled switch, the authentication modes, the REST API gate, read-only mode, the
  allowed origins, `max_results` and the excluded custom fields. A tool honours the last through the
  `shown_custom_fields` and `shown_custom_field_values` helpers and the `QueryTool` filters.
- **Request handling.** Authentication, the Origin and protocol-version checks, the JSON-RPC handling and
  the status codes.
- **Tool behaviour.** The `Tool` base: the permission check through `User#allowed_to?`, the read-only
  refusal, schema validation and coercion, the helpers, and the wording of every refusal.
- **Text.** The formatting guide and the parameter suffixes. User ids, project ids and the custom fields
  that render point to `list_users`, `list_projects` and `get_issue_fields`.
- **Discovery.** Doorkeeper, both discovery documents and the icon.

Every extension tool should declare a permission: a tool without one is listed to every user of `/mcp`.

What an administrator does:

1. **Install and restart,** as in Deployment.
2. **Enable the new scopes** on the existing MCP application: the ones
   `/.well-known/oauth-protected-resource` now lists. Until then a new connection fails with
   `invalid_scope`, because the client requests exactly that list. When the permissions come from a
   plugin that is already installed, they can be enabled before the restart.
3. **Grant the permissions** to the roles of the people who should use the tools.
4. **Reconnect.** A token keeps the scopes it was issued with, so each user reconnects the connector to
   see the new tools.

The URL, the connector and the firewall rule stay as they are.

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

This project began as [joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin),
continued as [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin), and
is maintained here; the original copyright notices are preserved as the licence requires.
