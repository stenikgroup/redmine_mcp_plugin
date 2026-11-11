# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require File.expand_path('../support/plugin_stand_ins', __dir__)

# A third-party plugin is usable when it is installed and still has what the
# tools call. One that does not is treated as absent, and said once.
class RedmineMcpPluginIntegrationsTest < ActiveSupport::TestCase
  I = RedmineMcpPlugin::Integrations

  def setup
    I.reset!
  end

  def teardown
    Redmine::Plugin.unstub(:installed?)
    I.reset!
  end

  def installed(*ids)
    Redmine::Plugin.stubs(:installed?).returns(false)
    ids.each { |id| Redmine::Plugin.stubs(:installed?).with(id).returns(true) }
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

  def test_a_plugin_that_is_not_installed_is_not_usable
    installed
    assert_not I.usable?(:redmine_checklists)
    assert_not I.usable?(:redmineup_tags)
    assert_not RedmineMcpPlugin::Tool.plugin?(:redmine_checklists)
  end

  def test_an_installed_plugin_that_has_everything_is_usable
    installed(:redmine_checklists, :redmineup_tags)

    assert_equal [], I.missing(:redmine_checklists)
    assert_equal [], I.missing(:redmineup_tags)
    assert I.usable?(:redmine_checklists)
    assert RedmineMcpPlugin::Tool.plugin?(:redmineup_tags)
  end

  def test_an_installed_plugin_that_lost_a_name_is_not_usable_and_is_said_once
    installed(:redmine_checklists, :redmineup_tags)
    I.stubs(:listener?).returns(false)

    log = log_of do
      assert_not I.usable?(:redmine_checklists)
      assert_not I.usable?(:redmine_checklists)
      assert_not I.usable?(:redmineup_tags)
    end
    assert_equal ['RedmineChecklists::Hooks::ControllerIssuesHook#controller_issues_edit_after_save'], I.missing(:redmine_checklists)
    assert_equal 1, log.scan(/redmine_checklists.*not usable/).size
    assert_match 'it has no RedmineupTags::Hooks::ModelIssueHook#controller_issues_edit_before_save', log
  end

  def test_a_listener_is_a_singleton_that_answers_the_hook
    assert I.send(:listener?, 'RedmineChecklists::Hooks::ControllerIssuesHook', :controller_issues_edit_after_save)
    assert_not I.send(:listener?, 'RedmineChecklists::Hooks::ControllerIssuesHook', :no_such_hook)
    assert_not I.send(:listener?, 'No::Such::Listener', :controller_issues_edit_after_save)
    assert_not I.send(:listener?, 'String', :upcase)
  end

  # A plugin no tool reaches into has no contract: installed is enough.
  def test_a_plugin_with_no_contract_is_usable_when_installed
    installed(:some_other_plugin)
    assert I.usable?(:some_other_plugin)
    assert_equal [], I.missing(:some_other_plugin)
  end

  def test_the_boot_report_checks_every_contract_and_never_raises
    installed(:redmine_checklists)
    I.stubs(:listener?).returns(false)

    log = log_of { assert_nothing_raised { I.report } }
    assert_match(/redmine_checklists.*not usable/, log)
    assert_no_match(/redmineup_tags/, log)
  end
end
