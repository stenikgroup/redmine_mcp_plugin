# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Writing an issue: every field create_issue and update_issue take, what each
# refuses and how it names the refusal, then notes, watchers and relations.
class McpIssueWritesTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :issue_categories, :issue_relations, :trackers, :enumerations,
           :enabled_modules, :watchers, :projects_trackers, :workflows, :custom_fields,
           :custom_fields_trackers, :custom_fields_projects, :custom_values, :versions,
           :journals, :journal_details, :attachments, :time_entries

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
    set_tmp_attachments_directory
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  def without_permission(*permissions)
    Role.find_each { |role| permissions.each { |permission| role.remove_permission!(permission) } }
  end

  # --- every field ----------------------------------------------------------

  def test_create_issue_sets_every_field_and_reads_them_back
    created = state(call_tool('create_issue', {
                                'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Full', 'description' => 'Body',
                                'priority' => 'High', 'category' => 'Recipes', 'fixed_version' => 3, 'assigned_to' => 'me',
                                'parent' => 1, 'start_date' => '2026-01-05', 'due_date' => '2026-01-09', 'done_ratio' => 30,
                                'estimated_hours' => 2.5, 'is_private' => true, 'watcher_users' => [3]
                              }))
    issue = Issue.find(created['id'])

    assert_equal 'Recipes', created['category']
    assert_equal issue.fixed_version.name, created['fixed_version']
    assert_equal 3, issue.fixed_version_id
    assert_equal User.find(2).name, created['assigned_to']
    assert_equal 'High', created['priority']
    assert_equal 1, created['parent']
    assert_equal '2026-01-05', created['start_date']
    assert_equal '2026-01-09', created['due_date']
    assert_equal 30, created['done_ratio']
    assert_equal 2.5, created['estimated_hours']
    assert created['is_private']
    assert_equal [User.find(3).name], created['watcher_users']
    assert_equal 'Body', created['description']
  end

  def test_create_issue_names_every_refused_field_at_once
    assert_no_difference 'Issue.count' do
      text = refusal(call_tool('create_issue', {
                                 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Refused',
                                 'status' => 'Nope', 'priority' => 'Nope', 'category' => 'Nope', 'fixed_version' => 'Nope',
                                 'assigned_to' => 999, 'parent' => 999_999, 'watcher_users' => [999]
                               }))
      assert_match 'Cannot set', text
      assert_match 'status (No issue status named "Nope")', text
      assert_match 'priority (No active priority named "Nope")', text
      assert_match(/category \(No category "Nope" in ecookbook\. Categories: .*Recipes/, text)
      assert_match 'fixed_version (No assignable version "Nope" for ecookbook', text
      assert_match 'assigned_to (999 is not assignable on ecookbook)', text
      assert_match 'parent (No visible issue with id', text
      assert_match 'watcher_users (User 999 cannot be added as a watcher of this issue)', text
    end
  end

  # A value of the wrong shape is the schema's kind of mistake and refuses at once.
  def test_a_value_of_the_wrong_shape_is_refused_alone
    base = { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Shape' }

    assert_match 'assigned_to must be a user id from list_users, or "me"',
                 refusal(call_tool('create_issue', base.merge('assigned_to' => 'bob')))
    assert_match 'parent must be an issue id, or "none"', refusal(call_tool('update_issue', { 'issue' => 1, 'parent' => 'abc' }))
    assert_match 'start_date must be an ISO-8601 date', refusal(call_tool('create_issue', base.merge('start_date' => 'tomorrow')))
  end

  def test_update_issue_clears_a_field_with_none
    issue = Issue.find(1)
    issue.update_columns(fixed_version_id: 3, assigned_to_id: 3, category_id: 1, parent_id: nil)

    state(call_tool('update_issue', { 'issue' => 1, 'category' => 'none', 'fixed_version' => 'none', 'assigned_to' => 'none',
                                      'start_date' => 'none', 'due_date' => 'none', 'parent' => 'none' }))
    issue.reload
    assert_nil issue.category_id
    assert_nil issue.fixed_version_id
    assert_nil issue.assigned_to_id
    assert_nil issue.start_date
    assert_nil issue.due_date
  end

  def test_update_issue_takes_a_category_and_a_version_by_name_or_id
    updated = state(call_tool('update_issue', { 'issue' => 1, 'category' => 2, 'fixed_version' => 3 }))
    assert_equal 'Recipes', updated['category']
    assert_equal 3, Issue.find(1).fixed_version_id

    assert_equal 'Printing', state(call_tool('update_issue', { 'issue' => 1, 'category' => 'Printing' }))['category']
  end

  # Two assignable versions with one name: the id is asked for, with the choices.
  def test_a_version_name_shared_by_two_versions_asks_for_the_id
    twin = Version.create!(project_id: 1, name: "#{Version.find(3).name} twin")
    twin.update_column(:name, Version.find(3).name)

    text = refusal(call_tool('update_issue', { 'issue' => 1, 'fixed_version' => Version.find(3).name }))
    assert_match 'is ambiguous here; pass the id', text
    assert_match "id #{twin.id}", text
  end

  # --- parent -----------------------------------------------------------------

  def test_update_issue_refuses_itself_or_another_project_as_parent
    assert_match '#1 is this issue or one of its subtasks', refusal(call_tool('update_issue', { 'issue' => 1, 'parent' => 1 }))

    with_settings cross_project_subtasks: 'tree' do
      text = refusal(call_tool('update_issue', { 'issue' => 1, 'parent' => 4 }))
      assert_match '#4 is in onlinestore, outside what the cross-project subtasks setting', text
    end
  end

  def test_update_issue_sets_a_parent
    assert_equal 2, state(call_tool('update_issue', { 'issue' => 1, 'parent' => 2 }))['parent']
    assert_equal 2, Issue.find(1).parent_id
  end

  # --- status, tracker, done ratio ----------------------------------------------

  def test_update_issue_names_the_statuses_the_workflow_allows
    WorkflowTransition.delete_all
    text = refusal(call_tool('update_issue', { 'issue' => 1, 'status' => 'Closed' }))
    assert_match '"Closed" is not allowed here; allowed:', text
    assert_equal 1, Issue.find(1).status_id
  end

  def test_create_issue_asks_for_the_tracker_when_the_project_has_several
    text = refusal(call_tool('create_issue', { 'project' => 'ecookbook', 'subject' => 'Which' }))
    assert_match 'Pass tracker. ecookbook allows: ', text
    assert_match 'Bug', text
  end

  def test_create_issue_takes_the_only_tracker_there_is
    Project.find(1).update!(tracker_ids: [2])
    created = state(call_tool('create_issue', { 'project' => 'ecookbook', 'subject' => 'Only one' }))
    assert_equal Tracker.find(2).name, created['tracker']
  end

  def test_create_issue_refuses_an_unknown_tracker_and_one_the_role_may_not_use
    base = { 'project' => 'ecookbook', 'subject' => 'Tracker' }
    assert_match 'Project ecookbook has no tracker named "Nope"', refusal(call_tool('create_issue', base.merge('tracker' => 'Nope')))

    role = Role.find(1)
    role.set_permission_trackers(:add_issues, [2])
    role.save!
    assert_match 'You do not have permission to create issues with tracker "Bug" in project ecookbook',
                 refusal(call_tool('create_issue', base.merge('tracker' => 'Bug')))
  end

  def test_done_ratio_is_refused_when_the_status_computes_it
    with_settings issue_done_ratio: 'issue_status' do
      text = refusal(call_tool('update_issue', { 'issue' => 1, 'done_ratio' => 50 }))
      assert_match 'done_ratio (computed from the status on this Redmine)', text
    end
  end

  # --- what a role, a tracker or a workflow blocks ---------------------------------

  def test_a_field_gated_by_a_permission_names_the_permission
    without_permission(:manage_subtasks, :add_issue_watchers, :set_issues_private, :set_own_issues_private)

    text = refusal(call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Gated',
                                               'parent' => 1, 'watcher_users' => [3], 'is_private' => true }))
    assert_match 'parent (needs ', text
    assert_match 'watcher_users (needs ', text
    assert_match 'is_private (needs ', text
  end

  def test_a_field_disabled_on_the_tracker_or_read_only_by_workflow_says_so
    tracker = Tracker.find(1)
    tracker.update!(core_fields: tracker.core_fields - ['due_date'])
    WorkflowPermission.create!(role_id: 1, tracker_id: 1, old_status_id: 1, field_name: 'start_date', rule: 'readonly')

    text = refusal(call_tool('update_issue', { 'issue' => 1, 'due_date' => '2026-02-01', 'start_date' => '2026-01-01' }))
    assert_match 'due_date (disabled on tracker Bug)', text
    assert_match 'start_date (read-only by workflow)', text
  end

  # edit_own_issues admits the tool; core's rule is then applied per issue.
  def test_edit_own_issues_edits_ones_own_issue_only
    without_permission(:edit_issues)
    Role.find(1).add_permission!(:edit_own_issues)
    own    = Issue.generate!(project_id: 1, author: User.find(2))
    theirs = Issue.generate!(project_id: 1, author: User.find(3))

    assert_equal 'Mine', state(call_tool('update_issue', { 'issue' => own.id, 'subject' => 'Mine' }))['subject']
    assert_match 'do not have permission', refusal(call_tool('update_issue', { 'issue' => theirs.id, 'subject' => 'Theirs' }))

    added = state(call_tool('add_issue_attachment', { 'issue' => own.id, 'filename' => 'own.txt', 'content' => 'mine' }))
    assert_equal 'own.txt', added['filename']
  end

  def test_update_issue_needs_something_to_change
    assert_match 'Pass at least one field to change, or a note', refusal(call_tool('update_issue', { 'issue' => 1 }))
  end

  # A label that names two values of a list field cannot pick one.
  def test_a_custom_field_label_naming_two_values_is_refused
    CustomField.find(1).update!(possible_values: %w[MySQL mysql Oracle])
    text = refusal(call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Twice',
                                               'custom_field_values' => { '1' => 'MYSQL' } }))
    assert_match '"MYSQL" names several values, pass one: MySQL, mysql', text
  end

  # --- watchers -------------------------------------------------------------------

  def test_update_issue_adds_and_removes_watchers
    added = state(call_tool('update_issue', { 'issue' => 1, 'add_watcher_users' => ['me', 3] }))
    assert_equal [2, 3], Issue.find(1).watcher_user_ids.sort
    assert_equal 2, added['watcher_users'].size

    state(call_tool('update_issue', { 'issue' => 1, 'remove_watcher_users' => [3] }))
    assert_equal [2], Issue.find(1).watcher_user_ids
  end

  def test_update_issue_refuses_a_watcher_it_cannot_add_or_remove
    assert_match 'add_watcher_users (User 999 cannot be added as a watcher of #1)',
                 refusal(call_tool('update_issue', { 'issue' => 1, 'add_watcher_users' => [999] }))
    assert_match 'remove_watcher_users (User 3 is not a watcher of #1)',
                 refusal(call_tool('update_issue', { 'issue' => 1, 'remove_watcher_users' => [3] }))
  end

  # Watching oneself is core's Watch link and needs no permission; anyone else does.
  def test_adding_another_watcher_needs_its_permission_and_oneself_does_not
    without_permission(:add_issue_watchers)

    assert_match 'add_watcher_users (needs ', refusal(call_tool('update_issue', { 'issue' => 1, 'add_watcher_users' => [3] }))
    state(call_tool('update_issue', { 'issue' => 1, 'add_watcher_users' => ['me'] }))
    assert_equal [2], Issue.find(1).watcher_user_ids
  end

  # --- notes ------------------------------------------------------------------------

  def test_add_issue_note_marks_a_note_private_under_its_permission
    added = state(call_tool('add_issue_note', { 'issue' => 1, 'notes' => 'Between us', 'private_notes' => true }))
    assert Journal.find(added['journal_id']).private_notes?

    without_permission(:set_notes_private)
    assert_match 'do not have permission', refusal(call_tool('add_issue_note', { 'issue' => 1, 'notes' => 'Again',
                                                                                 'private_notes' => true }))
    assert_match 'notes must not be empty', refusal(call_tool('add_issue_note', { 'issue' => 1, 'notes' => '  ' }))
  end

  def test_update_issue_note_makes_a_note_private
    Role.find(1).add_permission!(:edit_own_issue_notes)
    journal = Journal.create!(journalized: Issue.find(1), user: User.find(2), notes: 'Public so far')

    updated = state(call_tool('update_issue_note', { 'journal' => journal.id, 'notes' => 'Private now', 'private_notes' => true }))
    assert updated['private_notes']
    assert journal.reload.private_notes?
    assert_equal 'Private now', journal.notes
  end

  def test_log_time_refuses_a_date_it_cannot_read
    text = refusal(call_tool('log_time', { 'project' => 'ecookbook', 'hours' => 1, 'activity' => 'Design',
                                           'spent_on' => 'yesterday' }))
    assert_match 'spent_on must be an ISO-8601 date', text
  end

  # --- relations ----------------------------------------------------------------------

  def test_update_issue_relations_adds_a_relation_seen_from_the_issue
    result = state(call_tool('update_issue_relations', { 'issue' => 1, 'add' => [{ 'issue' => 7, 'relation_type' => 'relates' }] }))

    assert_equal 1, result['issue_id']
    assert_includes result['relations'], { 'relation_type' => 'relates', 'issue' => 7 }
    assert IssueRelation.exists?(issue_from_id: 1, issue_to_id: 7, relation_type: 'relates')
  end

  def test_update_issue_relations_keeps_a_delay_on_precedes
    result = state(call_tool('update_issue_relations', { 'issue' => 1, 'add' => [{ 'issue' => 7, 'relation_type' => 'precedes',
                                                                                   'delay' => 2 }] }))
    assert_includes result['relations'], { 'relation_type' => 'precedes', 'issue' => 7, 'delay' => 2 }
  end

  def test_update_issue_relations_removes_every_relation_with_an_issue
    assert IssueRelation.exists?(issue_from_id: 2, issue_to_id: 3)

    result = state(call_tool('update_issue_relations', { 'issue' => 2, 'remove' => [3] }))
    assert_empty(result['relations'].select { |row| row['issue'] == 3 })
    assert_not IssueRelation.exists?(issue_from_id: 2, issue_to_id: 3)
  end

  def test_update_issue_relations_names_what_it_refuses_and_changes_nothing
    assert_match 'Pass add or remove', refusal(call_tool('update_issue_relations', { 'issue' => 1 }))
    assert_match 'Each add entry is', refusal(call_tool('update_issue_relations', { 'issue' => 1, 'add' => [{ 'issue' => 7 }] }))

    assert_no_difference 'IssueRelation.count' do
      text = refusal(call_tool('update_issue_relations', {
                                 'issue' => 1, 'remove' => [7],
                                 'add' => [{ 'issue' => 3, 'relation_type' => 'relates', 'delay' => 2 },
                                           { 'issue' => 1, 'relation_type' => 'relates' }]
                               }))
      assert_match 'remove (7 is not related to #1)', text
      assert_match 'delay is only for precedes and follows', text
      assert_match 'relates 1: ', text
    end
  end

  def test_update_issue_relations_refuses_a_relation_that_exists
    assert_no_difference 'IssueRelation.count' do
      text = refusal(call_tool('update_issue_relations', { 'issue' => 2, 'add' => [{ 'issue' => 3, 'relation_type' => 'relates' }] }))
      assert_match 'add (relates 3: ', text
    end
  end

  def test_update_issue_relations_needs_manage_issue_relations
    without_permission(:manage_issue_relations)
    post_mcp rpc('tools/call', { 'name' => 'update_issue_relations', 'arguments' => { 'issue' => 1, 'remove' => [3] } }),
             api_key_headers(User.find(2))
    assert_match 'Unknown tool', json_body.dig('error', 'message')
  end

  def test_update_issue_relations_refuses_a_token_without_the_scope_or_the_view
    arguments = { 'issue' => 2, 'remove' => [3] }

    hidden = call_with_scopes('view_project view_issues', 'update_issue_relations', arguments)
    assert_match 'Unknown tool', hidden.dig('error', 'message')

    blind = call_with_scopes('view_project manage_issue_relations', 'update_issue_relations', arguments)
    assert_match 'No visible issue', refusal(blind['result'])
    assert IssueRelation.exists?(issue_from_id: 2, issue_to_id: 3)
  end
  # --- redmineup_tags ---------------------------------------------------------------------

  # Without the plugin its parameters are not in the schema at all.
  def test_tag_parameters_do_not_exist_without_the_plugin
    text = refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['urgent'] }))
    assert_match 'Unknown argument: "add_tag_list"', text
  end

  # --- the shape of an argument ---------------------------------------------------------------

  def test_an_array_argument_must_be_an_array_of_what_it_declares
    assert_match 'add_watcher_users must be an array, got 3',
                 refusal(call_tool('update_issue', { 'issue' => 1, 'add_watcher_users' => 3 }))
    assert_match 'add_watcher_users[0] must be an integer or a string, got an object',
                 refusal(call_tool('update_issue', { 'issue' => 1, 'add_watcher_users' => [{ 'id' => 3 }] }))
    assert_match 'add must be an array', refusal(call_tool('update_issue_relations', { 'issue' => 1, 'add' => 'relates 7' }))
    assert_match 'add[0] must be an object, got 7', refusal(call_tool('update_issue_relations', { 'issue' => 1, 'add' => [7] }))
    assert_empty Issue.find(1).watcher_user_ids
  end

  def test_an_object_argument_must_be_an_object
    text = refusal(call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Shape',
                                               'custom_field_values' => 'MySQL' }))
    assert_match 'custom_field_values must be an object, got "MySQL"', text
  end
end
