# Third-party plugins

Three Redmine plugins add something to the tools when they are installed. None is required: without
one, its tool, its parameters and its scopes are absent from what the server serves and advertises.

| Plugin | Adds | How far it is tested |
|---|---|---|
| [redmine_checklists](https://www.redmineup.com/pages/plugins/checklists) (RedmineUP) | The `update_issue_checklists` tool, the checklist in `get_issue`, the checklist rights and the done-ratio rule in `get_issue_fields` | **Against the plugin**, light edition 4.1.0, on Redmine 7.0. The Pro edition: not tested here |
| [additional_tags](https://github.com/alphanodes/additional_tags) (AlphaNodes) | `tag_list` in `create_issue`, `add_tag_list` and `remove_tag_list` in `update_issue`, the tags in `get_issue` and `get_issue_fields` | **Against the plugin**, its `main` branch as of 2026-11-11, with `additionals`, on Redmine 7.0.3 and PostgreSQL, and in CI on every pull request |
| redmineup_tags (RedmineUP) | The same tag parameters and fields as additional_tags | **Over a stand-in only.** The plugin itself has never run in this repository's tests |

With both tags plugins installed, redmineup_tags is the one the tools talk to.

## What "tested" means here

Each row above is one of three levels, and they are not equivalent.

- **Against the plugin.** The integration tests ran with the real plugin installed in the Redmine
  under test: its models, its permissions, its validations and its journaling. This is the only level
  that says the tools work with the plugin.
- **Over a stand-in.** The tests run over
  [`test/support/plugin_stand_ins.rb`](../test/support/plugin_stand_ins.rb), the smallest thing that
  answers the names the tools call. It proves the tools' own logic: the permissions they check, the
  refusals they word, the replies they build. It says nothing about the plugin, and for
  redmineup_tags it was written from what the tools call, without the plugin's source.
- **Not tested.** An edition or a version nobody ran. The contract check below is all that covers it.

The whole suite runs over the stand-ins on every Redmine and Ruby of the CI matrix, which is where
the coverage figure comes from. The `Third-party plugins` job then runs the integration tests over
the real additional_tags. redmine_checklists has no public source to fetch, so it is checked by
hand: install it in the Redmine under test and the same tests use it instead of its stand-in.

## What each plugin needs

**redmine_checklists.** Its three permissions: `view_checklists` to read, `done_checklists` to tick,
`edit_checklists` to add and rename.

- The light edition keeps no history of a checklist: a change made through `update_issue_checklists`
  is stored, and nothing is added to the issue's journal. The edition that journals shows the change
  in `get_issue`.
- With the plugin's `issue_done_ratio` setting on, `done_ratio` belongs to the checklist as soon as
  the issue has an item, and the tools refuse to set it.

**additional_tags.** The `additionals` plugin, Redmine 7.0.3 or later, PostgreSQL or MySQL, and its
three permissions: `view_issue_tags` to read, `edit_issue_tags` to set, `create_issue_tags` for a tag
that does not exist yet.

- Issue tags are behind the plugin's `active_issue_tags` setting, which is off by default. While it
  is off a tag is refused by name and no tag is returned.

**redmineup_tags.** Its two permissions, `edit_tags` and `create_tags`. It has none to read tags.

The scopes each one adds to the OAuth application are in [scopes.md](scopes.md).

## When a plugin changes

None of these plugins publishes an API for what the tools do, so the server lists every name it
calls, per plugin, in [`integrations.rb`](../lib/redmine_mcp_plugin/integrations.rb). A plugin is
served when it is installed and all of them are there. After an upgrade that removed one, the plugin
is treated as absent, nothing fails, and the log says once at boot:

```
[redmine_mcp_plugin] redmine_checklists 4.1.0 is installed but not usable: it has no JournalChecklistHistory. Its tool, parameters and fields are not served.
```

That check sees a name that went away. It does not see one that kept its name and changed its
meaning: only a test against the plugin does.

## Checking a plugin yourself

Put the plugin in the `plugins/` directory of the Redmine under test, next to this one, install its
gems and migrate, then run the integration tests:

```bash
bin/rails test plugins/redmine_mcp_plugin/test/functional/mcp_plugin_integrations_test.rb plugins/redmine_mcp_plugin/test/unit/integrations_test.rb
```

The stand-in of redmine_checklists or additional_tags steps aside when the real one is installed,
and the tests of the other tags plugin are skipped. How the tools reach into the plugins is in
[internals.md](internals.md#reaching-into-redmine_checklists-and-redmineup_tags).
