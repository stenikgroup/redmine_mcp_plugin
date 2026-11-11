# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Endpoint.add_tools is how another plugin adds tools to /mcp. Each rule it
# checks is one a broken extension would otherwise turn into a broken server.
class RedmineMcpPluginEndpointTest < ActiveSupport::TestCase
  fixtures :users, :roles, :members, :member_roles, :projects

  E = RedmineMcpPlugin::Endpoint

  def setup
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1', 'read_only' => '0')
    Setting.clear_cache
    @registered = []
  end

  def teardown
    @registered.each { |name| E.send(:added).delete(name) }
    E.instance_variable_set(:@added_tools, nil)
    Setting.clear_cache
  end

  def add(extension, &)
    @registered << extension
    E.add_tools(extension, &)
  end

  def probe(name, **options)
    Class.new(RedmineMcpPlugin::Tool) do
      tool name, title: 'Probe', description: 'A test tool.', schema: { 'type' => 'object', 'properties' => {} }, **options

      private

      def perform(_arguments) = { probe: self.class.mcp_name }
    end
  end

  def log_of
    previous = Rails.logger
    io       = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = previous
  end

  def test_an_added_tool_is_served_after_the_built_in_ones
    tool = probe('probe_served')
    add('probe_plugin') { [tool] }

    assert_equal RedmineMcpPlugin::Registry.all, E.tools.first(RedmineMcpPlugin::Registry.all.size)
    assert_includes E.tools, tool
    assert_equal tool, E.find('probe_served', User.find(2))
    assert_equal({ probe: 'probe_served' }, tool.new(User.find(2)).call({}))
  end

  def test_an_added_tool_follows_its_permission_and_the_read_only_mode
    reader = probe('probe_reader', permission: :view_issues)
    writer = probe('probe_writer', permission: :edit_issues, write: true)
    add('probe_plugin') { [reader, writer] }

    assert_includes E.visible_to(User.find(2)), reader
    assert_includes E.visible_to(User.find(2)), writer
    assert_nil E.find('probe_reader', User.anonymous.tap { Role.anonymous.remove_permission!(:view_issues) })

    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1')
    Setting.clear_cache
    assert_not_includes E.visible_to(User.find(2)), writer
    assert_includes E.visible_to(User.find(2)), reader
  end

  def test_a_block_that_does_not_return_tools_adds_nothing_and_is_logged
    log = log_of do
      add('probe_broken') { 'not a list' }
      assert_equal RedmineMcpPlugin::Registry.all, E.tools
    end
    assert_match 'probe_broken adds no tools to /mcp', log
    assert_match 'the block must return a list of RedmineMcpPlugin::Tool subclasses', log

    add('probe_classes') { [String] }
    assert_equal RedmineMcpPlugin::Registry.all, E.tools
  end

  def test_a_tool_name_already_taken_is_refused
    log = log_of do
      add('probe_clash') { [probe('whoami')] }
      assert_equal RedmineMcpPlugin::Registry.all, E.tools
    end
    assert_match 'tool name whoami is taken', log
  end

  def test_two_extensions_cannot_share_a_name_and_the_first_keeps_it
    first  = probe('probe_shared')
    second = probe('probe_shared')
    add('probe_one') { [first] }
    add('probe_two') { [second] }

    assert_includes E.tools, first
    assert_not_includes E.tools, second
  end

  def test_a_permission_redmine_does_not_know_is_refused
    log = log_of do
      add('probe_permission') { [probe('probe_unknown', permission: :no_such_permission)] }
      assert_equal RedmineMcpPlugin::Registry.all, E.tools
    end
    assert_match 'no_such_permission is not a Redmine permission', log
  end

  # A tool tied to a plugin that is not installed is never served, so its
  # permissions need not exist.
  def test_a_tool_of_an_absent_plugin_is_accepted_and_not_served
    tool = probe('probe_absent', permission: :no_such_permission, plugin: :no_such_plugin)
    add('probe_plugin') { [tool] }

    assert_includes E.tools, tool
    assert_not_includes E.visible_to(User.find(1)), tool
  end

  def test_a_failing_extension_leaves_the_others_served
    good = probe('probe_good')
    add('probe_failing') { raise 'boom' }
    add('probe_working') { [good] }

    log = log_of { assert_includes E.tools, good }
    assert_match 'probe_failing adds no tools to /mcp: RuntimeError: boom', log
  end

  def test_registering_again_under_the_same_name_replaces_the_tools
    old     = probe('probe_old')
    current = probe('probe_current')
    add('probe_plugin') { [old] }
    assert_includes E.tools, old

    add('probe_plugin') { [current] }
    assert_includes E.tools, current
    assert_not_includes E.tools, old
  end

  # A keyword the validator does not enforce is served and checked by nobody:
  # the tool is kept, and the log says what it promises in vain.
  def test_a_schema_keyword_that_is_not_enforced_is_logged_and_the_tool_kept
    loose = Class.new(RedmineMcpPlugin::Tool) do
      tool 'probe_loose', title: 'Probe', description: 'A test tool.',
                          schema: { 'type' => 'object', 'properties' => { 'limit' => { 'type' => 'integer', 'maximum' => 10 } } }
    end
    add('probe_plugin') { [loose] }

    log = log_of { assert_includes E.tools, loose }
    assert_match 'probe_loose declares what /mcp does not enforce: limit: maximum', log
  end
end
