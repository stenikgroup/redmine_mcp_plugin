# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The OAuth2 discovery documents name this Redmine by its configured address.
# Built from the Host header, a forged request would get a document that sends
# the client's OAuth2 flow to another server.
class McpDiscoveryTest < Redmine::IntegrationTest
  include McpTestHelper

  FORGED = { 'Host' => 'evil.example' }.freeze

  def setup
    enable_mcp
  end

  def teardown
    Setting.clear_cache
  end

  def test_protected_resource_names_the_configured_host_not_the_host_header
    with_settings host_name: 'redmine.example/tracker', protocol: 'https' do
      %w[/.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp].each do |path|
        get path, headers: FORGED
        assert_response :success
        document = JSON.parse(response.body)
        assert_equal 'https://redmine.example/tracker/mcp', document['resource']
        assert_equal ['https://redmine.example/tracker'], document['authorization_servers']
      end
    end
  end

  def test_authorization_server_names_the_configured_host_not_the_host_header
    with_settings host_name: 'redmine.example/tracker', protocol: 'https' do
      get '/.well-known/oauth-authorization-server', headers: FORGED
      assert_response :success
      document = JSON.parse(response.body)
      assert_equal 'https://redmine.example/tracker', document['issuer']
      assert_equal 'https://redmine.example/tracker/oauth/authorize', document['authorization_endpoint']
      assert_equal 'https://redmine.example/tracker/oauth/token', document['token_endpoint']
    end
  end

  def test_challenge_names_the_configured_host_not_the_host_header
    with_settings host_name: 'redmine.example/tracker', protocol: 'https' do
      post '/mcp', params: rpc('tools/list'), headers: FORGED.merge('Content-Type' => 'application/json')
      assert_response :unauthorized
      assert_includes response.headers['WWW-Authenticate'],
                      'resource_metadata="https://redmine.example/tracker/.well-known/oauth-protected-resource/mcp"'
    end
  end

  def test_documents_fall_back_to_the_request_when_no_host_name_is_set
    with_settings host_name: '' do
      get '/.well-known/oauth-protected-resource'
      assert_equal 'http://www.example.com/mcp', JSON.parse(response.body)['resource']
    end
  end

  def test_documents_are_not_served_while_oauth2_is_off
    enable_mcp('auth_oauth2' => '0')
    get '/.well-known/oauth-protected-resource'
    assert_response :not_found
  end
end
