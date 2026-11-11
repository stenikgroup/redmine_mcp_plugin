# frozen_string_literal: true

require File.expand_path('../../../test/test_helper', __dir__)

# Redmine plugin tests run against the host application's test database and
# fixtures. From the Redmine root:
#
#   bin/rails redmine:plugins:test NAME=redmine_mcp_plugin RAILS_ENV=test

# What every functional test of /mcp needs: the settings, a JSON-RPC body, and a
# tool call under an API key.
module McpTestHelper
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

  def call_tool(name, arguments, user = User.find(2))
    post_mcp rpc('tools/call', { 'name' => name, 'arguments' => arguments }), api_key_headers(user)
    json_body['result']
  end

  # A successful tool result, as the structured reply.
  def state(result)
    assert result, json_body.inspect
    assert_not result['isError'], result.inspect
    result['structuredContent']
  end

  # A refused tool call, as the text the caller reads.
  def refusal(result)
    assert result, json_body.inspect
    assert result['isError'], result.inspect
    result['content'].first['text']
  end

  # The headers of an OAuth2 token of `user` narrowed to `scopes`.
  def bearer_headers_for(scopes, user = User.find(2))
    application = Doorkeeper::Application.create!(name: 'MCP test', redirect_uri: 'https://client.example/callback',
                                                  scopes: scopes)
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id, scopes: scopes,
                                            expires_in: 2.hours)
    { 'Authorization' => "Bearer #{token.plaintext_token}" }
  end

  # A tool call under such a token; the whole JSON-RPC body, since a tool the
  # token does not list is answered with an error and no result.
  def call_with_scopes(scopes, name, arguments = {})
    post_mcp rpc('tools/call', { 'name' => name, 'arguments' => arguments }), bearer_headers_for(scopes)
    json_body
  end
end
