# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class McpControllerTest < Redmine::ControllerTest
  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :watchers,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :time_entries

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('enabled' => '1')
    User.current = nil
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  def enable_mcp(overrides = {})
    Setting.plugin_redmine_mcp_plugin =
      RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1').merge(overrides)
    Setting.clear_cache
  end

  def rpc(method, params = nil, id: 1)
    body = { jsonrpc: '2.0', id: id, method: method }
    body[:params] = params if params
    body.to_json
  end

  # ActionController::TestCase#process takes no headers keyword, on any Rails:
  # request headers are set on @request before the call.
  def post_mcp(payload, headers = {})
    headers.each { |name, value| @request.headers[name] = value }
    post :handle, body: payload, as: :json
  end

  def json_body
    JSON.parse(response.body)
  end

  def api_key_headers(user)
    { 'X-Redmine-API-Key' => user.api_key }
  end

  # --- endpoint gating ---------------------------------------------------

  def test_endpoint_is_off_until_enabled
    enable_mcp('enabled' => '0')
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_response :forbidden
  end

  def test_unauthenticated_request_is_rejected
    post_mcp rpc('tools/list')
    assert_response :unauthorized
  end

  def test_invalid_api_key_is_rejected
    post_mcp rpc('tools/list'), 'X-Redmine-API-Key' => 'nonsense'
    assert_response :unauthorized
  end

  # A mode that is switched off must not authenticate, even with a valid
  # credential for that mode.
  def test_disabled_api_key_mode_rejects_a_valid_key
    enable_mcp('auth_api_key' => '0', 'auth_oauth2' => '0', 'auth_basic' => '0', 'auth_session' => '0')
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_response :service_unavailable
  end

  def test_api_key_mode_requires_rest_api_enabled
    Setting.rest_api_enabled = '0'
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_response :unauthorized
  end

  # --- transport ----------------------------------------------------------

  def test_malformed_json_is_a_parse_error
    post_mcp '{not json', api_key_headers(User.find(2))
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::PARSE_ERROR, json_body['error']['code']
  end

  # Batching was removed from the protocol in 2025-06-18. Refusing it beats
  # processing element zero and silently dropping the rest.
  def test_batches_are_refused
    post_mcp [{ jsonrpc: '2.0', id: 1, method: 'tools/list' }].to_json, api_key_headers(User.find(2))
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::INVALID_REQUEST, json_body['error']['code']
  end

  def test_notification_gets_202_with_no_body
    post_mcp({ jsonrpc: '2.0', method: 'notifications/initialized' }.to_json, api_key_headers(User.find(2)))
    assert_response :accepted
    assert response.body.blank?
  end

  def test_unsupported_protocol_version_is_a_400
    post_mcp rpc('tools/list'), api_key_headers(User.find(2)).merge('MCP-Protocol-Version' => '1999-01-01')
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::UNSUPPORTED_PROTOCOL_VERSION, json_body['error']['code']
  end

  def test_get_returns_405_because_there_is_no_stream
    @request.headers['X-Redmine-API-Key'] = User.find(2).api_key
    get :stream
    assert_response :method_not_allowed
  end

  def test_unknown_method_is_method_not_found
    post_mcp rpc('nonsense/method'), api_key_headers(User.find(2))
    assert_equal RedmineMcpPlugin::JsonRpc::METHOD_NOT_FOUND, json_body['error']['code']
  end

  # --- Origin / DNS rebinding --------------------------------------------

  def test_foreign_origin_is_rejected
    post_mcp rpc('tools/list'), api_key_headers(User.find(2)).merge('Origin' => 'https://evil.example')
    assert_response :forbidden
  end

  def test_configured_origin_is_allowed
    enable_mcp('allowed_origins' => 'https://friend.example')
    post_mcp rpc('tools/list'), api_key_headers(User.find(2)).merge('Origin' => 'https://friend.example')
    assert_response :success
  end

  # Every non-browser MCP client sends no Origin at all; they must not be
  # caught by the rebinding guard.
  def test_absent_origin_is_allowed
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_response :success
  end

  # --- protocol methods ---------------------------------------------------

  def test_server_discover_advertises_versions
    post_mcp rpc('server/discover'), api_key_headers(User.find(2))
    assert_response :success
    assert_equal RedmineMcpPlugin::SUPPORTED_PROTOCOL_VERSIONS, json_body['result']['protocolVersions']
  end

  def test_initialize_echoes_supported_version
    post_mcp rpc('initialize', { 'protocolVersion' => '2025-06-18' }), api_key_headers(User.find(2))
    assert_equal '2025-06-18', json_body['result']['protocolVersion']
  end

  def test_tools_list_is_cacheable_but_private
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_equal 'private', json_body['result']['cacheScope']
    assert json_body['result']['ttlMs'].to_i.positive?
  end

  # --- read-only mode -----------------------------------------------------

  def test_write_tools_are_hidden_in_read_only_mode
    post_mcp rpc('tools/list'), api_key_headers(User.find(1))
    names = json_body['result']['tools'].map { |t| t['name'] }
    assert_not_includes names, 'create_issue'
    assert_includes names, 'search_issues'
  end

  def test_write_tool_call_is_refused_in_read_only_mode
    post_mcp rpc('tools/call', { 'name' => 'create_issue',
                                 'arguments' => { 'project' => 'ecookbook', 'subject' => 'x' } }),
             api_key_headers(User.find(1))
    assert json_body['error'].present?
  end

  def test_write_tools_appear_when_read_only_is_off
    enable_mcp('read_only' => '0')
    post_mcp rpc('tools/list'), api_key_headers(User.find(1))
    assert_includes json_body['result']['tools'].map { |t| t['name'] }, 'create_issue'
  end

  # --- visibility ---------------------------------------------------------

  def test_whoami_reports_the_authenticated_user
    post_mcp rpc('tools/call', { 'name' => 'whoami' }), api_key_headers(User.find(2))
    payload = json_body['result']['structuredContent']
    assert_equal 2, payload['id']
    assert_equal 'api_key', payload['authentication_mode']
    assert_nil payload['oauth_scopes']
  end

  # An invisible issue and a nonexistent one must be indistinguishable, or the
  # error message confirms the existence of records the caller cannot see.
  def test_invisible_issue_is_reported_as_not_found
    issue = Issue.find(4)
    issue.update_columns(is_private: true)
    post_mcp rpc('tools/call', { 'name' => 'get_issue', 'arguments' => { 'issue' => issue.id } }),
             api_key_headers(User.find(7))
    assert json_body['result']['isError']
    assert_match(/No visible issue/, json_body['result']['content'].first['text'])
  end

  def test_search_issues_only_returns_visible_rows
    user = User.find(7)
    post_mcp rpc('tools/call', { 'name' => 'search_issues', 'arguments' => { 'status' => 'all' } }),
             api_key_headers(user)
    returned = json_body['result']['structuredContent']['issues'].map { |i| i['id'] }
    assert_equal returned.sort, Issue.visible(user).where(id: returned).pluck(:id).sort
    assert Issue.count > returned.size, 'fixture set should be larger than what one user can see'
  end

  # list_users must not enumerate the directory: core's own users list is
  # admin-only and each role carries a users_visibility setting.
  def test_list_users_respects_users_visibility
    user = User.find(7)
    post_mcp rpc('tools/call', { 'name' => 'list_users' }), api_key_headers(user)
    total = json_body['result']['structuredContent']['total_count']
    assert_equal Principal.visible(user).where(type: 'User').active.count, total
  end

  # Core dropped Issue#addable_watcher_users (#43429); the plugin rebuilds the list
  # and must leave out current watchers and anyone outside the project.
  def test_get_issue_fields_lists_addable_watchers_without_current_ones
    issue = Issue.find(2)
    post_mcp rpc('tools/call', { 'name' => 'get_issue_fields', 'arguments' => { 'issue' => issue.id } }),
             api_key_headers(User.find(2))
    refute json_body['result']['isError'], json_body['result'].inspect
    ids = json_body['result']['structuredContent']['addable_watcher_users'].map { |p| p['id'] }
    assert ids.any?, 'a manager should be offered at least one watcher'
    assert_empty ids & issue.watcher_user_ids, 'current watchers must not be offered again'
    assert_empty ids - issue.project.principals.pluck(:id), 'only project members may watch'
  end

  def call_tool(name, arguments, user = User.find(2))
    post_mcp rpc('tools/call', { 'name' => name, 'arguments' => arguments }), api_key_headers(user)
    json_body['result']
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
    assert_equal %w[1 0], field['possible_values'].map { |v| v['value'] }
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
end
