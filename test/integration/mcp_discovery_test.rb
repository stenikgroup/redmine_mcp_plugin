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
  # --- what the documents advertise ---------------------------------------------

  def test_scopes_follow_the_read_only_mode
    get '/.well-known/oauth-protected-resource'
    read_only = JSON.parse(response.body)['scopes_supported']
    assert_includes read_only, 'view_issues'
    assert_not_includes read_only, 'add_issues'
    assert_not_includes read_only, 'admin'

    enable_mcp('read_only' => '0')
    get '/.well-known/oauth-protected-resource'
    assert_includes JSON.parse(response.body)['scopes_supported'], 'add_issues'
  end

  def test_both_documents_advertise_the_same_scopes
    get '/.well-known/oauth-protected-resource'
    resource = JSON.parse(response.body)
    get '/.well-known/oauth-authorization-server'
    server = JSON.parse(response.body)

    assert_equal resource['scopes_supported'], server['scopes_supported']
    assert_equal %w[header], resource['bearer_methods_supported']
    assert_equal %w[code], server['response_types_supported']
    assert_equal %w[authorization_code refresh_token], server['grant_types_supported']
    assert_not server.key?('registration_endpoint')
  end

  # MCP requires S256; plain is never offered, even when Doorkeeper has it.
  def test_pkce_is_advertised_as_s256_only
    get '/.well-known/oauth-authorization-server'
    assert_includes [nil, %w[S256]], JSON.parse(response.body)['code_challenge_methods_supported']
  end

  def test_the_authorization_server_document_is_not_served_while_the_endpoint_is_off
    enable_mcp('enabled' => '0')
    get '/.well-known/oauth-authorization-server'
    assert_response :not_found
  end

  # A Doorkeeper that cannot be asked must not take the documents down.
  def test_a_doorkeeper_that_fails_leaves_the_documents_served_without_scopes
    McpMetadataController.any_instance.stubs(:doorkeeper_config).raises(RuntimeError, 'no configuration')

    get '/.well-known/oauth-authorization-server'
    assert_response :success
    document = JSON.parse(response.body)
    assert_equal [], document['scopes_supported']
    assert_not document.key?('code_challenge_methods_supported')
  end

  # An older Doorkeeper has no list of PKCE methods to ask for; the column that
  # stores the challenge is then what says whether S256 can be honoured.
  def test_pkce_is_read_from_the_grants_table_when_doorkeeper_does_not_say
    older = Struct.new(:scopes).new(Doorkeeper.config.scopes)
    McpMetadataController.any_instance.stubs(:doorkeeper_config).returns(older)

    get '/.well-known/oauth-authorization-server'
    document = JSON.parse(response.body)
    expected = Doorkeeper::AccessGrant.column_names.include?('code_challenge') ? %w[S256] : nil
    assert_equal expected, document['code_challenge_methods_supported']
    assert_includes document['scopes_supported'], 'view_issues'
  end
end
