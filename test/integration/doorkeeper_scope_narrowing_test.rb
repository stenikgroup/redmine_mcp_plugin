# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# An application that enables fewer scopes than the server advertises must still connect, with a
# token narrowed to what it enables.
class DoorkeeperScopeNarrowingTest < Redmine::IntegrationTest
  fixtures :users, :email_addresses

  REQUESTED = 'view_project view_issues delete_issues'

  def setup
    Setting.rest_api_enabled = '1'
    # No configured address: the resource is then the one the test request is made to.
    Setting.host_name = ''
    Setting.plugin_redmine_mcp_plugin =
      RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1', 'read_only' => '0')
    Setting.clear_cache
    @client = Doorkeeper::Application.create!(name: 'MCP client', redirect_uri: 'http://127.0.0.1:4567/callback',
                                              scopes: 'view_project view_issues')
    log_user('jsmith', 'jsmith')
  end

  def teardown
    Setting.clear_cache
  end

  def authorize_params(extra = {})
    { client_id: @client.uid, redirect_uri: @client.redirect_uri, response_type: 'code',
      scope: REQUESTED, state: 'xyz', resource: 'http://www.example.com/mcp' }.merge(extra)
  end

  def test_consent_is_narrowed_to_the_scopes_the_application_enables
    get '/oauth/authorize', params: authorize_params
    assert_response :success
    assert_select 'input[name=scope][value=?]', 'view_project view_issues'
  end

  def test_the_grant_carries_the_narrowed_scopes
    post '/oauth/authorize', params: authorize_params
    assert_response :redirect
    assert_match(/code=/, response.location)
    assert_equal 'view_project view_issues', Doorkeeper::AccessGrant.last.scopes.to_s
  end

  def test_a_request_with_no_enabled_scope_is_still_refused
    get '/oauth/authorize', params: authorize_params(scope: 'delete_issues')
    assert_response :bad_request
    assert_equal 0, Doorkeeper::AccessGrant.count
  end

  def test_a_request_for_another_resource_keeps_doorkeepers_behaviour
    get '/oauth/authorize', params: authorize_params(resource: nil)
    assert_response :bad_request

    get '/oauth/authorize', params: authorize_params(resource: 'http://www.example.com/other')
    assert_response :bad_request
  end

  def test_nothing_is_narrowed_while_oauth2_is_off
    Setting.plugin_redmine_mcp_plugin =
      RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1', 'auth_oauth2' => '0')
    Setting.clear_cache

    get '/oauth/authorize', params: authorize_params
    assert_response :bad_request
  end

  def test_narrow_leaves_alone_what_it_cannot_narrow
    narrowing = RedmineMcpPlugin::DoorkeeperScopeNarrowing
    assert_nil narrowing.narrow(nil, @client.uid)
    assert_equal REQUESTED, narrowing.narrow(REQUESTED, 'unknown')
    assert_equal REQUESTED, narrowing.narrow(REQUESTED, nil)
    assert_equal 'view_issues', narrowing.narrow('view_issues delete_issues', @client.uid)
  end
end
