# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# search_issues, list_time_entries and list_projects over core's queries: the named filters,
# the explicit ones with their operators, sorting, grouping, and what a filter
# may point at.
class McpQueryToolsTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :issue_categories, :trackers, :enumerations, :enabled_modules,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :time_entries, :versions, :queries

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp
    User.current = nil
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  # A project's issues include its subprojects', as on the issue list.
  def in_ecookbook
    Issue.visible(User.find(2)).where(project_id: Project.find(1).self_and_descendants.select(:id))
  end

  def issue_ids(arguments)
    state(call_tool('search_issues', arguments.merge('limit' => 100)))['issues'].map { |row| row['id'] }
  end

  # --- named filters ------------------------------------------------------------

  def test_status_filters_split_open_from_closed
    visible = in_ecookbook
    base    = { 'project' => 'ecookbook' }

    assert_equal visible.open.pluck(:id).sort, issue_ids(base.merge('status' => 'open')).sort
    assert_equal visible.open(false).pluck(:id).sort, issue_ids(base.merge('status' => 'closed')).sort
    assert_equal visible.pluck(:id).sort, issue_ids(base.merge('status' => 'all')).sort
  end

  def test_tracker_priority_and_version_are_named
    ids = issue_ids('project' => 'ecookbook', 'status' => 'all', 'tracker' => 'Bug', 'priority' => 'Low')
    assert_equal in_ecookbook.where(tracker_id: 1, priority_id: 4).pluck(:id).sort, ids.sort

    versioned = issue_ids('project' => 'ecookbook', 'status' => 'all', 'fixed_version' => Version.find(2).name)
    assert_equal in_ecookbook.where(fixed_version_id: 2).pluck(:id).sort, versioned.sort
  end

  def test_an_unknown_name_is_refused_by_name
    assert_match 'No tracker named "Nope"', refusal(call_tool('search_issues', { 'tracker' => 'Nope' }))
    assert_match 'No priority named "Nope"', refusal(call_tool('search_issues', { 'priority' => 'Nope' }))
    assert_match 'fixed_version needs a project', refusal(call_tool('search_issues', { 'fixed_version' => '1.0' }))
    assert_match 'Project ecookbook has no version named "Nope"',
                 refusal(call_tool('search_issues', { 'project' => 'ecookbook', 'fixed_version' => 'Nope' }))
    assert_match 'assigned_to must be a user id', refusal(call_tool('search_issues', { 'assigned_to' => 'bob' }))
  end

  def test_people_and_dates_filter
    mine = issue_ids('status' => 'all', 'author' => 'me')
    assert mine.any?
    assert_equal [2], Issue.where(id: mine).distinct.pluck(:author_id)

    assigned = issue_ids('status' => 'all', 'assigned_to' => 3)
    assert_equal [3], Issue.where(id: assigned).distinct.pluck(:assigned_to_id)

    assert_empty issue_ids('status' => 'all', 'created_since' => '2999-01-01')
    assert_empty issue_ids('status' => 'all', 'updated_since' => '2999-01-01')
    assert_empty issue_ids('status' => 'all', 'due_before' => '1970-01-01')
  end

  # --- explicit filters ------------------------------------------------------------

  def test_an_explicit_filter_takes_an_operator
    ids = issue_ids('project' => 'ecookbook', 'filters' => { 'status_id' => { 'operator' => '!', 'values' => ['1'] },
                                                             'tracker_id' => '1' })
    assert ids.any?
    assert_empty Issue.where(id: ids).where(status_id: 1)
    assert_equal [1], Issue.where(id: ids).distinct.pluck(:tracker_id)
  end

  # Core skips a filter that has no value at all, and the result reads unfiltered.
  def test_an_empty_values_list_reads_as_values_left_out
    filter = ->(spec) { issue_ids('status' => 'all', 'filters' => { 'assigned_to_id' => spec }) }
    unassigned = filter.call('operator' => '!*', 'values' => [])

    assert unassigned.any?
    assert_empty Issue.where(id: unassigned).where.not(assigned_to_id: nil)
    assert_equal filter.call('operator' => '!*').sort, unassigned.sort
  end

  def test_an_operator_the_filter_does_not_take_is_refused_with_the_valid_ones
    text = refusal(call_tool('search_issues', { 'filters' => { 'status_id' => { 'operator' => '~', 'values' => ['1'] } } }))
    assert_match 'Operator "~" is not valid for "status_id". Valid: ', text
  end

  def test_a_named_filter_and_its_explicit_twin_are_refused_together
    text = refusal(call_tool('search_issues', { 'tracker' => 'Bug', 'filters' => { 'tracker_id' => '1' } }))
    assert_match 'Pass tracker or filters["tracker_id"], not both', text
  end

  def test_an_unknown_filter_suggests_the_close_ones
    assert_match 'Unknown filter "statu". Did you mean ', refusal(call_tool('search_issues', { 'filters' => { 'statu' => '1' } }))
    assert_match 'Unknown filter "zzzzzz". Call with describe: true',
                 refusal(call_tool('search_issues', { 'filters' => { 'zzzzzz' => '1' } }))
  end

  # A filter that points at a record is checked as the record itself would be.
  def test_a_filter_may_only_point_at_what_the_caller_may_see
    assert issue_ids('status' => 'all', 'filters' => { 'project_id' => '1' }).any?
    assert_equal [1], issue_ids('status' => 'all', 'filters' => { 'issue_id' => '1' })
    assert_kind_of Array, issue_ids('status' => 'all', 'filters' => { 'parent_id' => '1' })
    assert_kind_of Array, issue_ids('status' => 'all', 'filters' => { 'fixed_version_id' => '2' })
    assert_kind_of Array, issue_ids('project' => 'ecookbook', 'status' => 'all', 'filters' => { 'category_id' => '1' })

    private_project = Project.generate!(is_public: false)
    hidden          = Issue.generate!(project: private_project)
    assert_match 'No visible project', refusal(call_tool('search_issues', { 'filters' => { 'project_id' => private_project.id.to_s } }))
    assert_match 'No visible issue', refusal(call_tool('search_issues', { 'filters' => { 'parent_id' => hidden.id.to_s } }))
  end

  def test_a_filter_on_a_version_or_category_of_a_hidden_project_is_refused
    private_project = Project.generate!(is_public: false)
    version         = Version.create!(project: private_project, name: 'Hidden')
    category        = IssueCategory.create!(project: private_project, name: 'Hidden')

    assert_match 'do not have permission',
                 refusal(call_tool('search_issues', { 'filters' => { 'fixed_version_id' => version.id.to_s } }))
    assert_match 'do not have permission',
                 refusal(call_tool('search_issues', { 'project' => 'ecookbook', 'filters' => { 'category_id' => category.id.to_s } }))
  end

  # --- sort, group, describe ----------------------------------------------------------

  def test_sort_takes_a_field_and_a_direction
    ids = issue_ids('project' => 'ecookbook', 'status' => 'all', 'sort' => 'id:asc')
    assert_equal ids.sort, ids
    ids = issue_ids('project' => 'ecookbook', 'status' => 'all', 'sort' => 'id')
    assert_equal ids.sort.reverse, ids

    assert_match 'Cannot sort by "nope". Sortable: ', refusal(call_tool('search_issues', { 'sort' => 'nope' }))
    assert_match 'sort direction must be asc or desc, got "sideways"', refusal(call_tool('search_issues', { 'sort' => 'id:sideways' }))
  end

  def test_group_by_counts_the_whole_filtered_set
    result = state(call_tool('search_issues', { 'project' => 'ecookbook', 'status' => 'all', 'group_by' => 'status', 'limit' => 1 }))

    assert_equal 1, result['returned']
    assert_equal(result['total_count'], result['groups'].sum { |group| group['count'] })
    assert(result['groups'].all? { |group| group['group']['label'].present? })

    assert_match 'Cannot group by "nope". Groupable: ', refusal(call_tool('search_issues', { 'group_by' => 'nope' }))
  end

  def test_group_by_an_empty_value_is_labelled_none
    result = state(call_tool('search_issues', { 'project' => 'ecookbook', 'status' => 'all', 'group_by' => 'category' }))
    assert_includes result['groups'].map { |group| group['group']['label'] }, '(none)'
  end

  def test_describe_lists_everything_or_one_filter
    all = state(call_tool('search_issues', { 'describe' => true }))
    assert_includes all['filters'].map { |filter| filter['field'] }, 'status_id'
    assert_includes all['sortable'], 'id'
    assert_includes all['groupable'], 'status'

    one = state(call_tool('search_issues', { 'describe' => 'status_id' }))
    assert_equal 'status_id', one['field']
    assert one['operators'].any?
    assert one['values'].any?

    assert_match 'Ids come from list_users', state(call_tool('search_issues', { 'describe' => 'assigned_to_id' }))['note']
    assert_match 'Ids come from list_projects', state(call_tool('search_issues', { 'describe' => 'project_id' }))['note']
    assert_match 'Unknown filter "nope_at_all"', refusal(call_tool('search_issues', { 'describe' => 'nope_at_all' }))
  end

  def test_a_saved_query_is_run_and_an_unknown_one_refused
    query = IssueQuery.visible(User.find(2)).where(project_id: 1).first
    result = state(call_tool('search_issues', { 'query' => query.id, 'project' => 'ecookbook' }))
    assert_kind_of Array, result['issues']

    assert_match 'No visible saved query with id', refusal(call_tool('search_issues', { 'query' => 999_999 }))
  end

  # --- time entries ----------------------------------------------------------------------

  def test_list_time_entries_answers_for_the_issue_when_the_project_named_is_another
    result = state(call_tool('list_time_entries', { 'issue' => 1, 'project' => 'onlinestore' }))

    assert_match 'Issue #1 is in ecookbook', result['note']
    assert_match 'the project you named was not used', result['note']
    assert_equal TimeEntry.visible(User.find(2)).where(issue_id: 1).count, result['total_count']
  end

  def test_list_time_entries_filters_by_activity_user_and_dates
    base   = { 'project' => 'ecookbook', 'limit' => 100 }
    design = state(call_tool('list_time_entries', base.merge('activity' => 'Design')))
    assert_equal TimeEntry.visible(User.find(2)).where(project_id: 1, activity_id: 9).count, design['total_count']

    anywhere = state(call_tool('list_time_entries', { 'activity' => 'Design', 'limit' => 100 }))
    assert_operator anywhere['total_count'], :>=, design['total_count']

    assert_equal 0, state(call_tool('list_time_entries', base.merge('from' => '2999-01-01')))['total_count']
    assert_equal 0, state(call_tool('list_time_entries', base.merge('to' => '1970-01-01')))['total_count']
    mine = state(call_tool('list_time_entries', base.merge('user' => 'me')))
    assert_equal TimeEntry.visible(User.find(2)).where(project_id: 1, user_id: 2).count, mine['total_count']

    assert_match 'No time entry activity named "Nope"', refusal(call_tool('list_time_entries', base.merge('activity' => 'Nope')))
  end

  def test_list_time_entries_groups_with_hours_and_labels
    by_issue = state(call_tool('list_time_entries', { 'project' => 'ecookbook', 'group_by' => 'issue' }))
    labels   = by_issue['groups'].map { |group| group['group']['label'] }
    assert(labels.any? { |label| label.start_with?('#') })
    assert(by_issue['groups'].all? { |group| group.key?('total_hours') })

    by_user = state(call_tool('list_time_entries', { 'project' => 'ecookbook', 'group_by' => 'user' }))
    assert(by_user['groups'].all? { |group| group['group']['label'].present? })
  end

  def test_list_time_entries_takes_one_issue_id_with_equals
    text = refusal(call_tool('list_time_entries', { 'filters' => { 'issue_id' => { 'operator' => '=', 'values' => %w[1 2] } } }))
    assert_match 'filters["issue_id"] takes one id with "="', text
  end

  def test_list_time_entries_describes_its_filters
    described = state(call_tool('list_time_entries', { 'describe' => true }))
    assert_includes described['filters'].map { |filter| filter['field'] }, 'spent_on'
    assert described['sortable'].any?
  end

  # Filters that are not an object were ignored, and the search answered as if none had been sent.
  def test_filters_must_be_an_object
    assert_match 'filters must be an object, got "status_id=1"', refusal(call_tool('search_issues', { 'filters' => 'status_id=1' }))
    assert_match 'filters must be an object, got an array', refusal(call_tool('list_time_entries', { 'filters' => ['issue_id'] }))
  end

  # --- list_projects ------------------------------------------------------------

  def project_ids(arguments = {})
    state(call_tool('list_projects', arguments.merge('limit' => 100)))['projects'].map { |row| row['id'] }
  end

  # No filter: every visible project, closed ones included, in the project tree's order.
  def test_list_projects_without_a_filter_lists_the_tree
    Project.find(3).update_column(:status, Project::STATUS_CLOSED)
    assert_equal Project.visible(User.find(2)).order(:lft).pluck(:id), project_ids
  end

  def test_list_projects_filters_by_status_and_parent
    Project.find(3).update_column(:status, Project::STATUS_CLOSED)

    assert_equal [3], project_ids('filters' => { 'status' => '5' })
    assert_not_includes project_ids('filters' => { 'status' => '1' }), 3
    children = Project.visible(User.find(2)).where(parent_id: 1).pluck(:id)
    assert children.any?
    assert_equal children.sort, project_ids('filters' => { 'parent_id' => '1' }).sort
    assert_equal Project.visible(User.find(2)).where(parent_id: nil).pluck(:id).sort,
                 project_ids('filters' => { 'parent_id' => { 'operator' => '!*', 'values' => [] } }).sort
  end

  def test_list_projects_filters_and_groups_by_a_custom_field
    stable = Project.visible(User.find(2)).joins(:custom_values)
                    .where(custom_values: { custom_field_id: 3, value: 'Stable' }).pluck(:id)
    assert stable.any?
    assert_equal stable.sort, project_ids('filters' => { 'cf_3' => 'Stable' }).sort

    result = state(call_tool('list_projects', { 'group_by' => 'cf_3', 'limit' => 1 }))
    assert_equal 1, result['returned']
    assert_equal(result['total_count'], result['groups'].sum { |group| group['count'] })
    assert_includes result['groups'].map { |group| group['group']['label'] }, 'Stable'
  end

  # name is not a core filter: the group counts must cover it all the same.
  def test_list_projects_name_narrows_the_rows_and_the_groups
    result = state(call_tool('list_projects', { 'name' => 'COOK', 'group_by' => 'is_public', 'filters' => { 'status' => '1' } }))

    assert result['projects'].any?
    assert(result['projects'].all? { |row| "#{row['identifier']} #{row['name']}".downcase.include?('cook') })
    assert_equal(result['total_count'], result['groups'].sum { |group| group['count'] })
    assert_operator result['total_count'], :<, Project.visible(User.find(2)).count
  end

  def test_list_projects_sorts
    names = ->(sort) { state(call_tool('list_projects', { 'sort' => sort, 'limit' => 100 }))['projects'].map { |row| row['id'] } }
    by_name = Project.visible(User.find(2)).order(:name).pluck(:id)

    assert_equal by_name, names.call('name:asc')
    assert_equal by_name.reverse, names.call('name')
    assert_match 'Cannot sort by "nope". Sortable: ', refusal(call_tool('list_projects', { 'sort' => 'nope' }))
  end

  def test_list_projects_describes_its_filters
    all = state(call_tool('list_projects', { 'describe' => true }))
    assert_includes all['filters'].map { |filter| filter['field'] }, 'status'
    assert_includes all['filters'].map { |filter| filter['field'] }, 'cf_3'
    assert_includes all['sortable'], 'name'
    assert_includes all['groupable'], 'is_public'

    assert state(call_tool('list_projects', { 'describe' => 'status' }))['values'].any?
    parent = state(call_tool('list_projects', { 'describe' => 'parent_id' }))
    assert_nil parent['values']
    assert_match 'Project ids from this tool', parent['note']
  end

  def test_list_projects_refuses_a_filter_it_cannot_apply
    hidden = Project.generate!(is_public: false)
    assert_match 'No visible project', refusal(call_tool('list_projects', { 'filters' => { 'id' => hidden.id.to_s } }))
    assert_match 'No visible project', refusal(call_tool('list_projects', { 'filters' => { 'parent_id' => hidden.id.to_s } }))
    assert_match 'Unknown filter "statu". Did you mean ', refusal(call_tool('list_projects', { 'filters' => { 'statu' => '1' } }))
    assert_match 'Operator "~" is not valid for "status"',
                 refusal(call_tool('list_projects', { 'filters' => { 'status' => { 'operator' => '~', 'values' => ['1'] } } }))
  end

  # Redmine offers no filter on such a field; the refusal says so and how to read it.
  def test_list_projects_names_a_custom_field_that_is_not_a_filter
    field = ProjectCustomField.create!(name: 'Sponsor', field_format: 'string', is_filter: false)
    text  = refusal(call_tool('list_projects', { 'filters' => { "cf_#{field.id}" => 'Acme' } }))
    assert_match "cf_#{field.id} (Sponsor) is not \"Used as a filter\"", text

    enable_mcp('excluded_custom_fields' => ['', field.id.to_s, '3'])
    assert_match "Unknown filter \"cf_#{field.id}\"", refusal(call_tool('list_projects', { 'filters' => { "cf_#{field.id}" => 'Acme' } }))
    assert_match 'Unknown filter "cf_3"', refusal(call_tool('list_projects', { 'filters' => { 'cf_3' => 'Stable' } }))
    assert_match 'Cannot group by "cf_3"', refusal(call_tool('list_projects', { 'group_by' => 'cf_3' }))
  end

  def test_list_projects_keeps_custom_fields_on_filtered_rows
    rows = state(call_tool('list_projects', { 'filters' => { 'cf_3' => 'Stable' }, 'include_custom_fields' => true }))['projects']
    assert rows.any?
    assert(rows.all? { |row| row['custom_fields'].any? { |field| field['id'] == 3 && field['value'] == 'Stable' } })
  end
end
