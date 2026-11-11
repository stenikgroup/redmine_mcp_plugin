# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# What a request must be before any tool runs: where it may come from, and
# which credential each mode takes. One request per test, since the headers set
# on @request stay for the next call.
class McpRequestSecurityTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp
    User.current = nil
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  def basic_headers(username, password)
    { 'Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
  end

  # A browser's fetch: a JSON body, and no format in the path. post_mcp's
  # `as: :json` adds format=json to the parameters, which makes the request an
  # API request to core, and Redmine 7 gives those an empty session.
  def post_from_browser(payload, origin: nil, content_type: 'application/json')
    @request.session[:user_id] = 2
    @request.headers['Origin'] = origin if origin
    @request.headers['CONTENT_TYPE'] = content_type
    post :handle, body: payload
  end

  # --- Origin ---------------------------------------------------------------

  # Under DNS rebinding the Host header carries the attacker's domain, as the
  # Origin does. Comparing the two would let the page through.
  def test_origin_matching_only_the_host_header_is_rejected
    with_settings host_name: 'redmine.example', protocol: 'https' do
      @request.host = 'evil.example'
      post_mcp rpc('tools/list'), api_key_headers(User.find(2)).merge('Origin' => 'http://evil.example')
      assert_response :forbidden
    end
  end

  def test_origin_of_the_configured_host_is_allowed_whatever_its_sub_path
    with_settings host_name: 'redmine.example/tracker', protocol: 'https' do
      post_mcp rpc('tools/list'), api_key_headers(User.find(2)).merge('Origin' => 'https://redmine.example')
      assert_response :success
    end
  end

  def test_origin_falls_back_to_the_request_when_no_host_name_is_set
    with_settings host_name: '' do
      post_mcp rpc('tools/list'), api_key_headers(User.find(2)).merge('Origin' => 'http://test.host')
      assert_response :success
    end
  end

  # --- API key ----------------------------------------------------------------

  # Rails merges the JSON body into params, where ?key= would land too.
  def test_an_api_key_outside_the_header_is_not_read
    body = { jsonrpc: '2.0', id: 1, method: 'tools/list', key: User.find(2).api_key }.to_json
    post_mcp body
    assert_response :unauthorized
  end

  # --- HTTP Basic ---------------------------------------------------------------

  def test_basic_takes_a_login_and_password
    enable_mcp('auth_basic' => '1')
    post_mcp rpc('tools/list'), basic_headers('jsmith', 'jsmith')
    assert_response :success
  end

  def test_basic_is_refused_while_its_mode_is_off
    post_mcp rpc('tools/list'), basic_headers('jsmith', 'jsmith')
    assert_response :unauthorized
  end

  def test_basic_takes_an_api_key_while_the_api_key_mode_is_on
    enable_mcp('auth_basic' => '1')
    post_mcp rpc('tools/list'), basic_headers(User.find(2).api_key, 'x')
    assert_response :success
  end

  def test_basic_refuses_an_api_key_once_the_api_key_mode_is_off
    enable_mcp('auth_basic' => '1', 'auth_api_key' => '0')
    post_mcp rpc('tools/list'), basic_headers(User.find(2).api_key, 'x')
    assert_response :unauthorized
  end

  # --- session cookie -----------------------------------------------------------

  def test_session_request_from_this_redmine_is_accepted
    enable_mcp('auth_session' => '1')
    with_settings host_name: 'redmine.example', protocol: 'https' do
      post_from_browser rpc('tools/list'), origin: 'https://redmine.example'
      assert_response :success
    end
  end

  def test_session_request_from_another_site_is_rejected
    enable_mcp('auth_session' => '1')
    with_settings host_name: 'redmine.example', protocol: 'https' do
      post_from_browser rpc('tools/list'), origin: 'https://evil.example'
      assert_response :forbidden
    end
  end

  def test_session_request_with_no_origin_is_rejected
    enable_mcp('auth_session' => '1')
    post_from_browser rpc('tools/list')
    assert_response :forbidden
    assert_match 'Origin', json_body['error']
  end

  # What a cross-site HTML form can send without a CORS preflight.
  def test_session_request_that_is_not_json_is_rejected
    enable_mcp('auth_session' => '1')
    with_settings host_name: 'redmine.example', protocol: 'https' do
      post_from_browser rpc('tools/list'), origin: 'https://redmine.example', content_type: 'text/plain'
      assert_response :forbidden
      assert_match 'Content-Type', json_body['error']
    end
  end

  def test_session_is_refused_while_its_mode_is_off
    post_from_browser rpc('tools/list')
    assert_response :unauthorized
  end
end
