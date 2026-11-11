# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require File.expand_path('../support/plugin_stand_ins', __dir__)

# The tools that reach into redmine_checklists and redmineup_tags, over
# stand-ins for the two plugins: see test/support/plugin_stand_ins.rb for what
# that proves and what it does not.
class McpPluginIntegrationsTest < Redmine::ControllerTest
  include McpTestHelper
  include McpPluginStandIns

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :issue_categories, :trackers, :enumerations, :enabled_modules,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :versions, :journals, :journal_details, :watchers

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
    Role.find(1).add_permission!(*CHECKLIST_PERMISSIONS, *TAG_PERMISSIONS, *ISSUE_TAG_PERMISSIONS)
    Checklist.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM mcp_stand_in_tags') unless REAL_ADDITIONAL_TAGS
    issue_tags_active!(true)
  end

  def teardown
    checklist_done_ratio!(false)
    issue_tags_active!(false)
    Setting.clear_cache
    User.current = nil
  end

  def without_permission(*permissions)
    Role.find_each { |role| permissions.each { |permission| role.remove_permission!(permission) } }
  end

  def tool_names
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    json_body['result']['tools'].map { |tool| tool['name'] }
  end

  def item(subject, attributes = {})
    Checklist.create!({ issue_id: 1, subject: subject, position: Checklist.where(issue_id: 1).count + 1 }.merge(attributes))
  end

  # --- what is served ---------------------------------------------------------

  def test_the_checklist_tool_exists_only_with_its_plugin
    with_plugin { assert_not_includes tool_names, 'update_issue_checklists' }
    with_plugin(:redmine_checklists) { assert_includes tool_names, 'update_issue_checklists' }
  end

  def test_the_tag_parameters_exist_only_with_their_plugin
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    properties = lambda do
      post_mcp rpc('tools/list'), api_key_headers(User.find(2))
      json_body['result']['tools'].detect { |tool| tool['name'] == 'update_issue' }['inputSchema']['properties'].keys
    end

    with_plugin { assert_not_includes properties.call, 'add_tag_list' }
    with_plugin(:redmineup_tags) { assert_includes properties.call, 'add_tag_list' }
  end

  # A plugin that no longer has what the tools call is treated as absent.
  def test_a_plugin_whose_contract_is_broken_is_not_served
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    RedmineMcpPlugin::Integrations.stubs(:listener?).returns(false)
    with_plugin(:redmine_checklists, :redmineup_tags) do
      assert_not_includes tool_names, 'update_issue_checklists'
      assert_match 'Unknown argument: "add_tag_list"', refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['x'] }))
      assert_not state(call_tool('get_issue', { 'issue' => 1 })).key?('tag_list')
    end
  end

  # --- checklists -----------------------------------------------------------------

  def test_update_issue_checklists_adds_ticks_unticks_and_renames
    draft  = item('Draft')
    review = item('Review')
    sent   = item('Sent', is_done: true)

    with_plugin(:redmine_checklists) do
      result = state(call_tool('update_issue_checklists', {
                                 'issue' => 1, 'add' => ['Ship'], 'done' => [draft.id], 'undone' => [sent.id.to_s],
                                 'rename' => [{ 'checklist' => review.id, 'subject' => 'Peer review' }]
                               }))

      assert_equal 1, result['issue_id']
      assert_equal(['Draft', 'Peer review', 'Sent', 'Ship'], result['checklists'].map { |row| row['subject'] })
      assert_equal([true, false, false, false], result['checklists'].map { |row| row['is_done'] })
      assert draft.reload.is_done
      assert_not sent.reload.is_done

      issue = state(call_tool('get_issue', { 'issue' => 1 }))
      assert_equal 4, issue['checklists'].size
      next unless checklists_journaled?

      change = issue['journals'].last['details'].detect { |detail| detail['name'] == 'checklist' }
      assert_equal ['Ship'], change['added']
      assert_equal ['Draft'], change['done']
      assert_equal ['Sent'], change['undone']
      assert_equal [{ 'from' => 'Review', 'to' => 'Peer review' }], change['renamed']
    end
  end

  # The light edition's diff names what was ticked and unticked, nothing else:
  # a key it lacks reads as no change of that kind, not as a failure.
  def test_get_issue_reads_a_history_diff_that_names_only_ticks
    journal = Journal.create!(journalized: Issue.find(1), user: User.find(2), notes: 'Ticked')
    journal.details.create!(property: 'attr', prop_key: 'checklist',
                            old_value: [{ id: 1, subject: 'Draft', is_done: false }].to_json,
                            value: [{ id: 1, subject: 'Draft', is_done: true }].to_json)
    ticked = Struct.new(:subject).new('Draft')
    JournalChecklistHistory.any_instance.stubs(:diff).returns({ done: [ticked], undone: [] })

    with_plugin(:redmine_checklists) do
      details = state(call_tool('get_issue', { 'issue' => 1 }))['journals'].detect { |row| row['id'] == journal.id }['details']
      assert_equal [{ 'property' => 'attr', 'name' => 'checklist', 'done' => ['Draft'] }], details
    end
  end

  def test_update_issue_checklists_names_what_it_refuses_and_changes_nothing
    draft   = item('Draft')
    section = item('Phase one', is_section: true)

    with_plugin(:redmine_checklists) do
      assert_match 'Pass add, done, undone or rename', refusal(call_tool('update_issue_checklists', { 'issue' => 1 }))

      text = refusal(call_tool('update_issue_checklists', {
                                 'issue' => 1, 'done' => [999_999, section.id], 'undone' => [888_888],
                                 'rename' => [{ 'checklist' => draft.id, 'subject' => ' ' }, { 'checklist' => 777_777, 'subject' => 'x' },
                                              {}]
                               }))
      assert_match 'done (999999 is not an item of #1', text
      assert_match "#{section.id} is not an item of #1", text
      assert_match 'undone (888888 is not an item of #1)', text
      assert_match "checklist #{draft.id} needs a subject", text
      assert_match '777777 is not an item of #1', text
      assert_match 'nil is not an item of #1', text
      assert_not draft.reload.is_done
    end
  end

  # Ticking needs either permission; adding and renaming need edit_checklists.
  def test_done_checklists_alone_ticks_and_does_not_edit
    draft = item('Draft')
    without_permission(:edit_checklists)

    with_plugin(:redmine_checklists) do
      text = refusal(call_tool('update_issue_checklists', { 'issue' => 1, 'add' => ['Ship'],
                                                            'rename' => [{ 'checklist' => draft.id, 'subject' => 'x' }] }))
      assert_match 'add (needs ', text
      assert_match 'rename (needs ', text
      assert_equal 1, Checklist.count

      state(call_tool('update_issue_checklists', { 'issue' => 1, 'done' => [draft.id] }))
      assert draft.reload.is_done
    end
  end

  def test_the_checklist_tool_needs_one_of_its_permissions
    item('Draft')
    without_permission(:edit_checklists, :done_checklists)

    with_plugin(:redmine_checklists) do
      post_mcp rpc('tools/call', { 'name' => 'update_issue_checklists', 'arguments' => { 'issue' => 1, 'add' => ['x'] } }),
               api_key_headers(User.find(2))
      assert_match 'Unknown tool', json_body.dig('error', 'message')
    end
  end

  # The role holds the permission in another project only: the tool is listed, the issue refuses.
  def test_the_checklist_permission_is_checked_on_the_issues_project
    item('Draft')
    without_permission(:edit_checklists, :done_checklists)
    Role.find(2).add_permission!(:edit_checklists)

    with_plugin(:redmine_checklists) do
      assert_match 'do not have permission', refusal(call_tool('update_issue_checklists', { 'issue' => 1, 'add' => ['x'] }))
    end
  end

  def test_get_issue_leaves_the_checklist_out_without_view_checklists
    draft = item('Draft')

    with_plugin(:redmine_checklists) do
      state(call_tool('update_issue_checklists', { 'issue' => 1, 'done' => [draft.id] }))
      assert state(call_tool('get_issue', { 'issue' => 1 })).key?('checklists')

      without_permission(:view_checklists)
      issue = state(call_tool('get_issue', { 'issue' => 1 }))
      assert_not issue.key?('checklists')
      assert_empty(issue['journals'].flat_map { |journal| journal['details'] }.select { |detail| detail['name'] == 'checklist' })
    end
  end

  # The plugin's first versions journaled text the diff cannot read: it is shown as it is.
  def test_get_issue_shows_an_old_checklist_detail_as_text
    journal = Journal.create!(journalized: Issue.find(1), user: User.find(2), notes: 'Ticked')
    journal.details.create!(property: 'attr', prop_key: 'checklist', old_value: '[ ] Draft', value: '[x] Draft')

    with_plugin(:redmine_checklists) do
      details = state(call_tool('get_issue', { 'issue' => 1 }))['journals'].detect { |row| row['id'] == journal.id }['details']
      assert_equal [{ 'property' => 'attr', 'name' => 'checklist', 'old_value' => '[ ] Draft', 'new_value' => '[x] Draft' }], details
    end
  end

  def test_the_done_ratio_belongs_to_the_checklist_once_the_plugin_computes_it
    draft = item('Draft')
    item('Review')
    checklist_done_ratio!(true)

    with_plugin(:redmine_checklists) do
      assert_match 'done_ratio (computed from the checklist by redmine_checklists)',
                   refusal(call_tool('update_issue', { 'issue' => 1, 'done_ratio' => 80 }))

      fields = state(call_tool('get_issue_fields', { 'issue' => 1 }))
      assert_equal 'checklist', fields['done_ratio_computed_from']
      assert_equal false, fields['done_ratio_field']
      assert_equal({ 'edit' => true, 'done' => true }, fields['checklists'])

      fresh = state(call_tool('get_issue_fields', { 'project' => 'ecookbook', 'tracker' => 'Bug' }))
      assert_match 'redmine_checklists computes it once the issue has checklist items', fresh['done_ratio_note']

      state(call_tool('update_issue_checklists', { 'issue' => 1, 'done' => [draft.id] }))
      assert_equal 50, Issue.find(1).done_ratio
    end
  end

  # With no item yet the field is still the issue's own.
  def test_the_done_ratio_stays_a_field_on_an_issue_with_no_item
    checklist_done_ratio!(true)

    with_plugin(:redmine_checklists) do
      assert_equal 80, state(call_tool('update_issue', { 'issue' => 1, 'done_ratio' => 80 }))['done_ratio']
    end
  end

  # --- tags -------------------------------------------------------------------------

  def test_create_issue_sets_tags_and_get_issue_returns_them
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    with_plugin(:redmineup_tags) do
      created = state(call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Tagged',
                                                  'tag_list' => %w[urgent billing] }))
      assert_equal %w[urgent billing], created['tag_list']
      assert_equal %w[urgent billing], state(call_tool('get_issue', { 'issue' => created['id'] }))['tag_list']
    end
  end

  def test_update_issue_adds_and_removes_tags_and_journals_the_change
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    with_plugin(:redmineup_tags) do
      state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => %w[urgent billing] }))
      updated = state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['legal'], 'remove_tag_list' => ['billing'] }))

      assert_equal %w[urgent legal], updated['tag_list']
      detail = Journal.find(updated['journal_id']).details.detect { |row| row.prop_key == 'tag_list' }
      assert_equal 'urgent, billing', detail.old_value
      assert_equal 'urgent, legal', detail.value
    end
  end

  def test_tags_need_edit_tags_and_a_new_tag_needs_create_tags
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    with_plugin(:redmineup_tags) do
      state(call_tool('update_issue', { 'issue' => 2, 'add_tag_list' => ['known'] }))

      without_permission(:create_tags)
      text = refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => %w[known brand-new] }))
      assert_match 'add_tag_list (new tags need ', text
      assert_match 'brand-new', text
      assert_not_includes text, 'known,'
      assert_equal ['known'], state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['known'] }))['tag_list']

      without_permission(:edit_tags)
      text = refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['known'], 'remove_tag_list' => ['old'] }))
      assert_match 'add_tag_list (needs ', text
      assert_match 'remove_tag_list (needs ', text
    end
  end

  def test_get_issue_fields_lists_the_tags_and_what_the_caller_may_do_with_them
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    with_plugin(:redmineup_tags) do
      state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => %w[urgent billing] }))
      tags = state(call_tool('get_issue_fields', { 'issue' => 1 }))['tags']

      assert_equal({ 'edit' => true, 'create' => true, 'available' => %w[billing urgent], 'truncated' => false }, tags)
    end
  end

  def test_both_plugins_at_once
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    draft = item('Draft')

    with_plugin(:redmine_checklists, :redmineup_tags) do
      state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['urgent'], 'notes' => 'Tagged' }))
      state(call_tool('update_issue_checklists', { 'issue' => 1, 'done' => [draft.id] }))
      issue = state(call_tool('get_issue', { 'issue' => 1 }))

      assert_equal ['urgent'], issue['tag_list']
      assert_equal([true], issue['checklists'].map { |row| row['is_done'] })
    end
  end

  # --- additional_tags: other permissions, tag_list alone, tags behind a setting ---------

  def test_additional_tags_serves_the_same_parameters
    with_plugin(:additional_tags) do
      post_mcp rpc('tools/list'), api_key_headers(User.find(2))
      tools = json_body['result']['tools'].to_h { |tool| [tool['name'], tool['inputSchema']['properties'].to_h.keys] }

      assert_includes tools['create_issue'], 'tag_list'
      assert_includes tools['update_issue'], 'add_tag_list'
      assert_includes tools['update_issue'], 'remove_tag_list'
    end
  end

  def test_additional_tags_sets_reads_adds_and_removes
    with_plugin(:additional_tags) do
      created = state(call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Tagged',
                                                  'tag_list' => %w[urgent billing] }))
      assert_equal %w[billing urgent], created['tag_list'].sort

      updated = state(call_tool('update_issue', { 'issue' => created['id'], 'add_tag_list' => ['legal'],
                                                  'remove_tag_list' => ['billing'] }))
      assert_equal %w[legal urgent], updated['tag_list'].sort
      assert_equal %w[legal urgent], Issue.find(created['id']).tag_list.to_a.sort
      assert_equal %w[legal urgent], state(call_tool('get_issue', { 'issue' => created['id'] }))['tag_list'].sort
    end
  end

  def test_additional_tags_checks_its_own_permissions
    with_plugin(:additional_tags) do
      state(call_tool('update_issue', { 'issue' => 2, 'add_tag_list' => ['known'] }))

      without_permission(:create_issue_tags)
      text = refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => %w[known brand-new] }))
      assert_match 'add_tag_list (new tags need ', text
      assert_match 'brand-new', text
      assert_equal ['known'], state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['known'] }))['tag_list']

      without_permission(:edit_issue_tags)
      assert_match 'add_tag_list (needs ', refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['known'] }))
      assert_equal ['known'], Issue.find(1).tag_list.to_a
    end
  end

  # Reading tags is a permission of its own in additional_tags.
  def test_additional_tags_are_read_only_under_view_issue_tags
    with_plugin(:additional_tags) do
      state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['urgent'] }))
      assert_equal ['urgent'], state(call_tool('get_issue', { 'issue' => 1 }))['tag_list']

      without_permission(:view_issue_tags)
      assert_not state(call_tool('get_issue', { 'issue' => 1 })).key?('tag_list')
    end
  end

  def test_additional_tags_lists_the_tags_and_what_the_caller_may_do
    with_plugin(:additional_tags) do
      state(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => %w[urgent billing] }))
      tags = state(call_tool('get_issue_fields', { 'issue' => 1 }))['tags']

      assert tags['edit']
      assert tags['create']
      assert_equal %w[billing urgent], tags['available'].sort
      assert_equal false, tags['truncated']
    end
  end

  # With the plugin's switch off it ignores every tag: said, not silently dropped.
  def test_additional_tags_switched_off_refuses_tags_and_shows_none
    issue_tags_active!(false)

    with_plugin(:additional_tags) do
      text = refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['urgent'] }))
      assert_match 'add_tag_list (issue tags are switched off in the additional_tags settings)', text
      assert_not state(call_tool('get_issue', { 'issue' => 1 })).key?('tag_list')
      assert_not state(call_tool('get_issue_fields', { 'issue' => 1 })).key?('tags')
    end
  end

  # With both tags plugins there, the first the server knows is the one it talks to.
  def test_redmineup_tags_wins_when_both_tags_plugins_are_installed
    skip 'redmineup_tags has no stand-in beside the real additional_tags' if REAL_ADDITIONAL_TAGS

    with_plugin(:redmineup_tags, :additional_tags) do
      assert_equal :redmineup_tags, RedmineMcpPlugin::Integrations.tags_plugin
      without_permission(:edit_tags)
      assert_match 'add_tag_list (needs ', refusal(call_tool('update_issue', { 'issue' => 1, 'add_tag_list' => ['x'] }))
    end
  end
end
