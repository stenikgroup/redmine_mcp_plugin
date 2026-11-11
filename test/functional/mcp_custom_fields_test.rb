# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Custom fields across the tools: the values a write accepts, the labels a read
# gives, and the fields an administrator excludes.
class McpCustomFieldsTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :watchers,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :time_entries, :versions, :journals, :journal_details,
           :queries

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('enabled' => '1')
    User.current = nil
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  # --- custom field values --------------------------------------------------

  # log_time needs the time entry custom fields before its first call, as
  # get_issue_fields gives an issue's: required flag and allowed values.
  def test_list_enumerations_with_project_lists_time_entry_custom_fields
    CustomField.find(10).update!(is_required: true)
    result = call_tool('list_enumerations', { 'project' => 'ecookbook' })
    field  = result['structuredContent']['time_entry_custom_fields'].detect { |f| f['id'] == 10 }
    assert field, result.inspect
    assert field['required']
    assert_equal(%w[1 0], field['possible_values'].map { |v| v['value'] })
  end

  def test_list_enumerations_without_project_has_no_time_entry_custom_fields
    result = call_tool('list_enumerations', {})
    assert_not result['structuredContent'].key?('time_entry_custom_fields')
  end

  def test_log_time_names_a_missing_required_custom_field_with_its_values
    enable_mcp('read_only' => '0')
    CustomField.find(10).update!(is_required: true, default_value: '')
    assert_no_difference 'TimeEntry.count' do
      result = call_tool('log_time', { 'project' => 'ecookbook', 'hours' => 1, 'activity' => 'Design' })
      assert result['isError'], result.inspect
      assert_match(/Overtime \(id 10\) is required; accepts 1 \(.+\), 0 \(.+\)/, result['content'].first['text'])
    end
  end

  def test_log_time_accepts_true_for_a_bool_custom_field
    enable_mcp('read_only' => '0')
    CustomField.find(10).update!(is_required: true, default_value: '')
    result = call_tool('log_time', { 'project' => 'ecookbook', 'hours' => 1, 'activity' => 'Design',
                                     'custom_field_values' => { '10' => 'true' } })
    assert_not result['isError'], result.inspect
    assert_equal '1', TimeEntry.find(result['structuredContent']['id']).custom_field_value(CustomField.find(10))
  end

  def test_create_issue_resolves_a_custom_field_label
    enable_mcp('read_only' => '0')
    result = call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Label',
                                         'custom_field_values' => { '1' => 'postgresql' } })
    assert_not result['isError'], result.inspect
    assert_equal 'PostgreSQL', Issue.find(result['structuredContent']['id']).custom_field_value(CustomField.find(1))
  end

  def test_create_issue_refuses_an_unknown_custom_field_value_with_the_choices
    enable_mcp('read_only' => '0')
    assert_no_difference 'Issue.count' do
      result = call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Bad',
                                           'custom_field_values' => { '1' => 'Sybase' } })
      assert result['isError'], result.inspect
      assert_match(/Database \(id 1\) has no value "Sybase"; accepts "MySQL", "PostgreSQL", "Oracle"/,
                   result['content'].first['text'])
    end
  end

  def test_create_issue_names_a_missing_required_custom_field
    enable_mcp('read_only' => '0')
    CustomField.find(1).update!(is_required: true)
    assert_no_difference 'Issue.count' do
      result = call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Missing' })
      assert result['isError'], result.inspect
      assert_match(/custom_field_values \(custom field Database \(id 1\) is required; accepts "MySQL"/,
                   result['content'].first['text'])
    end
  end

  # Core reads the workflow rules of the status being set, at every save.
  def test_update_issue_names_a_custom_field_the_new_status_requires
    enable_mcp('read_only' => '0')
    WorkflowPermission.create!(tracker_id: 1, old_status_id: 2, role_id: 1, field_name: '1', rule: 'required')
    result = call_tool('update_issue', { 'issue' => 1, 'status' => 'Assigned' })
    assert result['isError'], result.inspect
    assert_match(/custom_field_values \(custom field Database \(id 1\) is required; accepts "MySQL"/,
                 result['content'].first['text'])
    assert_equal 1, Issue.find(1).status_id
  end

  def test_create_issue_names_a_custom_field_the_status_requires
    enable_mcp('read_only' => '0')
    WorkflowPermission.create!(tracker_id: 1, old_status_id: 2, role_id: 1, field_name: '1', rule: 'required')
    assert_no_difference 'Issue.count' do
      result = call_tool('create_issue', { 'project' => 'ecookbook', 'tracker' => 'Bug', 'subject' => 'Assigned',
                                           'status' => 'Assigned' })
      assert result['isError'], result.inspect
      assert_match(/custom field Database \(id 1\) is required/, result['content'].first['text'])
    end
  end

  # A tracker move makes core recheck every custom field, flag included.
  def test_update_issue_names_a_required_custom_field_left_blank_by_a_tracker_move
    enable_mcp('read_only' => '0')
    issue = Issue.find(1)
    issue.custom_field_values = { '6' => '' }
    issue.save!
    CustomField.find(6).update!(is_required: true)
    result = call_tool('update_issue', { 'issue' => 1, 'tracker' => 'Feature request' })
    assert result['isError'], result.inspect
    assert_match(/custom field Float field \(id 6\) is required/, result['content'].first['text'])
    assert_equal 1, Issue.find(1).tracker_id
  end

  # Without a status, tracker or custom field change core does not recheck the flag, and neither does this.
  def test_update_issue_leaves_a_blank_required_custom_field_alone_when_nothing_rechecks_it
    enable_mcp('read_only' => '0')
    issue = Issue.find(1)
    issue.custom_field_values = { '6' => '' }
    issue.save!
    CustomField.find(6).update!(is_required: true)
    result = call_tool('update_issue', { 'issue' => 1, 'subject' => 'Untouched' })
    assert_not result['isError'], result.inspect
    assert_equal 'Untouched', Issue.find(1).subject
  end

  # Core accepts the value already stored even once it is no longer offered.
  def test_update_issue_keeps_a_stored_value_no_longer_offered
    enable_mcp('read_only' => '0')
    issue = Issue.find(1)
    issue.custom_field_values = { '1' => 'MySQL' }
    issue.save!
    CustomField.find(1).update!(possible_values: %w[PostgreSQL Oracle])
    result = call_tool('update_issue', { 'issue' => issue.id, 'custom_field_values' => { '1' => 'MySQL' } })
    assert_not result['isError'], result.inspect
  end

  # --- project custom fields -----------------------------------------------

  def project_custom_fields(row)
    row['custom_fields'].to_h { |field| [field['id'], field['value']] }
  end

  def test_get_project_returns_its_custom_fields
    result = call_tool('get_project', { 'project' => 'ecookbook' })
    assert_not result['isError'], result.inspect
    assert_equal({ 3 => 'Stable' }, project_custom_fields(result['structuredContent']))
  end

  # A field restricted to roles the caller does not hold there is hidden, as on the project page.
  def test_get_project_leaves_out_a_field_restricted_to_another_role
    CustomField.find(3).update!(visible: false, role_ids: [Role.find(3).id])
    result = call_tool('get_project', { 'project' => 'ecookbook' })
    assert_not result['isError'], result.inspect
    assert_empty result['structuredContent']['custom_fields']
  end

  def test_list_projects_leaves_custom_fields_out_by_default
    result = call_tool('list_projects', {})
    assert(result['structuredContent']['projects'].none? { |row| row.key?('custom_fields') })
  end

  # Restricted to Non member: user 2 sees it on the public projects they are not a member of only.
  def test_list_projects_applies_field_roles_per_project
    CustomField.find(3).update!(visible: false, role_ids: [Role.non_member.id])
    rows = call_tool('list_projects', { 'include_custom_fields' => true })['structuredContent']['projects']
    shown = rows.select { |row| project_custom_fields(row).key?(3) }.map { |row| row['id'] }
    expected = rows.map { |row| Project.find(row['id']) }
                   .select { |project| CustomField.find(3).visible_by?(project, User.find(2)) }.map(&:id)
    assert_equal expected.sort, shown.sort
    assert_includes shown, 3
    assert_not_includes shown, 1
  end

  def test_list_projects_with_custom_fields_does_not_query_per_project
    CustomField.find(3).update!(visible: false, role_ids: [Role.non_member.id])
    queries = lambda do |limit|
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA CACHE].include?(payload[:name]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        call_tool('list_projects', { 'include_custom_fields' => true, 'limit' => limit })
      end
      count
    end
    queries.call(1) # warm the settings and role caches
    assert_operator Project.visible(User.find(2)).count, :>, 2
    # Two rows, so both pages hold a subproject and pay the one query for the parents.
    assert_equal queries.call(2), queries.call(100)
  end

  # --- custom field labels -------------------------------------------------

  # A project field per id-based format. CustomValue rows are written directly:
  # core's validation would refuse a user who is not a project member, which
  # is the case the visibility rule is about.
  def labelled_project_fields
    health = ProjectCustomField.create!(name: 'Health', field_format: 'enumeration', visible: true)
    green  = health.enumerations.create!(name: 'Green', position: 1)
    red    = health.enumerations.create!(name: 'Red', position: 2)
    team   = ProjectCustomField.create!(name: 'Team', field_format: 'user', multiple: true, visible: true)
    target = ProjectCustomField.create!(name: 'Target', field_format: 'version', visible: true)
    { health: health, green: green, red: red, team: team, target: target }
  end

  def store_value(project, field, value)
    CustomValue.create!(custom_field: field, customized: project, value: value.to_s)
  end

  def project_custom_field(row, field)
    row['custom_fields'].detect { |f| f['id'] == field.id }
  end

  def test_get_project_names_enumeration_user_and_version_values
    f = labelled_project_fields
    project = Project.find(1)
    store_value(project, f[:health], f[:green].id)
    store_value(project, f[:team], 2)
    store_value(project, f[:team], 3)
    store_value(project, f[:target], 2)

    row = call_tool('get_project', { 'project' => 'ecookbook' })['structuredContent']
    assert_equal({ 'id' => f[:health].id, 'name' => 'Health', 'format' => 'enumeration',
                   'value' => f[:green].id.to_s, 'label' => 'Green' }, project_custom_field(row, f[:health]))
    team = project_custom_field(row, f[:team])
    assert_equal %w[2 3], team['value'].sort
    assert_equal team['value'].map { |id| User.find(id).name }, team['label']
    assert_equal ['2', '1.0'], project_custom_field(row, f[:target]).values_at('value', 'label')
    # A list field stores the label itself, so it gets none.
    assert_not project_custom_field(row, CustomField.find(3)).key?('label')
    assert_equal 'list', project_custom_field(row, CustomField.find(3))['format']
  end

  def test_get_project_leaves_unnamed_a_deleted_or_invisible_target
    f = labelled_project_fields
    project = Project.find(1)
    store_value(project, f[:health], f[:red].id)
    store_value(project, f[:team], 2)
    store_value(project, f[:team], 5) # locked, so outside Principal.visible for user 2
    store_value(project, f[:target], 999)
    CustomFieldEnumeration.where(id: f[:red].id).delete_all

    row = call_tool('get_project', { 'project' => 'ecookbook' })['structuredContent']
    assert_equal [f[:red].id.to_s, nil], project_custom_field(row, f[:health]).values_at('value', 'label')
    team = project_custom_field(row, f[:team])
    assert_equal({ '2' => User.find(2).name, '5' => nil }, team['value'].zip(team['label']).to_h)
    assert_equal ['999', nil], project_custom_field(row, f[:target]).values_at('value', 'label')
  end

  # Core still shows a value it no longer offers; so does the label.
  def test_get_project_names_an_inactive_enumeration
    f = labelled_project_fields
    store_value(Project.find(1), f[:health], f[:green].id)
    f[:green].update!(active: false)
    row = call_tool('get_project', { 'project' => 'ecookbook' })['structuredContent']
    assert_equal 'Green', project_custom_field(row, f[:health])['label']
  end

  def test_list_projects_labels_do_not_query_per_project
    CustomField.find(3).update!(visible: false, role_ids: [Role.non_member.id])
    f = labelled_project_fields
    Project.all.each do |project|
      store_value(project, f[:health], f[:green].id)
      store_value(project, f[:team], 2)
      store_value(project, f[:team], 3)
      store_value(project, f[:target], 2)
    end
    queries = lambda do |limit|
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA CACHE].include?(payload[:name]) || payload[:cached] }
      rows = nil
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        rows = call_tool('list_projects', { 'include_custom_fields' => true, 'limit' => limit })['structuredContent']['projects']
      end
      assert(rows.all? { |row| project_custom_field(row, f[:health])['label'] == 'Green' })
      count
    end
    queries.call(1) # warm the settings and role caches
    assert_operator Project.visible(User.find(2)).count, :>, 2
    # Two rows, so both pages hold a subproject and pay the one query for the parents.
    assert_equal queries.call(2), queries.call(100)
  end

  # The write tools read back the saved fields through the same row.
  def test_update_issue_names_a_saved_user_custom_field
    enable_mcp('read_only' => '0')
    field  = IssueCustomField.create!(name: 'Reviewer', field_format: 'user', is_for_all: true, tracker_ids: [1])
    result = call_tool('update_issue', { 'issue' => 1, 'custom_field_values' => { field.id.to_s => '2' } })
    assert_not result['isError'], result.inspect
    saved = result['structuredContent']['custom_fields'].detect { |f| f['id'] == field.id }
    assert_equal ['2', User.find(2).name], saved.values_at('value', 'label')
  end

  # The history names a value stored as an id, as the custom field row does.
  def test_get_issue_names_a_custom_field_change_in_the_history
    enable_mcp('read_only' => '0')
    field = IssueCustomField.create!(name: 'Reviewer', field_format: 'user', is_for_all: true, tracker_ids: [1])
    call_tool('update_issue', { 'issue' => 1, 'custom_field_values' => { field.id.to_s => '2' } })
    Issue.find(1).journals.last.details.create!(property: 'cf', prop_key: field.id.to_s, old_value: '2', value: '999')

    journals = call_tool('get_issue', { 'issue' => 1 })['structuredContent']['journals']
    changes  = journals.flat_map { |journal| journal['details'] }.select { |detail| detail['name'] == 'Reviewer' }
    name     = User.find(2).name
    assert_equal([[nil, name], [name, '999']], changes.map { |c| c.values_at('old_value', 'new_value') })
  end

  # Core lists the caller twice in a user field: as "<< me >>" and by name.
  def test_get_issue_fields_lists_each_user_once
    field  = IssueCustomField.create!(name: 'Reviewer', field_format: 'user', is_for_all: true, tracker_ids: [1])
    fields = call_tool('get_issue_fields', { 'issue' => 1 })['structuredContent']['custom_fields']
    values = fields.detect { |f| f['id'] == field.id }['possible_values']
    ids    = values.map { |v| v['value'] }
    assert_equal ids.uniq, ids
    assert_equal User.find(2).name, values.detect { |v| v['value'] == '2' }['label']
  end

  # --- excluded custom fields ----------------------------------------------

  def exclude_custom_fields(*ids)
    enable_mcp('excluded_custom_fields' => ['', *ids.map(&:to_s)])
  end

  def custom_field_ids_in(rows)
    Array(rows).map { |row| row['id'] }
  end

  # Issue 1 holds a value for field 2; journal 3, on issue 2, records a change to it.
  def test_get_issue_leaves_out_an_excluded_field_and_its_history
    history = lambda do
      fields  = call_tool('get_issue', { 'issue' => 1 })['structuredContent']['custom_fields']
      journal = call_tool('get_issue', { 'issue' => 2 })['structuredContent']['journals']
      [custom_field_ids_in(fields), journal.flat_map { |entry| entry['details'] }.select { |d| d['property'] == 'cf' }]
    end
    fields, details = history.call
    assert_includes fields, 2
    assert details.any?, 'journal 3 should record a change to field 2'

    exclude_custom_fields(2)
    fields, details = history.call
    assert_not_includes fields, 2
    assert_empty details
  end

  def test_project_tools_leave_out_an_excluded_field
    exclude_custom_fields(3)
    assert_empty call_tool('get_project', { 'project' => 'ecookbook' })['structuredContent']['custom_fields']
    rows = call_tool('list_projects', { 'include_custom_fields' => true })['structuredContent']['projects']
    assert(rows.all? { |row| row['custom_fields'].empty? })
  end

  def test_time_entry_tools_leave_out_an_excluded_field
    entries = -> { call_tool('list_time_entries', { 'project' => 'ecookbook' })['structuredContent']['entries'] }
    assert(entries.call.any? { |row| custom_field_ids_in(row['custom_fields']).include?(10) })
    exclude_custom_fields(10)
    rows = entries.call
    assert rows.any?
    assert(rows.none? { |row| custom_field_ids_in(row['custom_fields']).include?(10) })
    fields = call_tool('list_enumerations', { 'project' => 'ecookbook' })['structuredContent']['time_entry_custom_fields']
    assert_not_includes custom_field_ids_in(fields), 10
  end

  # Neither offered nor accepted: setting it is refused as a field that cannot be set here.
  def test_an_excluded_field_cannot_be_set
    enable_mcp('read_only' => '0', 'excluded_custom_fields' => ['2'])
    fields = call_tool('get_issue_fields', { 'issue' => 1 })['structuredContent']['custom_fields']
    assert_not_includes custom_field_ids_in(fields), 2
    result = call_tool('update_issue', { 'issue' => 1, 'custom_field_values' => { '2' => 'leak' } })
    assert result['isError'], result.inspect
    assert_match(/cannot be set here/, result['content'].first['text'])
    assert_equal '125', Issue.find(1).custom_field_value(CustomField.find(2))
  end

  # A filter, sort or grouping on the field would read its values back.
  def test_an_excluded_field_is_unknown_to_issue_queries
    assert_not call_tool('search_issues', { 'filters' => { 'cf_1' => 'MySQL' } })['isError']
    exclude_custom_fields(1)
    [{ 'filters' => { 'cf_1' => 'MySQL' } }, { 'sort' => 'cf_1:asc' }, { 'group_by' => 'cf_1' },
     { 'describe' => 'cf_1' }].each do |arguments|
      assert call_tool('search_issues', arguments)['isError'], arguments.inspect
    end
    described = call_tool('search_issues', { 'describe' => true })['structuredContent']
    assert(described['filters'].none? { |filter| filter['field'] =~ /cf_1\z/ })
    assert(described['groupable'].none? { |field| field.end_with?('cf_1') })
  end

  def test_an_excluded_field_is_unknown_to_time_entry_queries
    exclude_custom_fields(10)
    result = call_tool('list_time_entries', { 'project' => 'ecookbook', 'filters' => { 'cf_10' => '1' } })
    assert result['isError'], result.inspect
  end

  # Query 9 groups by cf_1: its group labels would be the field's values.
  def test_a_saved_query_does_not_group_on_an_excluded_field
    assert call_tool('search_issues', { 'query' => 9 })['structuredContent'].key?('groups')
    exclude_custom_fields(1)
    result = call_tool('search_issues', { 'query' => 9 })
    assert_not result['isError'], result.inspect
    assert_not result['structuredContent'].key?('groups')
  end

  # A version or user field offers chained filters on the target's own fields:
  # cf_N.status reads which version an issue holds, cf_N.cf_M which user.
  def test_chained_keys_on_an_excluded_field_are_unknown
    version = IssueCustomField.create!(name: 'Target version', field_format: 'version', is_filter: true,
                                       is_for_all: true, tracker_ids: Tracker.pluck(:id))
    reviewer = IssueCustomField.create!(name: 'Reviewer', field_format: 'user', is_filter: true,
                                        is_for_all: true, tracker_ids: Tracker.pluck(:id))
    team = UserCustomField.create!(name: 'Team', field_format: 'string', is_filter: true, visible: true)
    issue = Issue.find(1)
    issue.custom_field_values = { version.id.to_s => '2', reviewer.id.to_s => '3' }
    issue.save!
    chained = [
      { "cf_#{version.id}.status" => 'locked' },
      { "cf_#{version.id}.due_date" => { 'operator' => '*' } },
      { "cf_#{reviewer.id}.cf_#{team.id}" => 'core' }
    ]
    search = ->(filters) { call_tool('search_issues', { 'status' => 'all', 'filters' => filters }) }
    chained.each { |filters| assert_not search.call(filters)['isError'], filters.inspect }

    exclude_custom_fields(version.id, reviewer.id)
    chained.each { |filters| assert search.call(filters)['isError'], filters.inspect }
    described = call_tool('search_issues', { 'describe' => true })['structuredContent']
    assert(described['filters'].none? { |filter| filter['field'] =~ /cf_(#{version.id}|#{reviewer.id})\b/ })

    # Excluded at the tail of the chain only.
    exclude_custom_fields(team.id)
    assert search.call({ "cf_#{reviewer.id}.cf_#{team.id}" => 'core' })['isError']
  end

  def test_chained_keys_on_an_excluded_time_entry_field_are_unknown
    version = TimeEntryCustomField.create!(name: 'Billed version', field_format: 'version', is_filter: true,
                                           visible: true)
    filters = { 'project' => 'ecookbook', 'filters' => { "cf_#{version.id}.status" => 'locked' } }
    assert_not call_tool('list_time_entries', filters)['isError']
    exclude_custom_fields(version.id)
    assert call_tool('list_time_entries', filters)['isError']
  end

  # The refusal names a field only when the caller may read it on the issue.
  def test_a_refused_field_is_named_only_when_the_caller_may_read_it
    enable_mcp('read_only' => '0', 'excluded_custom_fields' => ['2'])
    restricted = IssueCustomField.create!(name: 'Margin', field_format: 'string', is_for_all: true,
                                          visible: false, role_ids: [3], tracker_ids: Tracker.pluck(:id))
    names = { 2 => CustomField.find(2).name, 3 => CustomField.find(3).name, restricted.id => 'Margin' }
    names.each do |id, name|
      result = call_tool('update_issue', { 'issue' => 1, 'custom_field_values' => { id.to_s => 'x' } })
      text   = result['content'].first['text']
      assert result['isError'], result.inspect
      assert_match(/\bid #{id} cannot be set here/, text)
      assert_not_includes text, name
    end
  end
end
