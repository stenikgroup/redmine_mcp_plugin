# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class DoorkeeperUrlOptionsTest < Redmine::IntegrationTest
  fixtures :users, :email_addresses

  def setup
    Setting.rest_api_enabled = '1'
    Redmine::SudoMode.stubs(:enabled?).returns(true)
    @client = Doorkeeper::Application.create!(name: 'MCP client', redirect_uri: 'http://127.0.0.1:4567/callback',
                                           scopes: 'view_project view_issues')
  end

  def teardown
    travel_back
    Setting.clear_cache
  end

  def authorize_params
    { client_id: @client.uid, redirect_uri: @client.redirect_uri, response_type: 'code',
      scope: 'view_project view_issues', state: 'xyz' }
  end

  # Clicking Authorize with sudo mode expired renders core's password form, whose
  # `form_tag({})` posts back to the current route through the recalled controller.
  def test_sudo_form_on_consent_posts_back_to_the_authorize_route
    log_user('jsmith', 'jsmith')
    travel_to 20.minutes.from_now

    post '/oauth/authorize', params: authorize_params
    assert_response :success
    assert_select 'form#sudo-form[action=?]', '/oauth/authorize'
  end

  def test_relative_controller_resolves_from_the_root_inside_doorkeeper
    log_user('jsmith', 'jsmith')

    get '/oauth/authorize', params: authorize_params
    assert_response :success
    assert_equal '/my/account', @controller.view_context.url_for(controller: 'my', action: 'account')
    assert_equal '/oauth/authorize', @controller.view_context.url_for({})
  end
end
