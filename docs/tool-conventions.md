# Tool conventions

What the tools listed in [tools.md](tools.md) have in common: how parameters are named, what a write refuses, and how each family behaves.

## Parameters

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

Arguments are checked against each tool's declared schema. A value outside a declared `enum`, below a
declared `minimum`, of the wrong type, or missing when required is refused rather than ignored. An
array must be an array, each of its items of the type the schema gives, and an object an object: a
single value where a list is declared is refused, not wrapped.

A result is returned twice, as `structuredContent` and as the same JSON in a text block, compact,
for clients that read only text.

The list tools take `limit` and `offset` and return `total_count`, `returned`, `offset` and `has_more`.
`limit` is capped by the `max_results` setting, 100 by default, so page with `offset`.

## Reading

`get_issue` respects per-field custom field visibility and filters private notes by role and token scope, as
[permissions.md](permissions.md#private-notes) describes.
Its history reads as the issue page's: a custom field by its name, a reference without `_id` (`status`,
`assigned_to`, `parent`, `child`), a checklist change as the items added, removed, done, undone and
renamed, shown only under `view_checklists` as the plugin's own history does, and no journal with
neither notes nor a detail the caller may see.

Every custom field row gives its `format` and its stored `value`, which is what the write tools take;
an `enumeration`, `user` or `version` field also names that id in `label`, `null` for a user outside
`Principal.visible`, a version whose issues the caller may not see, or a target deleted since.

`list_users` uses `Principal.visible` rather than `User.all`, which honours each role's
`users_visibility` setting.

`search` runs core's own fetcher. Core keeps, for one project, the types the user may view there; its
queries then go through `.visible` scopes, which read roles and not a token's scopes, so the tool
also leaves out every type whose `view_` scope the token lacks. `searched_types` says what was
searched. An excerpt is cut at 500 characters.

## Writes refuse rather than guess

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

The project structure tools refuse what core would drop in silence, naming the parameter: a field
the role or the token may not set, a parent the caller may not extend, a `sharing` outside
`allowed_sharings`, a role outside the caller's managed roles, an unknown module or tracker. A write
on a closed project says the project is closed, where core's permission check only says no. Archiving a project needs
an administrator; see [TODO.md](../TODO.md).

## Custom field values

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

## Issue fields

`create_issue` and `update_issue` take every field of core's issue form: the standard attributes,
custom fields, watchers, and with the plugins below tags; checklist items only through
`update_issue_checklists`. Each parameter maps to one
core attribute through one table in `lib/redmine_mcp_plugin/tool.rb`, and `get_issue_fields` reports
that table filtered by core's `safe_attribute?`, so what it lists is what a write accepts. The core
safe attributes left out, each for a reason: `project_id` (moving an issue is another act),
`notes` and `private_notes` (the note tools), `custom_fields` (the array form of
`custom_field_values`), `lock_version` (a form concern), `deleted_attachment_ids` (the
`delete_attachment` tool). On `update_issue` a new `tracker` is applied before anything else, as core's form does, so
the status and the custom fields are checked against the new tracker; the journal is opened before
that, as core's update does, so the tracker change is journaled. `done_ratio` is refused when Redmine
computes it from the status. Watchers are added and removed explicitly; nothing replaces the list.
Every write reply is read back from the database after the save and the plugins' hooks, so it never
claims a value that is not stored.

## Deleting

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

## Attachments

Attachments: `get_issue` lists them, `get_attachment` reads a text file within
`file_max_size_displayed` and reports a binary or larger file as omitted, and `add_issue_attachment`
adds a text file through core's token path, so `attachment_max_size` and the extension lists apply.
It saves the attachment with a journal, and Redmine mails the watchers when `issue_updated` or
`issue_attachment_added` is a notified event. `delete_attachment` removes one, under its container's rule. Binary attachments are out of scope;
see [TODO.md](../TODO.md).

## Relations

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

## Checklists and tags

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

## Text formatting

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
