# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The dispatcher without the HTTP layer: the methods it answers, and the two
# tiers of error a tool call can end in.
class RedmineMcpPluginDispatcherTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses, :roles, :members, :member_roles, :projects, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations, :projects_trackers

  J = RedmineMcpPlugin::JsonRpc

  class Exploding < RedmineMcpPlugin::Tool
    tool 'probe_exploding', title: 'Exploding', description: 'Raises.', schema: { 'type' => 'object', 'properties' => {} }

    private

    def perform(_arguments) = raise('SELECT secret FROM vault')
  end

  class Unfinished < RedmineMcpPlugin::Tool
    tool 'probe_unfinished', title: 'Unfinished', description: 'No perform.', schema: { 'type' => 'object' }
  end

  def setup
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1')
    Setting.clear_cache
    @user = User.find(2)
    User.current = @user
    @dispatcher = RedmineMcpPlugin::Dispatcher.new(user: @user, auth: { mode: :api_key })
  end

  def teardown
    RedmineMcpPlugin::Endpoint.send(:added).delete('probe_dispatcher')
    RedmineMcpPlugin::Endpoint.instance_variable_set(:@added_tools, nil)
    User.current = nil
    Setting.clear_cache
  end

  def call(method, params = nil)
    message = { 'jsonrpc' => '2.0', 'id' => 7, 'method' => method }
    message['params'] = params if params
    @dispatcher.call(message)
  end

  def test_ping_answers_an_empty_result
    assert_equal({ jsonrpc: '2.0', id: 7, result: {} }, call('ping'))
  end

  def test_initialize_falls_back_to_the_preferred_version_and_carries_instructions
    result = call('initialize', { 'protocolVersion' => '1999-01-01' })[:result]

    assert_equal RedmineMcpPlugin::PREFERRED_PROTOCOL_VERSION, result[:protocolVersion]
    assert result[:instructions].present?
    assert_equal({ tools: {} }, result[:capabilities])
  end

  def test_every_listed_tool_has_a_name_a_schema_and_annotations
    tools = call('tools/list')[:result][:tools]

    assert tools.any?
    tools.each do |tool|
      assert tool[:name].present?
      assert_equal 'object', tool[:inputSchema]['type'], tool[:name]
      assert_equal [true, false], [tool[:annotations][:readOnlyHint], tool[:annotations][:destructiveHint]], tool[:name]
    end
  end

  def test_a_tool_result_is_given_as_text_and_as_structure
    result = call('tools/call', { 'name' => 'whoami' })[:result]

    assert_equal false, result[:isError]
    assert_equal @user.id, result[:structuredContent][:id]
    assert_equal result[:structuredContent].as_json, JSON.parse(result[:content].first[:text])
    assert_equal 'complete', result[:resultType]
  end

  def test_an_unknown_tool_is_invalid_params
    error = call('tools/call', { 'name' => 'no_such_tool' })[:error]
    assert_equal J::INVALID_PARAMS, error[:code]
    assert_equal 'Unknown tool: no_such_tool', error[:message]
  end

  def test_arguments_that_are_not_an_object_are_a_tool_error
    result = call('tools/call', { 'name' => 'whoami', 'arguments' => 'now' })[:result]
    assert result[:isError]
    assert_equal 'arguments must be an object', result[:content].first[:text]
  end

  def test_an_unknown_argument_is_a_tool_error_the_model_can_act_on
    result = call('tools/call', { 'name' => 'whoami', 'arguments' => { 'verbose' => true } })[:result]
    assert result[:isError]
    assert_match 'Unknown argument: "verbose"', result[:content].first[:text]
  end

  # An exception from deep in Rails can carry SQL or record contents: it is
  # logged, and the caller is told nothing of it.
  def test_an_unexpected_error_is_logged_and_not_echoed
    RedmineMcpPlugin::Endpoint.add_tools('probe_dispatcher') { [Exploding] }
    io       = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    response = call('tools/call', { 'name' => 'probe_exploding' })
    Rails.logger = previous

    assert_equal J::INTERNAL_ERROR, response[:error][:code]
    assert_equal 'Internal error', response[:error][:message]
    assert_match 'RuntimeError: SELECT secret FROM vault', io.string
  ensure
    Rails.logger = previous if previous
  end

  # --- the base class ---------------------------------------------------------

  def test_a_tool_called_past_the_list_still_checks_its_permission
    Role.find_each { |role| role.remove_permission!(:view_issues) }

    error = assert_raises(RedmineMcpPlugin::PermissionError) do
      RedmineMcpPlugin::Tools::GetIssue.new(@user).call({ 'issue' => 1 })
    end
    assert_equal 'You do not have permission to use this tool', error.message
  end

  def test_a_write_tool_called_past_the_list_still_checks_read_only
    error = assert_raises(RedmineMcpPlugin::PermissionError) do
      RedmineMcpPlugin::Tools::CreateIssue.new(@user).call({ 'project' => 'ecookbook', 'subject' => 'x' })
    end
    assert_match 'read-only mode', error.message
  end

  def test_a_tool_without_perform_says_so
    assert_raises(NotImplementedError) { Unfinished.new(@user).call({}) }
  end

  # Indentation in the text copy is only tokens for the model that reads it.
  def test_the_text_copy_is_compact_json
    text = call('tools/call', { 'name' => 'list_projects', 'arguments' => { 'limit' => 2 } })[:result][:content].first[:text]

    assert_not_includes text, "\n"
    assert_not_includes text, '": '
    assert_equal 2, JSON.parse(text)['returned']
  end

  # --- one acting user -----------------------------------------------------------

  # Core reads User.current in places a tool cannot pass a user to: the base
  # scope of a query, the history helper. A tool sets it for its own call.
  def test_a_tool_acts_as_its_user_whoever_is_current
    User.current = nil
    seen   = nil
    probe  = Class.new(RedmineMcpPlugin::Tool) do
      tool 'probe_current', title: 'Probe', description: 'Reports User.current.', schema: { 'type' => 'object', 'properties' => {} }
      define_method(:perform) { |_arguments| seen = User.current }
      private :perform
    end
    probe.new(@user).call({})

    assert_equal @user, seen
    assert_equal User.anonymous, User.current
  end

  def test_a_query_tool_called_for_another_user_answers_for_that_user
    User.current = User.find(1)
    other = User.find(7)

    result = RedmineMcpPlugin::Tools::SearchIssues.new(other).call({ 'status' => 'all', 'limit' => 100 })
    ids    = result[:issues].map { |row| row[:id] }

    assert_equal Issue.visible(other).where(id: ids).pluck(:id).sort, ids.sort
    assert_operator Issue.visible(User.find(1)).count, :>, result[:total_count]
    assert_equal User.find(1), User.current
  end

  def test_the_current_user_is_put_back_when_a_tool_raises
    User.current = User.find(1)

    assert_raises(RedmineMcpPlugin::ToolError) do
      RedmineMcpPlugin::Tools::GetIssue.new(@user).call({ 'issue' => 999_999 })
    end
    assert_equal User.find(1), User.current
  end

  def test_a_tool_knows_how_its_user_authenticated
    token = RedmineMcpPlugin::Tools::WhoAmI.new(@user, { mode: :oauth2, scopes: %i[view_issues] })
    key   = RedmineMcpPlugin::Tools::WhoAmI.new(@user, { mode: :api_key })
    bare  = RedmineMcpPlugin::Tools::WhoAmI.new(@user, nil)

    assert token.oauth?
    assert_equal :oauth2, token.auth_mode
    assert_equal %i[view_issues], token.oauth_scopes
    assert_not key.oauth?
    assert_nil key.oauth_scopes
    assert_nil bare.auth_mode
  end
end
