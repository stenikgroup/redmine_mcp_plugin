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
end
