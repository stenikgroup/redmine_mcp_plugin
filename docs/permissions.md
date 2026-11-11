# Permission model

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

## Tracker-level permissions

Redmine grants five issue permissions **per tracker**, not per project: `view_issues`, `add_issues`,
`edit_issues`, `add_issue_notes` and `delete_issues`. `User#allowed_to?` does not know about
trackers, so a project-level check alone would let a role granted a permission on one tracker act on
every tracker in the project.

The plugin exercises all five:

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
- `delete_issues` - `delete_issue` checks `Issue#deletable?`, which applies the permission per
  tracker, on top of the scope-aware `allowed_to?`.

## Private notes

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

## Notes and time of other users

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
