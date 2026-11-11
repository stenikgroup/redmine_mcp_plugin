# Changelog

All notable changes to this fork. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version is `RedmineMcpPlugin::VERSION`: Redmine's
plugin list shows it, and MCP clients read it as `serverInfo.version`.

## [Unreleased]

### Added

- Nine tools for the structure of a project, each mapped to a Redmine permission, which is also its
  OAuth scope, and to a REST API action of Redmine 7.0: `create_project`, `update_project`,
  `close_project`, `reopen_project`, `create_version`, `update_version`, `create_issue_category`,
  `update_issue_category` and `update_membership`, plus `list_memberships` to read the members.
  They refuse, naming the parameter, what core drops in silence: a field the role or the token may
  not set, a parent the caller may not extend, a version `sharing` outside `allowed_sharings`, a role
  outside the caller's managed roles. **Upgrade step:** with writes on, the
  server now advertises `add_project`, `add_subprojects`, `edit_project`, `close_project`,
  `select_project_publicity`, `select_project_modules`, `manage_members`, `manage_versions` and
  `manage_categories`, and `view_members` in read-only mode too; enable them on the MCP application
  in Administration → Applications, or the next consent fails with `invalid_scope`.
- `update_time_entry` corrects a time entry, or moves it to another issue or project: the caller's
  own under `edit_own_time_entries`, anyone's under `edit_time_entries`.
- `copy_issue` copies an issue, in its project or to another, with core's options (attachments,
  subtasks, the "copied to" relation) and the field overrides of `create_issue`.
- `log_time` and `update_time_entry` take `user`, to log time for someone else under
  `log_time_for_other_users`. `log_time` replies with the entry's `user`.
- `update_wiki_page` creates or rewrites a wiki page under `edit_wiki_pages`, with core's optimistic
  lock on `version`. `list_wiki_page_versions` lists a page's history and `get_wiki_page` takes
  `version`, both under `view_wiki_edits`; `get_wiki_page` also returns `current_version`, `author`,
  `comments`, `parent_title` and `url`.
- `list_files` and `add_file` read and feed the Files module, under `view_files` and `manage_files`.
- `search` is Redmine's search box across issues, news, documents, changesets, wiki pages, forum
  messages and projects, under `search_project` and each type's own `view_` permission.
  **Upgrade step:** the server also advertises, read-only mode included, `search_project`,
  `view_wiki_edits`, `view_files`, `view_documents`, `view_changesets` and `view_messages`, and with
  writes on `edit_wiki_pages`, `rename_wiki_pages`, `protect_wiki_pages` and `manage_files`; enable
  them on the MCP application.
- Nine tools delete: `delete_issue`, `delete_time_entry`, `delete_news`, `delete_wiki_page`,
  `delete_attachment`, `delete_version`, `delete_issue_category`, `delete_membership` and
  `delete_project`. No plugin setting gates them: each needs the permission Redmine has for that
  deletion, and a token without the scope does not list the tool. `delete_issue` and
  `delete_wiki_page` ask what becomes of logged time and of child pages, as core's forms do, where
  its API decides silently. **Upgrade step:** with writes on, the server also advertises
  `delete_issues`, `delete_project`, `delete_wiki_pages` and `delete_wiki_pages_attachments`; tick
  them on the MCP application only if agents may delete. `manage_versions`, `manage_categories`,
  `manage_members`, `manage_news` and the `edit_time_entries` pair now also delete.
- `get_project` returns `inherit_members`.
- `TODO.md` lists the tools held back: those with no REST API action yet, those that need the
  `admin` scope, and what is not planned.
- The test suite runs in CI, on GitHub Actions: Redmine 6.1.0, `6.1-stable`, `7.0-stable` and trunk,
  on each Ruby they accept, from 3.2 to 4.0, on every pull request and once a week.
  `test/docker/Dockerfile` builds one cell of that matrix to run it locally.

### Changed

- `update_issue_note` edits another user's note when the role holds `edit_issue_notes`, as Redmine
  does. It was refused whatever the role, as a product rule, which is lifted. A token is kept to its
  owner's notes by leaving `edit_issue_notes` out of its scopes. The reply names the note's `author`.
  **Upgrade step:** with writes on, the server also advertises `edit_issue_notes`,
  `edit_time_entries`, `edit_own_time_entries`, `log_time_for_other_users` and `copy_issues`; enable
  them on the MCP application.

## [0.3.0] - 2026-11-06

### Added

- `get_project` returns the project's `custom_fields`, in the `{ id, name, value }` shape of
  `get_issue` and of core's `/projects/:id.json`. A field restricted to roles the caller does not
  hold on that project is left out, as on the project page.
- `list_projects` takes `include_custom_fields` (default `false`) to add the same `custom_fields` to
  every row, so one field can be read across all projects in a few paged calls. The query count
  does not grow with the page size. Without the flag the rows are unchanged.
- Every custom field row (`get_issue`, `get_project`, `list_projects`, `list_time_entries`, and the
  `custom_fields` read back by `create_issue`, `update_issue` and `log_time`) gives its `format`, and
  a field stored as an id (`enumeration`, `user`, `version`) names it in `label`, an array for a
  multiple field. `value` is unchanged and is still what the write tools take. A user outside
  `Principal.visible`, a version whose issues the caller may not see, or a target deleted since has
  a `null` label. The labels cost one query per format, whatever the page size (#9).
- A plugin setting lists the custom fields to hide from every MCP client, checked by type on the
  settings page. An excluded field is left out of every reply and of the issue history, refused as a
  value to set, and unknown as a filter, sort or grouping, including in a saved query's own sort and
  grouping. A free-text `search` still matches a searchable field.

### Changed

- A 401 from `/mcp` for an expired, revoked, unknown or orphaned OAuth2 token now carries
  `error="invalid_token"` and an `error_description` in its `WWW-Authenticate` challenge, as RFC 6750
  3.1 requires, so a client can tell a token to refresh from a missing one. A request with no token
  is answered as before.
- Each refused OAuth2 token is logged at `warn` with its reason, id, user, application, creation
  time, lifetime and revocation time. Users reported having to reconnect their MCP connector, and
  nothing in a production log at `warn` showed why.

### Changed

- Redmine's plugin list names Amaury Balmer as the plugin's author, linking to this fork's owner.
  The README keeps the credits for João Figueira and Stenik.

### Security

Four vulnerabilities, all rated low, found by a security audit of `3af02e6`. The first two and part
of the fourth are still in the upstream projects; the README's security notice says which.

- A write tool on an issue or a news item now refuses a token that may not view it. An OAuth token
  scoped to `edit_issues` or `add_issue_notes` without `view_issues` could update an issue, watch
  it, add a note or an attachment, and read the issue back in the reply, where core's REST API
  answers 403. `update_news` likewise needs `view_news`, which is stricter than core.
- `get_issue` no longer returns another user's private notes to an OAuth token without
  `view_private_notes`, whatever the user's role grants, as core's issue page and REST API.
  `view_private_notes` is now advertised as a scope, read-only mode included. **Upgrade step:**
  enable "View private notes" on the MCP application in Administration → Applications, or the next
  consent fails with `invalid_scope`.
- An excluded custom field could still be filtered on through a chained key on a version or user
  field (`cf_N.status`, `cf_N.due_date`, `cf_N.cf_M`), in `search_issues` and `list_time_entries`.
  Every field in a key is now checked.
- A refused custom field value named the field even when the caller may not read it: an excluded
  field, a field of another type, or one restricted to other roles. Such a field is now named by id
  only.

## [0.2.1] - 2026-10-27

### Fixed

- Clicking Authorize on the OAuth2 consent screen with sudo mode on returned a 500
  (`No route matches {:action=>"create", :controller=>"authorizations"}`), so nobody whose sudo
  mode had expired could connect an MCP client. The Doorkeeper URL fix stripped `doorkeeper/` from
  the recalled controller, which broke the sudo password form's `form_tag({})`. It now makes
  relative controllers absolute instead, and leaves the recall alone.

## [0.2.0] - 2026-10-27

First version of the herewithme fork. Checked on Redmine 6.1.2 (Rails 7.2.3) and Redmine 7.0.2
(Rails 8.1.4), on Ruby 3.3: the test suite and every tool, live.

### Added

- `list_enumerations` with a project lists the custom fields a time entry takes there, with their
  required flag and allowed values, for a caller who may log time on that project.
- `create_issue`, `update_issue` and `log_time` check custom field values before the save. A value
  outside the list, or a required field left blank, is refused with the field's name, its id and up
  to 25 accepted values, instead of core's bare "is not included in the list" or "cannot be blank".
  The check runs where core's does: a field a workflow requires at the status being set, and every
  required field on a tracker move, are named even when the update sends no custom field.
- A label naming exactly one value is accepted in place of the stored value, as are `"me"` for a
  user field and `true`/`false` for a bool field.
- The server instructions point the agent at `get_issue_fields` and `list_enumerations` before a
  write.

### Fixed

- Redmine 7.0 removed `Issue#addable_watcher_users`, so `get_issue_fields` and watcher updates
  raised `NoMethodError`. The plugin rebuilds that list from core scopes present on 6.1 and 7.0.
- A malformed JSON body is answered with the JSON-RPC parse error instead of Rails' own 400, on
  both Redmine 6.1 and 7.0.
- The test suite runs again: a `headers` keyword `ActionController::TestCase` never accepted, a
  test of a removed `negotiate` API, an outdated `get_issue` argument and an expected status
  checked before authentication.

### Changed

- The README describes the fork lineage. The clone URL, the plugin URL and the
  `resource_documentation` of `/.well-known/oauth-protected-resource` point to this repository.
- The README's target platform becomes a compatibility table: the versions checked for this
  release, and the platform the fork runs on in production.

## [0.1.0]

The version declared by
[joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin) and kept,
unchanged, by [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin)
through all of its work. This fork starts from stenikgroup's last commit, `19ce030`.

[Unreleased]: https://github.com/herewithme/redmine_mcp_plugin/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/herewithme/redmine_mcp_plugin/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/herewithme/redmine_mcp_plugin/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/herewithme/redmine_mcp_plugin/compare/19ce030...v0.2.0
[0.1.0]: https://github.com/stenikgroup/redmine_mcp_plugin/tree/19ce030
