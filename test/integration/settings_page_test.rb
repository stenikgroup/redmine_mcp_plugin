# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class SettingsPageTest < Redmine::IntegrationTest
  fixtures :users, :email_addresses, :custom_fields

  def teardown
    Setting.clear_cache
  end

  def test_settings_page_lists_custom_fields_with_the_excluded_ones_checked
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('excluded_custom_fields' => %w[2])
    log_user('admin', 'admin')

    get '/settings/plugin/redmine_mcp_plugin'
    assert_response :success
    assert_select 'input[type=hidden][name=?][value=""]', 'settings[excluded_custom_fields][]'
    assert_select 'input#settings_excluded_custom_fields_2[checked=checked]'
    assert_select 'input#settings_excluded_custom_fields_1:not([checked])'
  end

  def test_saving_the_form_stores_the_checked_ids
    log_user('admin', 'admin')

    post '/settings/plugin/redmine_mcp_plugin', params: { settings: { excluded_custom_fields: ['', '1', '3'] } }
    assert_response :redirect
    Setting.clear_cache
    assert_equal [1, 3], RedmineMcpPlugin::Settings.excluded_custom_field_ids
  end
end
