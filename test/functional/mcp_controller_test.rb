# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The transport: what a request must be, and how the protocol is answered,
# before any tool runs. The tools have a file per domain.
class McpControllerTest < Redmine::ControllerTest
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

  # --- OAuth2 -------------------------------------------------------------

  def oauth_token(attributes = {})
    application = Doorkeeper::Application.create!(name: 'MCP test', redirect_uri: 'https://client.example/callback',
                                                  scopes: 'view_project view_issues')
    Doorkeeper::AccessToken.create!({ application: application, resource_owner_id: 2,
                                      scopes: 'view_project view_issues', expires_in: 2.hours }.merge(attributes))
  end

  # The token as presented on the wire. Core hashes tokens before storing them,
  # so only the record that was just created still knows the plaintext.
  def bearer_headers(access_token)
    { 'Authorization' => "Bearer #{access_token.plaintext_token}" }
  end

  def challenge
    response.headers['WWW-Authenticate'].to_s
  end

  def capture_log
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = previous
  end

  def test_valid_oauth2_token_is_accepted
    post_mcp rpc('tools/list'), bearer_headers(oauth_token)
    assert_response :success
  end

  # RFC 6750 3.1: no error code when the request carried no credential at all.
  def test_missing_token_challenge_has_no_error_code
    post_mcp rpc('tools/list')
    assert_response :unauthorized
    assert_match 'resource_metadata=', challenge
    assert_no_match 'error=', challenge
  end

  def test_expired_token_is_answered_invalid_token_and_logged
    access_token = oauth_token(created_at: 3.hours.ago)
    log = capture_log { post_mcp rpc('tools/list'), bearer_headers(access_token) }

    assert_response :unauthorized
    assert_match 'error="invalid_token"', challenge
    assert_match 'resource_metadata=', challenge
    assert_match "OAuth2 token refused (expired): token=#{access_token.id} user=2", log
  end

  def test_revoked_token_is_answered_invalid_token_and_logged
    access_token = oauth_token(revoked_at: 1.minute.ago)
    log = capture_log { post_mcp rpc('tools/list'), bearer_headers(access_token) }

    assert_response :unauthorized
    assert_match 'error="invalid_token"', challenge
    assert_match "OAuth2 token refused (revoked): token=#{access_token.id}", log
  end

  def test_unknown_token_is_answered_invalid_token_and_logged
    log = capture_log { post_mcp rpc('tools/list'), 'Authorization' => 'Bearer nonsense' }

    assert_response :unauthorized
    assert_match 'error="invalid_token"', challenge
    assert_match 'OAuth2 token refused (unknown): token not found', log
  end

  def test_token_of_a_locked_user_is_answered_invalid_token
    access_token = oauth_token
    User.find(2).lock!
    log = capture_log { post_mcp rpc('tools/list'), bearer_headers(access_token) }

    assert_response :unauthorized
    assert_match 'error="invalid_token"', challenge
    assert_match "OAuth2 token refused (inactive user): token=#{access_token.id}", log
  end

  # An API key failure is not a bearer token failure: no error code to send.
  def test_invalid_api_key_challenge_has_no_error_code
    post_mcp rpc('tools/list'), 'X-Redmine-API-Key' => 'nonsense'
    assert_response :unauthorized
    assert_no_match 'error=', challenge
  end

  # --- transport ----------------------------------------------------------

  def test_malformed_json_is_a_parse_error
    post_mcp '{not json', api_key_headers(User.find(2))
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::PARSE_ERROR, json_body['error']['code']
  end

  # An array is legal JSON-RPC and no MCP method takes one; it is the caller's
  # mistake, not an internal error.
  def test_params_that_are_not_an_object_are_invalid_params
    post_mcp({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: ['whoami'] }.to_json, api_key_headers(User.find(2)))
    assert_response :success
    assert_equal RedmineMcpPlugin::JsonRpc::INVALID_PARAMS, json_body['error']['code']
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

  def test_delete_returns_405_because_there_is_no_session
    @request.headers['X-Redmine-API-Key'] = User.find(2).api_key
    delete :terminate
    assert_response :method_not_allowed
  end

  # Rails only parses a body it is told is JSON; any other reaches the handler's own parser.
  def test_malformed_json_under_another_content_type_is_a_parse_error
    @request.headers['X-Redmine-API-Key'] = User.find(2).api_key
    @request.headers['CONTENT_TYPE'] = 'text/plain'
    post :handle, body: '{not json'
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::PARSE_ERROR, json_body['error']['code']
  end

  def test_a_message_with_no_method_is_an_invalid_request
    post_mcp({ jsonrpc: '2.0', id: 1 }.to_json, api_key_headers(User.find(2)))
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::INVALID_REQUEST, json_body['error']['code']
  end

  def test_a_message_that_is_not_json_rpc_2_is_an_invalid_request
    post_mcp({ jsonrpc: '1.0', id: 9, method: 'ping' }.to_json, api_key_headers(User.find(2)))
    assert_response :bad_request
    assert_equal RedmineMcpPlugin::JsonRpc::INVALID_REQUEST, json_body['error']['code']
    assert_equal 9, json_body['id']
  end

  def test_ping_is_answered
    post_mcp rpc('ping'), api_key_headers(User.find(2))
    assert_response :success
    assert_equal({}, json_body['result'])
  end

  def test_no_authentication_mode_at_all_is_a_503
    enable_mcp('auth_oauth2' => '0', 'auth_api_key' => '0')
    post_mcp rpc('tools/list'), api_key_headers(User.find(2))
    assert_response :service_unavailable
  end

  def test_unknown_method_is_method_not_found
    post_mcp rpc('nonsense/method'), api_key_headers(User.find(2))
    assert_equal RedmineMcpPlugin::JsonRpc::METHOD_NOT_FOUND, json_body['error']['code']
  end

  # --- Origin -------------------------------------------------------------

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
  # caught by the Origin check.
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
end
