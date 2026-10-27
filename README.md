# redmine_mcp_plugin

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs inside Redmine as a
plugin. It adds one endpoint, `POST /mcp`, and authenticates it with Redmine's own mechanisms. Every
tool runs as a real Redmine user and is limited by that user's permissions.

Version 0.2.0. Read-only by default. See [CHANGELOG.md](CHANGELOG.md).

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
   working test suite, and custom field values checked before a write. See the changelog.

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
| `view_wiki_pages` | View wiki | Wiki |
| `view_time_entries` | View spent time | Time tracking |
| `view_news` | View news | News |
| `view_checklists` | View checklist | Issue tracking, with redmine_checklists installed |
| `add_issues` | Add issues | Issue tracking |
| `edit_issues` | Edit issues | Issue tracking |
| `edit_own_issues` | Edit own issues | Issue tracking |
| `add_issue_notes` | Add notes | Issue tracking - **not** the "Add notes" under Contacts |
| `log_time` | Log spent time | Time tracking - **not** "Log spent time for other users" |
| `set_notes_private` | Set notes as private | Issue tracking |
| `edit_own_issue_notes` | Edit own notes | Issue tracking |
| `manage_subtasks` | Manage subtasks | Issue tracking |
| `add_issue_watchers` | Add watchers | Issue tracking |
| `delete_issue_watchers` | Delete watchers | Issue tracking |
| `set_issues_private` | Set issues public or private | Issue tracking |
| `set_own_issues_private` | Set own issues public or private | Issue tracking |
| `manage_issue_relations` | Manage issue relations | Issue tracking |
| `manage_news` | Manage news | News |
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
`is_private`, `view_issue_watchers` and `view_checklists` for what `get_issue` includes, `edit_tags`
and `create_tags` for tags. A permission a tool checks at runtime must be advertised, or no token can
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
Read-only gives `view_project`, `view_issues`, `view_issue_watchers`, `view_wiki_pages`,
`view_time_entries` and `view_news`; with writes on, add `add_issues`, `add_issue_notes`,
`edit_issues`, `edit_own_issues`, `edit_own_issue_notes`, `log_time`, `set_notes_private`,
`manage_subtasks`, `add_issue_watchers`, `delete_issue_watchers`, `set_issues_private`,
`set_own_issues_private`, `manage_issue_relations` and `manage_news`. With redmine_checklists installed, `view_checklists`
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
argument** - so they honour roles but are blind to OAuth scopes. A token scoped to `view_wiki_pages`
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

Notes marked private are filtered by `Journal.visible`, which is core's own rule: a journal is
visible if it is not private, or the caller wrote it, or the caller's role holds
`view_private_notes`.

That filter is built on `Project.allowed_to_condition` and is therefore **not narrowed further by
OAuth scope**. A token whose scopes omit `view_private_notes` will still see private notes if the
user's role grants it. This is deliberate on our side: roles are the access boundary we rely on, and
token scopes are a second, coarser restriction on top of them - not the thing that decides who may
read what.

Writing one is the other way round: `add_issue_note` and `update_issue_note` with `private_notes: true`
check `set_notes_private` through the scope-aware `allowed_to?`, which is why that permission is
advertised as a scope once writes are on.

### Own notes only

One deliberate exception to "roles are the boundary": `update_issue_note` edits only notes the caller
wrote, even when their role holds `edit_issue_notes`, which in Redmine also allows editing other
people's notes. This is a product requirement, and the refusal names it ("You can only edit your own
notes") rather than using the permission wording, because the cause is our rule, not a Redmine
permission. Everything else is core's: the journal is found through `Journal.visible`, the right
through `Journal#editable_by?`, and a note saved blank is refused because Redmine would delete it.
The tool is gated on `edit_own_issue_notes` and only that scope is advertised, so Redmine itself
refuses other people's notes and our check is a second guard. A role with "Edit notes" but without
"Edit own notes" will not see the tool; the remedy is to tick "Edit own notes" on that role.

## Tools

Read-only unless marked write. Write tools are hidden from `tools/list` and refused by `tools/call`
while read-only mode is on, which is the default.

| Tool | Permission |
|---|---|
| `whoami` | none. Reports identity, auth mode and granted scopes |
| `list_projects`, `get_project` | `view_project` |
| `search_issues`, `get_issue` | `view_issues`. `get_issue` adds the attachments, the subtasks the caller can see, the relations whose other issue the caller can see, the watchers under `view_issue_watchers`, the checklist under `view_checklists`, and the tags |
| `get_attachment` | `view_issues`, through core's `Attachment#visible?`. Metadata, and the content of a text file within `file_max_size_displayed` |
| `list_queries` | `view_issues`. Saved queries, filtered by `IssueQuery.visible` |
| `list_wiki_pages`, `get_wiki_page` | `view_wiki_pages` |
| `list_news`, `get_news` | `view_news`. Filtered by `News.visible`; with a project, that project's own news, as core's index |
| `list_enumerations` | none. Trackers, statuses, priorities, time entry activities; with `project`, that project's activities and, for a caller with `log_time` there, the time entry custom fields with their required flag and allowed values |
| `list_users` | none. Filtered by `Principal.visible` |
| `list_time_entries` | `view_time_entries`. Totals, per-group hours and each entry's custom fields, filtered by `TimeEntry.visible` |
| `get_issue_fields` | `view_issues`. What the caller may set on an issue, before a write; with `issue` and `tracker`, what it would be under that tracker, refused as `update_issue` refuses the move |
| `create_issue` (write) | `add_issues`, on the requested tracker, plus `manage_subtasks` for `parent`, `add_issue_watchers` for `watcher_users`, `set_issues_private` or `set_own_issues_private` for `is_private`, `edit_tags` for `tag_list` and `create_tags` for a tag that does not exist yet |
| `update_issue` (write) | `edit_issues`, or `edit_own_issues` on one's own issue, on the issue's tracker, plus the per-field permissions of `create_issue` and `delete_issue_watchers` for `remove_watcher_users`. Watching or unwatching oneself needs none, as core's Watch link |
| `add_issue_note` (write) | `add_issue_notes`, on the issue's tracker, plus `set_notes_private` for private notes |
| `update_issue_note` (write) | `edit_own_issue_notes`; only notes the caller wrote, plus `set_notes_private` to change privacy |
| `add_issue_attachment` (write) | `edit_issues`, `edit_own_issues` or `add_issue_notes`, as core's `attachments_addable?`. A text file within `attachment_max_size` and the extension lists; saved with a journal, so watchers are mailed as for an issue update |
| `update_issue_checklists` (write) | `edit_checklists` to add or rename, `done_checklists` or `edit_checklists` to tick or untick. Present only with redmine_checklists |
| `update_issue_relations` (write) | `manage_issue_relations` on the issue's project, as core's relation form. Every relation type core has |
| `log_time` (write) | `log_time`. Always for the authenticated user |
| `create_news` (write) | `manage_news`. Publishes at once and, when `news_added` is a notified event, emails project members and news watchers; the tool tells the agent to get explicit confirmation first |
| `update_news` (write) | `manage_news`. Editing sends no email |

`get_issue` respects per-field custom field visibility and filters private notes by role, as above.
Its history reads as the issue page's: a custom field by its name, a reference without `_id` (`status`,
`assigned_to`, `parent`, `child`), a checklist change as the items added, removed, done, undone and
renamed, shown only under `view_checklists` as the plugin's own history does, and no journal with
neither notes nor a detail the caller may see.
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
in the list" or "cannot be blank". A field the caller may not set is refused by name. For a format
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
  allowed origins and `max_results`.
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
