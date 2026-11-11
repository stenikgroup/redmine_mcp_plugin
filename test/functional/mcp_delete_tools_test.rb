# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Every deletion follows the permission core has for it, which is the scope an
# administrator ticks, or leaves unticked, on the OAuth application.
class McpDeleteToolsTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :issue_categories, :issue_relations, :trackers, :enumerations,
           :enabled_modules, :watchers, :projects_trackers, :workflows, :custom_fields,
           :custom_fields_trackers, :custom_fields_projects, :custom_values, :time_entries, :versions,
           :journals, :journal_details, :attachments, :news, :comments,
           :wikis, :wiki_pages, :wiki_contents, :wiki_content_versions

  DELETE_PERMISSIONS = %i[delete_issues delete_project manage_versions manage_categories edit_time_entries
                          edit_own_time_entries manage_news delete_wiki_pages delete_wiki_pages_attachments
                          protect_wiki_pages manage_files manage_members edit_issues].freeze

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
    set_tmp_attachments_directory
    # jsmith is a manager on ecookbook; the role is given what each test then takes away.
    Role.find(1).add_permission!(*DELETE_PERMISSIONS)
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  def state(result)
    assert result, json_body.inspect
    assert_not result['isError'], result.inspect
    result['structuredContent']
  end

  def refusal(result)
    assert result, json_body.inspect
    assert result['isError'], result.inspect
    result['content'].first['text']
  end

  # --- issues -------------------------------------------------------------

  def test_delete_issue_takes_its_subtasks_with_it
    parent = Issue.generate!(project_id: 1, tracker_id: 1)
    child  = Issue.generate!(project_id: 1, tracker_id: 1, parent_issue_id: parent.id)

    deleted = state(call_tool('delete_issue', { 'issue' => parent.id }))
    assert_equal [parent.id, child.id].sort, deleted['deleted_issue_ids'].sort
    assert_not Issue.exists?(parent.id)
    assert_not Issue.exists?(child.id)
  end

  def test_delete_issue_asks_what_becomes_of_logged_time
    issue = Issue.generate!(project_id: 1, tracker_id: 1)
    other = Issue.generate!(project_id: 1, tracker_id: 1)
    entry = TimeEntry.generate!(project_id: 1, issue: issue, hours: 2)

    assert_match 'pass time_entries: destroy, nullify or reassign', refusal(call_tool('delete_issue', { 'issue' => issue.id }))
    assert Issue.exists?(issue.id)
    assert_match 'reassign_to must be an issue of ecookbook',
                 refusal(call_tool('delete_issue', { 'issue' => issue.id, 'time_entries' => 'reassign', 'reassign_to' => 999_999 }))
    assert Issue.exists?(issue.id)

    deleted = state(call_tool('delete_issue', { 'issue' => issue.id, 'time_entries' => 'reassign', 'reassign_to' => other.id }))
    assert_in_delta 2.0, deleted['hours']
    assert_not Issue.exists?(issue.id)
    assert_equal other.id, entry.reload.issue_id
  end

  def test_delete_issue_can_keep_the_time_on_the_project_or_delete_it
    kept    = Issue.generate!(project_id: 1, tracker_id: 1)
    entry   = TimeEntry.generate!(project_id: 1, issue: kept, hours: 1)
    state(call_tool('delete_issue', { 'issue' => kept.id, 'time_entries' => 'nullify' }))
    assert_nil entry.reload.issue_id

    gone  = Issue.generate!(project_id: 1, tracker_id: 1)
    spent = TimeEntry.generate!(project_id: 1, issue: gone, hours: 1)
    state(call_tool('delete_issue', { 'issue' => gone.id, 'time_entries' => 'destroy' }))
    assert_not TimeEntry.exists?(spent.id)
  end

  # --- time, news, versions, categories ---------------------------------------

  def test_delete_time_entry_of_another_user_needs_edit_time_entries
    own    = TimeEntry.generate!(project_id: 1, user: User.find(2))
    others = TimeEntry.generate!(project_id: 1, user: User.find(3))
    Role.find_each { |role| role.remove_permission!(:edit_time_entries) }

    assert_match "Deleting another user's time needs ", refusal(call_tool('delete_time_entry', { 'time_entry' => others.id }))
    assert TimeEntry.exists?(others.id)
    assert state(call_tool('delete_time_entry', { 'time_entry' => own.id }))['deleted']
    assert_not TimeEntry.exists?(own.id)
  end

  def test_delete_news
    assert state(call_tool('delete_news', { 'news' => 1 }))['deleted']
    assert_not News.exists?(1)
    assert_match 'No visible news with id 1', refusal(call_tool('delete_news', { 'news' => 1 }))
  end

  def test_delete_version_names_what_blocks_it
    used = Version.find(2)
    assert used.fixed_issues.any?
    assert_match(/Cannot delete this version: \d+ issues target it/, refusal(call_tool('delete_version', { 'version' => 2 })))
    assert Version.exists?(2)

    empty = Version.generate!(project: Project.find(1))
    assert state(call_tool('delete_version', { 'version' => empty.id }))['deleted']
    assert_not Version.exists?(empty.id)
  end

  def test_delete_issue_category_moves_its_issues_on_request
    from  = IssueCategory.find(1)
    to    = IssueCategory.create!(project_id: 1, name: 'Elsewhere')
    issue = Issue.generate!(project_id: 1, tracker_id: 1, category: from)

    assert_match 'reassign_to must be another category of ecookbook',
                 refusal(call_tool('delete_issue_category', { 'category' => 1, 'reassign_to' => 1 }))
    deleted = state(call_tool('delete_issue_category', { 'category' => 1, 'reassign_to' => to.id }))
    assert_equal to.id, deleted['reassigned_to']
    assert_equal to.id, issue.reload.category_id
    assert_not IssueCategory.exists?(1)

    state(call_tool('delete_issue_category', { 'category' => to.id }))
    assert_nil issue.reload.category_id
  end

  # --- wiki and attachments ---------------------------------------------------

  def test_delete_wiki_page_asks_what_becomes_of_its_children
    wiki   = Project.find(1).wiki
    parent = WikiPage.create!(wiki: wiki, title: 'Guide', content: WikiContent.new(text: 'Guide', author: User.find(2)))
    child  = WikiPage.create!(wiki: wiki, title: 'Chapter', parent: parent, content: WikiContent.new(text: 'One', author: User.find(2)))
    page   = { 'project' => 'ecookbook', 'title' => 'Guide' }

    assert_match 'has child pages (Chapter); pass children: nullify, destroy or reassign', refusal(call_tool('delete_wiki_page', page))
    assert WikiPage.exists?(parent.id)

    deleted = state(call_tool('delete_wiki_page', page.merge('children' => 'reassign', 'reassign_to' => 'Another_page')))
    assert_equal ['Chapter'], deleted['descendants']
    assert_not WikiPage.exists?(parent.id)
    assert_equal 'Another_page', child.reload.parent.title

    state(call_tool('delete_wiki_page', { 'project' => 'ecookbook', 'title' => 'Chapter' }))
    assert_not WikiPage.exists?(child.id)
  end

  def test_delete_wiki_page_refuses_a_protected_page_without_its_permission
    Role.find_each { |role| role.remove_permission!(:protect_wiki_pages) }
    text = refusal(call_tool('delete_wiki_page', { 'project' => 'ecookbook', 'title' => 'CookBook_documentation',
                                                   'children' => 'nullify' }))
    assert_match 'is protected: deleting it needs ', text
    assert WikiPage.exists?(1)
  end

  def test_delete_attachment_of_an_issue_is_journaled
    issue = Issue.find(1)
    added = state(call_tool('add_issue_attachment', { 'issue' => 1, 'filename' => 'log.txt', 'content' => 'trace' }))

    assert_difference -> { issue.journals.count }, 1 do
      deleted = state(call_tool('delete_attachment', { 'attachment' => added['id'] }))
      assert_equal 'log.txt', deleted['filename']
      assert_equal({ 'type' => 'Issue', 'id' => 1 }, deleted['container'])
    end
    assert_not Attachment.exists?(added['id'])
  end

  # Core's Issue#attachments_deletable? needs the issue visible as well as editable.
  def test_delete_attachment_of_an_issue_the_caller_cannot_see_is_refused
    Role.find(1).update!(issues_visibility: 'default')
    issue      = Issue.generate!(project_id: 1, author: User.find(1), is_private: true)
    attachment = Attachment.generate!(container: issue, author: User.find(1))
    assert_not issue.visible?(User.find(2))

    assert_match 'No visible attachment', refusal(call_tool('delete_attachment', { 'attachment' => attachment.id }))
    assert Attachment.exists?(attachment.id)
  end

  def test_delete_attachment_of_an_issue_refuses_a_token_without_view_issues
    refused = call_as('view_project edit_issues', 'delete_attachment', { 'attachment' => 1 })
    assert_match 'No visible attachment', refusal(refused['result'])
    assert Attachment.exists?(1)

    state(call_as('view_project view_issues edit_issues', 'delete_attachment', { 'attachment' => 1 })['result'])
    assert_not Attachment.exists?(1)
  end

  def test_delete_attachment_of_a_project_file_needs_manage_files
    Role.find(1).add_permission!(:manage_files, :view_files)
    added = state(call_tool('add_file', { 'project' => 'ecookbook', 'filename' => 'notes.md', 'content' => '# Notes' }))
    Role.find_each { |role| role.remove_permission!(:manage_files) }

    assert_match 'do not have permission', refusal(call_tool('delete_attachment', { 'attachment' => added['id'] }))
    assert Attachment.exists?(added['id'])
    assert_match 'No visible attachment', refusal(call_tool('delete_attachment', { 'attachment' => 999_999 }))
  end

  # --- members and projects ---------------------------------------------------

  def test_delete_membership
    newcomer = User.generate!
    Member.create!(project_id: 1, user_id: newcomer.id, role_ids: [3])

    removed = state(call_tool('delete_membership', { 'project' => 'ecookbook', 'principal' => newcomer.id }))
    assert_equal newcomer.id, removed['principal']['id']
    assert_not Member.exists?(project_id: 1, user_id: newcomer.id)
    assert_match "#{newcomer.id} is not a member of ecookbook",
                 refusal(call_tool('delete_membership', { 'project' => 'ecookbook', 'principal' => newcomer.id }))
  end

  def test_delete_membership_refuses_a_role_the_caller_may_not_manage
    Role.find(1).update!(all_roles_managed: false, managed_role_ids: [3])
    text = refusal(call_tool('delete_membership', { 'project' => 'ecookbook', 'principal' => 3 }))
    assert_match 'Cannot remove this member: you may not manage every role they hold', text
    assert Member.exists?(project_id: 1, user_id: 3)
  end

  def test_delete_project_needs_its_identifier_typed_again
    project = Project.generate!
    Member.create!(project: project, user_id: 2, role_ids: [1])
    arguments = { 'project' => project.identifier }

    assert_match 'confirm must be the project identifier', refusal(call_tool('delete_project', arguments.merge('confirm' => 'yes')))
    assert_equal Project::STATUS_ACTIVE, project.reload.status

    deleted = state(call_tool('delete_project', arguments.merge('confirm' => project.identifier)))
    assert deleted['scheduled']
    # Core marks the project at once and deletes it in a background job.
    remaining = Project.find_by(id: project.id)
    assert(remaining.nil? || remaining.status == Project::STATUS_SCHEDULED_FOR_DELETION)
  end

  def test_delete_project_with_subprojects_is_for_an_administrator
    text = refusal(call_tool('delete_project', { 'project' => 'ecookbook', 'confirm' => 'ecookbook' }))
    assert_match 'has subprojects; only an administrator may delete it', text
    assert_equal Project::STATUS_ACTIVE, Project.find(1).status
  end

  # --- what a token may do -------------------------------------------------

  def call_as(scopes, name, arguments)
    application = Doorkeeper::Application.create!(name: 'MCP test', redirect_uri: 'https://client.example/callback',
                                                  scopes: scopes)
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: 2, scopes: scopes,
                                            expires_in: 2.hours)
    post_mcp rpc('tools/call', { 'name' => name, 'arguments' => arguments }),
             'Authorization' => "Bearer #{token.plaintext_token}"
    json_body
  end

  # The role grants every deletion here. A token without the scope does not see
  # the tool, and that is the only switch there is.
  def test_a_token_without_the_delete_scopes_can_delete_nothing
    scopes = 'view_project view_issues view_time_entries view_news view_wiki_pages view_members ' \
             'add_issues add_issue_notes log_time'
    entry  = TimeEntry.generate!(project_id: 1, user: User.find(2))
    calls  = { 'delete_issue' => { 'issue' => 1 },
               'delete_project' => { 'project' => 'ecookbook', 'confirm' => 'ecookbook' },
               'delete_version' => { 'version' => 2 },
               'delete_issue_category' => { 'category' => 1 },
               'delete_time_entry' => { 'time_entry' => entry.id },
               'delete_news' => { 'news' => 1 },
               'delete_wiki_page' => { 'project' => 'ecookbook', 'title' => 'Another_page' },
               'delete_attachment' => { 'attachment' => 1 },
               'delete_membership' => { 'project' => 'ecookbook', 'principal' => 3 } }

    calls.each do |name, arguments|
      body = call_as(scopes, name, arguments)
      assert_match(/Unknown tool/, body.dig('error', 'message').to_s, "#{name} must be hidden")
    end
    assert Issue.exists?(1)
    assert News.exists?(1)
    assert TimeEntry.exists?(entry.id)
    assert Member.exists?(project_id: 1, user_id: 3)
  end

  def test_the_delete_scopes_are_what_show_the_tools
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    names = json_body['result']['tools'].map { |tool| tool['name'] }
    %w[delete_issue delete_project delete_version delete_issue_category delete_time_entry delete_news
       delete_wiki_page delete_attachment delete_membership].each { |name| assert_includes names, name }

    Role.find_each { |role| role.remove_permission!(*DELETE_PERMISSIONS, :edit_own_issues) }
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_empty(json_body['result']['tools'].map { |tool| tool['name'] }.grep(/\Adelete_/))
  end
end
