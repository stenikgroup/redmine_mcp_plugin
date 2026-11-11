# OAuth application scopes

Administration → Applications → the MCP application. Enable at least the scopes the server
advertises. Enabling more is fine - verified live, consent succeeds - but fewer fails with
`invalid_scope`, because the client requests exactly what `scopes_supported` lists. The permission
names below are the scope; the label is what the English UI shows, and several labels repeat across
sections.

This page is the one list of scopes. How the server computes the advertised set is in
[internals.md](internals.md#supported_scopes); what each tool does with its permission is in
[tools.md](tools.md).

## Read-only mode

Advertised in read-only mode, which is the default. They are all an application needs while the
server stays read-only.

| Scope | Label in Administration → Applications | Section | Used by |
|---|---|---|---|
| `view_project` | View projects | Project | `list_projects`, `get_project`, projects in `search` |
| `view_issues` | View Issues | Issue tracking | `search_issues`, `get_issue`, `get_attachment`, `list_queries`, `get_issue_fields`, issues in `search` |
| `view_issue_watchers` | View watchers list | Issue tracking | The watchers in `get_issue` |
| `view_private_notes` | View private notes | Issue tracking | Other users' private notes in `get_issue` |
| `view_wiki_pages` | View wiki | Wiki | `list_wiki_pages`, `get_wiki_page`, wiki pages in `search` |
| `view_time_entries` | View spent time | Time tracking | `list_time_entries`; reading the entry in `update_time_entry` and `delete_time_entry` |
| `view_news` | View news | News | `list_news`, `get_news`, news in `search` |
| `view_members` | View project members | Project | `list_memberships` |
| `search_project` | Search projects | Project | `search` |
| `view_wiki_edits` | View wiki history | Wiki | `list_wiki_page_versions`; `version` in `get_wiki_page` |
| `view_files` | View files | Files | `list_files` |
| `view_documents` | View documents | Documents | Read by `search` only |
| `view_changesets` | View changesets | Repository | Read by `search` only |
| `view_messages` | View messages | Forums | Read by `search` only |

## With writes on

Advertised only once read-only mode is switched off.

| Scope | Label in Administration → Applications | Section | Used by |
|---|---|---|---|
| `add_issues` | Add issues | Issue tracking | `create_issue`; the target of `copy_issue` |
| `edit_issues` | Edit issues | Issue tracking | `update_issue`, `add_issue_attachment`, `delete_attachment` on an issue |
| `edit_own_issues` | Edit own issues | Issue tracking | The same, on one's own issue |
| `add_issue_notes` | Add notes | Issue tracking - **not** the "Add notes" under Contacts | `add_issue_note`, `add_issue_attachment` |
| `copy_issues` | Copy issues | Issue tracking | `copy_issue` |
| `delete_issues` | Delete issues | Issue tracking | `delete_issue` |
| `set_notes_private` | Set notes as private | Issue tracking | `private_notes` in `add_issue_note` and `update_issue_note` |
| `edit_own_issue_notes` | Edit own notes | Issue tracking | `update_issue_note`, on a note the caller wrote |
| `edit_issue_notes` | Edit notes | Issue tracking | `update_issue_note`, on anyone's note |
| `manage_subtasks` | Manage subtasks | Issue tracking | `parent` in `create_issue`, `update_issue` and `copy_issue` |
| `add_issue_watchers` | Add watchers | Issue tracking | `watcher_users` in `create_issue`, `update_issue` and `copy_issue` |
| `delete_issue_watchers` | Delete watchers | Issue tracking | `remove_watcher_users` in `update_issue` |
| `set_issues_private` | Set issues public or private | Issue tracking | `is_private` in `create_issue`, `update_issue` and `copy_issue` |
| `set_own_issues_private` | Set own issues public or private | Issue tracking | The same, on one's own issue |
| `manage_issue_relations` | Manage issue relations | Issue tracking | `update_issue_relations` |
| `manage_categories` | Manage issue categories | Issue tracking | `create_issue_category`, `update_issue_category`, `delete_issue_category` |
| `log_time` | Log spent time | Time tracking | `log_time`; moving an entry in `update_time_entry` |
| `log_time_for_other_users` | Log spent time for other users | Time tracking | `user` in `log_time` and `update_time_entry` |
| `edit_time_entries` | Edit time logs | Time tracking | `update_time_entry`, `delete_time_entry`, on anyone's entry |
| `edit_own_time_entries` | Edit own time logs | Time tracking | `update_time_entry`, `delete_time_entry`, on the caller's own entry |
| `edit_wiki_pages` | Edit wiki pages | Wiki | `update_wiki_page` |
| `rename_wiki_pages` | Rename wiki pages | Wiki | `parent_title` on an existing page in `update_wiki_page` |
| `protect_wiki_pages` | Protect wiki pages | Wiki | A protected page in `update_wiki_page` and `delete_wiki_page` |
| `delete_wiki_pages` | Delete wiki pages | Wiki | `delete_wiki_page` |
| `delete_wiki_pages_attachments` | Delete attachments | Wiki | `delete_attachment` on a wiki page |
| `manage_files` | Manage files | Files | `add_file`; `delete_attachment` on a project or a version |
| `manage_news` | Manage news | News | `create_news`, `update_news`, `delete_news` |
| `add_project` | Create project | Project | `create_project` for a root project; moving one in `update_project` |
| `add_subprojects` | Create subprojects | Project | `create_project` for a subproject; moving one in `update_project` |
| `edit_project` | Edit project | Project | `update_project` |
| `close_project` | Close / reopen the project | Project | `close_project`, `reopen_project` |
| `delete_project` | Delete the project | Project | `delete_project` |
| `select_project_publicity` | Set project public or private | Project | `is_public` in `create_project` and `update_project` |
| `select_project_modules` | Select project modules | Project | `enabled_modules` in `create_project` and `update_project` |
| `manage_members` | Manage members | Project | `update_membership`, `delete_membership`; `inherit_members` on a project; the roles `list_memberships` says the caller may give |
| `manage_versions` | Manage versions | Project | `create_version`, `update_version`, `delete_version` |

## With an optional plugin

These rows exist only while that plugin is installed. The server reads this per request, so
installing or removing one of those plugins changes the advertised set the way adding a tool does.

| Scope | Label in Administration → Applications | Requires | Advertised | Used by |
|---|---|---|---|---|
| `view_checklists` | View checklist | redmine_checklists | Read-only mode | The checklist in `get_issue` |
| `done_checklists` | Done checklist items | redmine_checklists | With writes on | Ticking and unticking in `update_issue_checklists` |
| `edit_checklists` | Edit checklist items | redmine_checklists | With writes on | `update_issue_checklists` |
| `create_tags` | Create tags | redmineup_tags | With writes on | A tag that does not exist yet, in `tag_list` |
| `edit_tags` | Edit tags | redmineup_tags | With writes on | `tag_list` in `create_issue` and `update_issue` |

All five sit under Issue tracking in the application form.

## When the advertised set changes

Several scopes gate no tool but one parameter, or one part of a reply, as the "Used by" column
shows. A permission a tool checks at runtime must be advertised, or no token can ever carry it.

Adding a tool with a new permission changes the advertised set, and every user reconnects to get a
token that carries it. The application only needs editing if it did not already enable the scope.
An extension adds the permissions of its tools in the same way; see [extensions.md](extensions.md).
