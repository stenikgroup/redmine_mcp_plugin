# Tools

Read-only unless marked write. Write tools are hidden from `tools/list` and refused by `tools/call`
while read-only mode is on, which is the default.

Parameters, refusals and the behaviour shared across tools are in [tool-conventions.md](tool-conventions.md); the OAuth scope behind each permission is in [scopes.md](scopes.md).

## Projects, versions, categories and members

| Tool | Permission |
|---|---|
| `list_projects`, `get_project` | `view_project`. Project custom fields follow core's per-role visibility: always on `get_project`, on `list_projects` with `include_custom_fields` |
| `list_memberships` | `view_members`. Users and groups with their roles, inherited ones marked, as core's `/projects/:id/memberships.json`; with `manage_members`, the roles the caller may give |
| `create_project` (write) | `add_project` for a root project, `add_subprojects` on the parent for a subproject, plus `select_project_publicity` for `is_public`, `select_project_modules` for `enabled_modules` and `manage_members` for `inherit_members`. A non-administrator becomes a member with the default role, as in core |
| `update_project` (write) | `edit_project`, plus the per-field permissions of `create_project`, and `add_subprojects` or `add_project` to move it. The identifier cannot be changed |
| `close_project`, `reopen_project` (write) | `close_project`. Subprojects follow, as in core |
| `create_version`, `update_version` (write) | `manage_versions`. `sharing` within core's `allowed_sharings`. The saved version is read back only under `view_issues`; without it the write is acknowledged by id |
| `create_issue_category`, `update_issue_category` (write) | `manage_categories`, with the issue tracking module on. The default assignee is any user or group, as core's API. Read back only under `view_issues` |
| `update_membership` (write) | `manage_members`. Adds any user or group, or replaces a member's roles, among the roles the caller may manage; inherited roles are left alone |
| `delete_version` (write) | `manage_versions`. Refused, with the cause, for a version that issues target, that has files, or that a custom field refers to, as core's `Version#deletable?` |
| `delete_issue_category` (write) | `manage_categories`. Its issues lose the category or take `reassign_to` |
| `delete_membership` (write) | `manage_members`. Refused for an inherited role or a role outside the caller's managed roles, as core's `Member#deletable?` |
| `delete_project` (write) | `delete_project`, and an administrator when the project has subprojects, as core's `Project#deletable?`. `confirm` repeats the identifier, as the web form. Core deletes in a background job and mails the user |

## Issues

| Tool | Permission |
|---|---|
| `search_issues`, `get_issue` | `view_issues`. `get_issue` adds the attachments, the subtasks the caller can see, the relations whose other issue the caller can see, the watchers under `view_issue_watchers`, the checklist under `view_checklists`, and the tags |
| `list_queries` | `view_issues`. Saved queries, filtered by `IssueQuery.visible` |
| `get_issue_fields` | `view_issues`. What the caller may set on an issue, before a write; with `issue` and `tracker`, what it would be under that tracker, refused as `update_issue` refuses the move |
| `create_issue` (write) | `add_issues`, on the requested tracker, plus `manage_subtasks` for `parent`, `add_issue_watchers` for `watcher_users`, `set_issues_private` or `set_own_issues_private` for `is_private`, `edit_tags` for `tag_list` and `create_tags` for a tag that does not exist yet |
| `update_issue` (write) | `edit_issues`, or `edit_own_issues` on one's own issue, on the issue's tracker, plus the per-field permissions of `create_issue` and `delete_issue_watchers` for `remove_watcher_users`. Watching or unwatching oneself needs none, as core's Watch link |
| `copy_issue` (write) | `copy_issues` on the source project and `add_issues` on the target's tracker, plus the per-field permissions of `create_issue`. Copies the fields, custom fields, parent and attachments, the watchers under `add_issue_watchers`, the subtasks on request, and links the copy as core does |
| `add_issue_note` (write) | `add_issue_notes`, on the issue's tracker, plus `set_notes_private` for private notes |
| `update_issue_note` (write) | `edit_own_issue_notes` for a note the caller wrote, `edit_issue_notes` for anyone's, plus `set_notes_private` to change privacy |
| `update_issue_checklists` (write) | `edit_checklists` to add or rename, `done_checklists` or `edit_checklists` to tick or untick. Present only with redmine_checklists |
| `update_issue_relations` (write) | `manage_issue_relations` on the issue's project, as core's relation form. Every relation type core has |
| `delete_issue` (write) | `delete_issues`, on the issue's tracker. Subtasks go with it. With time logged, `time_entries` must say `destroy`, `nullify` or `reassign`, as core's form asks |

## Time

| Tool | Permission |
|---|---|
| `list_time_entries` | `view_time_entries`. Totals, per-group hours and each entry's custom fields, filtered by `TimeEntry.visible` |
| `log_time` (write) | `log_time`, plus `log_time_for_other_users` when `user` names someone else |
| `update_time_entry` (write) | `edit_own_time_entries` for the caller's own entry, `edit_time_entries` for anyone's, plus `view_time_entries` to read it and `log_time_for_other_users` to change whose it is. `issue` or `project` moves the entry, under `log_time` on the issue's project as in core |
| `delete_time_entry` (write) | `edit_own_time_entries` for the caller's own entry, `edit_time_entries` for anyone's, as core |

## Wiki

| Tool | Permission |
|---|---|
| `list_wiki_pages`, `get_wiki_page` | `view_wiki_pages`. `get_wiki_page` with `version` reads an earlier version, under `view_wiki_edits` as in core |
| `list_wiki_page_versions` | `view_wiki_edits`. The page's history, newest first, without the text |
| `update_wiki_page` (write) | `edit_wiki_pages`. Creates the page or replaces its text, keeping the history; `version` refuses an edit made meanwhile, as core's 409. A protected page needs `protect_wiki_pages`, and `parent_title` on an existing page `rename_wiki_pages`. Watchers are mailed as for an edit in the browser |
| `delete_wiki_page` (write) | `delete_wiki_pages`, plus `protect_wiki_pages` for a protected page. With child pages, `children` must say `nullify`, `destroy` or `reassign`, as core's form asks |

## News

| Tool | Permission |
|---|---|
| `list_news`, `get_news` | `view_news`. Filtered by `News.visible`; with a project, that project's own news, as core's index |
| `create_news` (write) | `manage_news`. Publishes at once and, when `news_added` is a notified event, emails project members and news watchers; the tool tells the agent to get explicit confirmation first |
| `update_news` (write) | `manage_news`. Editing sends no email |
| `delete_news` (write) | `manage_news` |

## Files and attachments

| Tool | Permission |
|---|---|
| `get_attachment` | `view_issues`, through core's `Attachment#visible?`. Metadata, and the content of a text file within `file_max_size_displayed` |
| `list_files` | `view_files`, with the Files module on. The project's files and those of its versions, as core's `/projects/:id/files.json` |
| `add_issue_attachment` (write) | `edit_issues`, `edit_own_issues` or `add_issue_notes`, as core's `attachments_addable?`. A text file within `attachment_max_size` and the extension lists; saved with a journal, so watchers are mailed as for an issue update |
| `add_file` (write) | `manage_files`, with the Files module on. A text file, on the project or on one of its versions; mails members when `file_added` is a notified event, as core |
| `delete_attachment` (write) | The container's rule, as core's `Attachment#deletable?`: `edit_issues` or `edit_own_issues` on an issue, where the removal is journaled, `manage_files` on a project or a version, `delete_wiki_pages_attachments` on a wiki page |

## Search and reference data

| Tool | Permission |
|---|---|
| `whoami` | none. Reports identity, auth mode and granted scopes |
| `search` | `search_project`. Core's search box: issues, news, documents, changesets, wiki pages, forum messages and projects, each only under its own `view_` permission |
| `list_enumerations` | none. Trackers, statuses, priorities, time entry activities; with `project`, that project's activities and, for a caller with `log_time` there, the time entry custom fields with their required flag and allowed values |
| `list_users` | none. Filtered by `Principal.visible` |

These tools add no rule of their own to Redmine's: a tool does what its permission allows in core,
and an administrator who does not want one leaves its scope off the OAuth application.
