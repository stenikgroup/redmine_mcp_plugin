# Installation and settings

For the administrator who installs the plugin. The OAuth application is covered in [scopes.md](scopes.md), the authentication modes in [authentication.md](authentication.md).

## Compatibility

The test suite runs in CI on each Ruby that each Redmine accepts in its `Gemfile`, on every pull
request and once a week:

| Redmine | Rails | Ruby |
|---|---|---|
| 6.1.0 and `6.1-stable` | 7.2 | 3.2, 3.3, 3.4 |
| `7.0-stable` | 8.1 | 3.2, 3.3, 3.4, 4.0 |
| trunk | 8.1 | 3.3, 3.4, 4.0 |

Rails is the version each Redmine pins in its `Gemfile`. `init.rb` declares a floor of Redmine
6.1.0, which is where OAuth2 (Doorkeeper) support lands. Redmine 7.0 removed
`Issue#addable_watcher_users`; the plugin rebuilds that list itself from core scopes that exist on
both versions. The exact matrix, and how to run one cell of it locally, is in
[internals.md](internals.md#running-the-tests).

Beyond the suite, every tool was exercised live with version 0.2.0 on 2026-10-27, over an API key
and over a scoped OAuth2 token, on Redmine 6.1.2 and 7.0.2 with Ruby 3.3.

Be API runs this fork in production on Redmine trunk, with Rails 8.1.4 and Ruby 3.2.3. A core
removal reaches trunk before any release, which is why trunk is part of the weekly run.

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
on. Recommended configuration:

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
enabling that mode discards the one restriction the token is there for. HTTP Basic has the same
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
