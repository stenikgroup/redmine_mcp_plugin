# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The tools that shape a project: the project itself, its versions, its issue
# categories and its members.
class McpProjectStructureTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :groups_users,
           :issues, :issue_statuses, :issue_categories, :trackers, :enumerations, :enabled_modules,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :versions

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  def without_permission(*permissions)
    Role.find_each { |role| permissions.each { |permission| role.remove_permission!(permission) } }
  end

  # --- projects -----------------------------------------------------------

  def test_create_project_makes_the_caller_a_member
    project = state(call_tool('create_project', { 'name' => 'Launch', 'identifier' => 'launch',
                                                  'enabled_modules' => %w[issue_tracking wiki],
                                                  'trackers' => ['Bug'] }))

    assert_equal 'launch', project['identifier']
    assert_nil project['parent_id']
    assert_equal %w[issue_tracking wiki], project['enabled_modules']
    assert_equal(['Bug'], project['trackers'].map { |t| t['name'] })
    assert Project.find_by(identifier: 'launch').members.exists?(user_id: 2)
  end

  def test_create_project_under_a_parent_needs_only_add_subprojects
    without_permission(:add_project)
    Role.find(1).add_permission!(:add_subprojects)

    project = state(call_tool('create_project', { 'name' => 'Child', 'identifier' => 'child', 'parent' => 'ecookbook' }))
    assert_equal 1, project['parent_id']

    assert_match(/parent \(needs /, refusal(call_tool('create_project', { 'name' => 'Root', 'identifier' => 'root-one' })))
    assert_nil Project.find_by(identifier: 'root-one')
  end

  def test_create_project_refuses_a_parent_the_caller_may_not_extend
    # jsmith is a developer on onlinestore, and a developer has no add_subprojects.
    Role.find(2).remove_permission!(:add_subprojects)
    text = refusal(call_tool('create_project', { 'name' => 'Child', 'identifier' => 'child', 'parent' => 'onlinestore' }))
    assert_match(/parent \(needs .* on onlinestore\)/, text)
  end

  def test_create_project_names_an_unknown_module_and_tracker
    text = refusal(call_tool('create_project', { 'name' => 'X', 'identifier' => 'x-one', 'enabled_modules' => ['kanban'],
                                                 'trackers' => ['Epic'] }))
    assert_match 'no module kanban', text
    assert_match 'no tracker "Epic"', text
    assert_match 'issue_tracking', text
  end

  def test_create_project_refuses_visibility_without_its_permission
    without_permission(:select_project_publicity)
    text = refusal(call_tool('create_project', { 'name' => 'X', 'identifier' => 'x-two', 'is_public' => false }))
    assert_match 'is_public (needs ', text
    assert_nil Project.find_by(identifier: 'x-two')
  end

  def test_create_project_reports_core_validation
    text = refusal(call_tool('create_project', { 'name' => 'Dup', 'identifier' => 'ecookbook' }))
    assert_match 'Could not create the project', text
  end

  def test_update_project_changes_only_what_is_sent
    project = state(call_tool('update_project', { 'project' => 'ecookbook', 'name' => 'Cookbook',
                                                  'enabled_modules' => %w[issue_tracking news] }))

    assert_equal 'Cookbook', project['name']
    assert_equal %w[issue_tracking news], project['enabled_modules']
    assert_equal Project.find(1).description, project['description']
  end

  def test_update_project_needs_a_field
    assert_match 'at least one field', refusal(call_tool('update_project', { 'project' => 'ecookbook' }))
  end

  def test_update_project_refuses_modules_without_their_permission
    without_permission(:select_project_modules)
    text = refusal(call_tool('update_project', { 'project' => 'ecookbook', 'name' => 'Kept out',
                                                 'enabled_modules' => %w[wiki] }))
    assert_match 'enabled_modules (needs ', text
    assert_equal 'eCookbook', Project.find(1).name
  end

  def test_update_project_moves_to_the_root_only_with_add_project
    Project.find(1).set_parent!(Project.find(2))
    without_permission(:add_project)
    text = refusal(call_tool('update_project', { 'project' => 'ecookbook', 'parent' => 'none' }))
    assert_match(/parent \(needs /, text)
  end

  def test_close_and_reopen_project
    closed = state(call_tool('close_project', { 'project' => 'ecookbook' }))
    assert_equal Project::STATUS_CLOSED, closed['status']
    assert_match 'already closed', refusal(call_tool('close_project', { 'project' => 'ecookbook' }))

    # A closed project names its state instead of a permission problem.
    assert_match 'is closed; reopen it first', refusal(call_tool('update_project', { 'project' => 'ecookbook', 'name' => 'X' }))
    assert_match 'is closed; reopen it first',
                 refusal(call_tool('create_version', { 'project' => 'ecookbook', 'name' => '9.0' }))

    reopened = state(call_tool('reopen_project', { 'project' => 'ecookbook' }))
    assert_equal Project::STATUS_ACTIVE, reopened['status']
    assert_match 'is not closed', refusal(call_tool('reopen_project', { 'project' => 'ecookbook' }))
  end

  def test_project_writes_need_their_permission_on_the_project
    # dlopper is a developer on ecookbook and on onlinestore; only the second lets him edit and close.
    Role.find(2).remove_permission!(:edit_project, :close_project)
    Member.where(project_id: 2, user_id: 3).destroy_all
    Member.create!(project_id: 2, user_id: 3, role_ids: [1])
    developer = User.find(3)

    assert_match 'do not have permission', refusal(call_tool('update_project', { 'project' => 'ecookbook', 'name' => 'X' }, developer))
    assert_match 'do not have permission', refusal(call_tool('close_project', { 'project' => 'ecookbook' }, developer))
    assert_equal 'eCookbook', Project.find(1).name
  end

  # --- versions -----------------------------------------------------------

  def test_create_version
    version = state(call_tool('create_version', { 'project' => 'ecookbook', 'name' => '3.0', 'due_date' => '2027-01-15',
                                                  'status' => 'locked', 'sharing' => 'descendants',
                                                  'default_project_version' => true }))

    assert_equal '3.0', version['name']
    assert_equal 'ecookbook', version['project_identifier']
    assert_equal '2027-01-15', version['due_date']
    assert_equal 'locked', version['status']
    assert_equal 'descendants', version['sharing']
    assert version['default_project_version']
    assert_equal version['id'], Project.find(1).default_version_id
  end

  def test_create_version_refuses_a_sharing_the_caller_may_not_set
    text = refusal(call_tool('create_version', { 'project' => 'ecookbook', 'name' => '3.0', 'sharing' => 'system' }))
    assert_match 'sharing ("system" is not allowed to you here', text
    assert_nil Version.find_by(name: '3.0')
  end

  def test_update_version_clears_the_due_date
    assert Version.find(2).effective_date
    version = state(call_tool('update_version', { 'version' => 2, 'due_date' => 'none', 'status' => 'closed' }))

    assert_nil version['due_date']
    assert_equal 'closed', version['status']
    assert_equal Version.find(2).name, version['name']
  end

  def test_update_version_refuses_a_bad_date_and_a_duplicate_name
    assert_match 'ISO-8601', refusal(call_tool('update_version', { 'version' => 2, 'due_date' => 'soon' }))
    assert_match 'Could not update the version',
                 refusal(call_tool('update_version', { 'version' => 2, 'name' => Version.find(1).name }))
  end

  def test_version_of_an_invisible_project_reads_as_missing
    # Version 5 belongs to a private project jsmith is not a member of... made so here.
    version = Version.generate!(project: Project.find(5))
    Member.where(project_id: 5, user_id: 2).destroy_all
    assert_match "No visible version with id #{version.id}", refusal(call_tool('update_version', { 'version' => version.id, 'name' => 'X' }))
    assert_match 'No visible version with id 99999', refusal(call_tool('update_version', { 'version' => 99_999, 'name' => 'X' }))
  end

  # --- issue categories -----------------------------------------------------

  def test_create_and_update_issue_category
    created = state(call_tool('create_issue_category', { 'project' => 'ecookbook', 'name' => 'Billing', 'assigned_to' => 'me' }))
    assert_equal 'Billing', created['name']
    assert_equal 2, created['assigned_to']['id']

    updated = state(call_tool('update_issue_category', { 'category' => created['id'], 'name' => 'Invoicing',
                                                         'assigned_to' => 'none' }))
    assert_equal 'Invoicing', updated['name']
    assert_nil updated['assigned_to']
  end

  # Core's API takes any principal as the default assignee, so this does too.
  def test_issue_category_takes_any_user_and_refuses_an_id_that_names_nobody
    outsider = User.generate!
    created  = state(call_tool('create_issue_category', { 'project' => 'ecookbook', 'name' => 'Billing',
                                                          'assigned_to' => outsider.id }))
    assert_equal outsider.id, created['assigned_to']['id']

    text = refusal(call_tool('create_issue_category', { 'project' => 'ecookbook', 'name' => 'Other',
                                                        'assigned_to' => 999_999 }))
    assert_match 'No user or group with id 999999', text
  end

  def test_issue_category_needs_the_issue_tracking_module
    Project.find(1).disable_module!(:issue_tracking)
    text = refusal(call_tool('create_issue_category', { 'project' => 'ecookbook', 'name' => 'Billing' }))
    assert_match 'issue_tracking module is not enabled', text
  end

  # --- members ------------------------------------------------------------

  def test_list_memberships_gives_roles_and_what_the_caller_may_give
    result = state(call_tool('list_memberships', { 'project' => 'ecookbook' }))

    manager = result['memberships'].detect { |row| row['principal']['id'] == 2 }
    assert_equal(['Manager'], manager['roles'].map { |role| role['name'] })
    assert_equal false, manager['roles'].first['inherited']
    assert_includes result['manageable_roles'].map { |role| role['name'] }, 'Reporter'

    # A developer may read the members, and is told of no role to give.
    Role.find(2).remove_permission!(:manage_members)
    assert_not state(call_tool('list_memberships', { 'project' => 'ecookbook' }, User.find(3))).key?('manageable_roles')
  end

  def test_update_membership_adds_then_replaces_roles
    newcomer = User.generate!

    added = state(call_tool('update_membership', { 'project' => 'ecookbook', 'principal' => newcomer.id,
                                                   'roles' => ['reporter'] }))
    assert_equal newcomer.id, added['principal']['id']
    assert_equal(['Reporter'], added['roles'].map { |role| role['name'] })

    replaced = state(call_tool('update_membership', { 'project' => 'ecookbook', 'principal' => newcomer.id,
                                                      'roles' => [2, 'Manager'] }))
    assert_equal added['id'], replaced['id']
    assert_equal %w[Developer Manager], replaced['roles'].map { |role| role['name'] }.sort
  end

  def test_update_membership_refuses_a_role_the_caller_may_not_give
    Role.find(1).update!(all_roles_managed: false, managed_role_ids: [3])
    newcomer = User.generate!

    text = refusal(call_tool('update_membership', { 'project' => 'ecookbook', 'principal' => newcomer.id,
                                                    'roles' => %w[Reporter Manager] }))
    assert_match 'You may not give role "Manager" here; roles: Reporter', text
    assert_not Member.exists?(project_id: 1, user_id: newcomer.id)
  end

  def test_update_membership_refuses_an_empty_list_and_an_unknown_principal
    assert_match 'roles',
                 refusal(call_tool('update_membership', { 'project' => 'ecookbook', 'principal' => 3, 'roles' => [] }))
    assert_match 'No user or group with id 99999',
                 refusal(call_tool('update_membership', { 'project' => 'ecookbook', 'principal' => 99_999, 'roles' => ['Reporter'] }))
  end

  # --- what a token may do -------------------------------------------------

  def bearer(scopes)
    application = Doorkeeper::Application.create!(name: 'MCP test', redirect_uri: 'https://client.example/callback',
                                                  scopes: scopes)
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: 2, scopes: scopes,
                                            expires_in: 2.hours)
    { 'Authorization' => "Bearer #{token.plaintext_token}" }
  end

  def call_as(headers, name, arguments)
    post_mcp rpc('tools/call', { 'name' => name, 'arguments' => arguments }), headers
    json_body
  end

  # The role grants everything here; the token's scopes are what narrow it.
  def test_a_token_without_the_scope_is_refused_each_write
    headers = bearer('view_project view_issues view_members')
    calls   = { 'create_project' => { 'name' => 'X', 'identifier' => 'x-three' },
                'update_project' => { 'project' => 'ecookbook', 'name' => 'X' },
                'close_project' => { 'project' => 'ecookbook' },
                'create_version' => { 'project' => 'ecookbook', 'name' => '9.0' },
                'update_version' => { 'version' => 2, 'name' => '9.0' },
                'create_issue_category' => { 'project' => 'ecookbook', 'name' => 'Billing' },
                'update_issue_category' => { 'category' => 1, 'name' => 'Billing' },
                'update_membership' => { 'project' => 'ecookbook', 'principal' => 3, 'roles' => ['Reporter'] } }

    calls.each do |name, arguments|
      assert call_as(headers, name, arguments)['error'].present?, "#{name} must be refused"
    end
    assert_equal 'eCookbook', Project.find(1).name
    assert_nil Project.find_by(identifier: 'x-three')
  end

  # Core's update needs no read permission and answers with no body: the write
  # goes through, and the record is not read back to a token that may not view it.
  def test_version_and_category_writes_do_not_need_view_issues
    headers = bearer('view_project manage_versions manage_categories')

    version = state(call_as(headers, 'update_version', { 'version' => 2, 'name' => '9.0' })['result'])
    assert_equal '9.0', Version.find(2).name
    assert_equal({ 'id' => 2, 'project_identifier' => 'ecookbook' }, version.slice('id', 'project_identifier'))
    assert_not version.key?('description')
    assert_match 'Reading it back needs ', version['note']

    category = state(call_as(headers, 'update_issue_category', { 'category' => 1, 'name' => 'Billing' })['result'])
    assert_equal 'Billing', IssueCategory.find(1).name
    assert_not category.key?('name')
  end

  def test_a_gated_project_field_needs_its_scope
    headers = bearer('view_project edit_project')
    text    = refusal(call_as(headers, 'update_project', { 'project' => 'ecookbook', 'is_public' => false })['result'])
    assert_match 'is_public (needs ', text
    assert Project.find(1).is_public?
  end
  # --- custom fields of a project and of a version ----------------------------

  def test_update_project_sets_a_custom_field_by_its_label
    field = ProjectCustomField.create!(name: 'Stage', field_format: 'list', possible_values: %w[Alpha Beta Stable])

    updated = state(call_tool('update_project', { 'project' => 'ecookbook', 'custom_field_values' => { field.id.to_s => 'beta' } }))
    assert_equal 'Beta', Project.find(1).custom_field_value(field)
    assert_includes updated['custom_fields'].map { |row| row['value'] }, 'Beta'

    text = refusal(call_tool('update_project', { 'project' => 'ecookbook', 'custom_field_values' => { field.id.to_s => 'Gamma' } }))
    assert_match "custom field Stage (id #{field.id}) has no value \"Gamma\"", text
  end

  def test_update_version_sets_a_custom_field
    field = VersionCustomField.create!(name: 'Codename', field_format: 'string')

    updated = state(call_tool('update_version', { 'version' => 3, 'custom_field_values' => { field.id.to_s => 'Tiger' } }))
    assert_equal 'Tiger', Version.find(3).custom_field_value(field)
    assert_includes updated['custom_fields'].map { |row| row['value'] }, 'Tiger'

    assert_match 'cannot be set here', refusal(call_tool('update_version', { 'version' => 3,
                                                                             'custom_field_values' => { '999999' => 'x' } }))
  end
end
