# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Time entries of other users, notes of other users, and copies of issues: each
# follows the permission core has for it.
class McpIssueTimeTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :issue_categories, :issue_relations, :trackers, :enumerations,
           :enabled_modules, :watchers, :projects_trackers, :workflows, :custom_fields,
           :custom_fields_trackers, :custom_fields_projects, :custom_values, :time_entries, :versions,
           :journals, :journal_details, :attachments

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
    # jsmith is a manager on ecookbook; the role is given what each test then takes away.
    Role.find(1).add_permission!(:edit_time_entries, :edit_own_time_entries, :log_time_for_other_users,
                                 :edit_issue_notes, :edit_own_issue_notes, :copy_issues)
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

  def others_entry
    TimeEntry.where(project_id: 1).where.not(user_id: 2).first || TimeEntry.generate!(project_id: 1, user: User.find(3))
  end

  # --- time entries ---------------------------------------------------------

  def test_update_time_entry_changes_only_what_is_sent
    entry = TimeEntry.generate!(project_id: 1, user: User.find(2), hours: 2, comments: 'Before')
    saved = state(call_tool('update_time_entry', { 'time_entry' => entry.id, 'hours' => 3.5, 'spent_on' => '2026-01-05' }))

    assert_in_delta 3.5, saved['hours']
    assert_equal '2026-01-05', saved['spent_on']
    assert_equal 'Before', saved['comments']
    assert_equal 2, saved['user']['id']
  end

  def test_update_time_entry_needs_a_field_and_a_visible_entry
    entry = TimeEntry.generate!(project_id: 1, user: User.find(2))
    assert_match 'at least one field', refusal(call_tool('update_time_entry', { 'time_entry' => entry.id }))
    assert_match 'No visible time entry', refusal(call_tool('update_time_entry', { 'time_entry' => 999_999, 'hours' => 1 }))
  end

  def test_update_time_entry_of_another_user_needs_edit_time_entries
    entry = others_entry
    assert_not state(call_tool('update_time_entry', { 'time_entry' => entry.id, 'comments' => 'Reviewed' }))['isError']
    assert_equal 'Reviewed', entry.reload.comments

    Role.find_each { |role| role.remove_permission!(:edit_time_entries) }
    text = refusal(call_tool('update_time_entry', { 'time_entry' => entry.id, 'comments' => 'Again' }))
    assert_match "Editing another user's time needs ", text
    assert_equal 'Reviewed', entry.reload.comments
  end

  def test_update_time_entry_refuses_an_unknown_activity
    entry = TimeEntry.generate!(project_id: 1, user: User.find(2))
    assert_match 'no activity named "Napping"',
                 refusal(call_tool('update_time_entry', { 'time_entry' => entry.id, 'activity' => 'Napping' }))
  end

  def test_log_time_for_another_user_needs_its_permission
    arguments = { 'project' => 'ecookbook', 'hours' => 1, 'activity' => 'Design', 'user' => 3 }
    saved = state(call_tool('log_time', arguments))
    assert_equal 3, saved['user']['id']
    assert_equal 2, TimeEntry.find(saved['id']).author_id

    Role.find_each { |role| role.remove_permission!(:log_time_for_other_users) }
    assert_no_difference 'TimeEntry.count' do
      assert_match 'Logging time for another user needs ', refusal(call_tool('log_time', arguments))
    end
    # Oneself needs nothing more than log_time.
    assert_equal 2, state(call_tool('log_time', arguments.merge('user' => 'me')))['user']['id']
  end

  def test_log_time_refuses_a_user_who_may_not_log_time_there
    outsider = User.generate!
    text = refusal(call_tool('log_time', { 'project' => 'ecookbook', 'hours' => 1, 'activity' => 'Design',
                                           'user' => outsider.id }))
    assert_match "User #{outsider.id} may not log time on ecookbook", text
  end

  # --- notes ----------------------------------------------------------------

  def others_note
    Journal.create!(journalized: Issue.find(1), user: User.find(3), notes: 'Written by dlopper')
  end

  def test_update_issue_note_edits_another_users_note_with_edit_issue_notes
    journal = others_note
    saved   = state(call_tool('update_issue_note', { 'journal' => journal.id, 'notes' => 'Corrected' }))

    assert_equal 'Corrected', saved['notes']
    assert_equal User.find(3).name, saved['author']
    assert_equal 'Corrected', journal.reload.notes
    assert_equal 3, journal.user_id
  end

  def test_update_issue_note_of_another_user_is_refused_without_edit_issue_notes
    journal = others_note
    Role.find_each { |role| role.remove_permission!(:edit_issue_notes) }

    text = refusal(call_tool('update_issue_note', { 'journal' => journal.id, 'notes' => 'Corrected' }))
    assert_match "Editing another user's note needs ", text
    assert_equal 'Written by dlopper', journal.reload.notes
  end

  def test_update_issue_note_still_edits_ones_own_with_edit_own_only
    Role.find_each { |role| role.remove_permission!(:edit_issue_notes) }
    journal = Journal.create!(journalized: Issue.find(1), user: User.find(2), notes: 'Mine')
    assert_equal 'Mine, fixed', state(call_tool('update_issue_note', { 'journal' => journal.id, 'notes' => 'Mine, fixed' }))['notes']
  end

  # --- copies ---------------------------------------------------------------

  def test_copy_issue_keeps_the_fields_and_links_the_copy
    source = Issue.find(1)
    copy   = state(call_tool('copy_issue', { 'issue' => 1 }))

    assert_not_equal 1, copy['id']
    assert_equal 1, copy['copied_from']
    assert_equal source.subject, copy['subject']
    assert_equal source.tracker.name, copy['tracker']
    assert_equal 'ecookbook', copy['project_identifier']
    assert IssueRelation.exists?(issue_from_id: 1, issue_to_id: copy['id'], relation_type: 'copied_to')
    assert_equal 2, Issue.find(copy['id']).author_id
  end

  def test_copy_issue_takes_overrides_and_can_skip_the_link
    copy = state(call_tool('copy_issue', { 'issue' => 1, 'subject' => 'Second run', 'priority' => 'Urgent', 'link' => false }))

    assert_equal 'Second run', copy['subject']
    assert_equal 'Urgent', copy['priority']
    assert_not IssueRelation.exists?(issue_to_id: copy['id'])
  end

  def test_copy_issue_refuses_a_blocked_field_and_creates_nothing
    assert_no_difference 'Issue.count' do
      assert_match 'No active priority', refusal(call_tool('copy_issue', { 'issue' => 1, 'priority' => 'Whenever' }))
      assert_match 'No visible issue', refusal(call_tool('copy_issue', { 'issue' => 999_999 }))
    end
  end

  def test_copy_issue_needs_copy_issues_on_the_source_project
    # dlopper may copy on onlinestore only.
    Role.find_each { |role| role.remove_permission!(:copy_issues) }
    Member.where(project_id: 2, user_id: 3).destroy_all
    Role.find(3).add_permission!(:copy_issues)
    Member.create!(project_id: 2, user_id: 3, role_ids: [3])

    assert_no_difference 'Issue.count' do
      assert_match 'do not have permission', refusal(call_tool('copy_issue', { 'issue' => 1 }, User.find(3)))
    end
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

  # The role grants everything here; the token's scopes are what narrow it.
  def test_a_token_scoped_to_ones_own_cannot_touch_anothers
    scopes  = 'view_project view_issues view_time_entries log_time edit_own_time_entries edit_own_issue_notes'
    entry   = others_entry
    journal = others_note

    assert_match "Editing another user's time needs ",
                 refusal(call_as(scopes, 'update_time_entry', { 'time_entry' => entry.id, 'hours' => 9 })['result'])
    assert_match "Editing another user's note needs ",
                 refusal(call_as(scopes, 'update_issue_note', { 'journal' => journal.id, 'notes' => 'X' })['result'])
    assert_match 'Logging time for another user needs ',
                 refusal(call_as(scopes, 'log_time', { 'project' => 'ecookbook', 'hours' => 1, 'activity' => 'Design',
                                                       'user' => 3 })['result'])
    assert call_as(scopes, 'copy_issue', { 'issue' => 1 })['error'].present?
  end
end
