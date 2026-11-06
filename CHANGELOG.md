# Changelog

All notable changes to this fork. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version is `RedmineMcpPlugin::VERSION`: Redmine's
plugin list shows it, and MCP clients read it as `serverInfo.version`.

## [Unreleased]

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
  release, and the platform Be API runs in production.

## [0.1.0]

The version declared by
[joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin) and kept,
unchanged, by [stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin)
through all of its work. This fork starts from stenikgroup's last commit, `19ce030`.

[0.2.1]: https://github.com/herewithme/redmine_mcp_plugin/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/herewithme/redmine_mcp_plugin/compare/19ce030...v0.2.0
[0.1.0]: https://github.com/stenikgroup/redmine_mcp_plugin/tree/19ce030
