# Security notice

**This fork carries security fixes that the upstream projects do not have.** Version 0.3.0 fixes
four vulnerabilities found by a security audit, all rated low. Three of them come from upstream
code and are still there: if you run
[joaoperfig/redmine_mcp_plugin](https://github.com/joaoperfig/redmine_mcp_plugin) or
[stenikgroup/redmine_mcp_plugin](https://github.com/stenikgroup/redmine_mcp_plugin) with OAuth2,
switch to this fork or port the fixes.

| Fixed in 0.3.0 | joaoperfig, `2375a2d` | stenikgroup, `12374fe` |
|---|---|---|
| A token scoped to a write permission without the matching view permission (`edit_issues` or `add_issue_notes` without `view_issues`, `manage_news` without `view_news`) could act on a record it may not read, and read it back in the reply | **Present** in `add_issue_note`, without the read-back | **Present** in every issue and news write tool, with the read-back |
| `get_issue` returned other users' private notes to a token without `view_private_notes` | **Present** | **Present** |
| A refused custom field value named fields the caller may not read: another object type's, or one restricted to other roles | Not applicable: no tool sets custom fields | **Present** |
| An excluded custom field could still be filtered on through a chained key such as `cf_N.status` | Not applicable: field exclusion is this fork's | Not applicable |

Each upstream was checked by reading its code at the commit named, its latest on 2026-11-06. The
stenikgroup code is identical to the code in which this fork reproduced the flaws before fixing
them. The fixes and their regression tests are listed in the changelog under 0.3.0.
