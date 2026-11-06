# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Core's .visible scopes read roles and ignore OAuth scopes, so every tool
# that reads a record must also go through the scope-aware allowed_to?.
class OauthScopeTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :watchers,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :versions, :journals, :journal_details,
           :news, :comments

  def setup
    Setting.rest_api_enabled = '1'
    Setting.plugin_redmine_mcp_plugin =
      RedmineMcpPlugin::Settings::DEFAULTS.merge('enabled' => '1', 'read_only' => '0')
    Setting.clear_cache
    @client = Doorkeeper::Application.create!(name: 'MCP client', redirect_uri: 'http://127.0.0.1:4567/callback',
                                              scopes: 'view_project view_issues view_private_notes view_news ' \
                                                      'edit_issues add_issue_notes manage_news')
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  # A token for jsmith (user 2), manager of project 1.
  def bearer(scopes)
    token = Doorkeeper::AccessToken.create!(application_id: @client.id, resource_owner_id: 2, scopes: scopes,
                                            expires_in: 3600)
    { 'Authorization' => "Bearer #{token.respond_to?(:plaintext_token) && token.plaintext_token || token.token}" }
  end

  def call_tool(headers, name, arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments } }.to_json
    post '/mcp', params: body,
                 headers: headers.merge('CONTENT_TYPE' => 'application/json',
                                        'Accept' => 'application/json, text/event-stream')
    JSON.parse(response.body)['result']
  end

  def assert_invisible_issue(result)
    assert result['isError'], result.inspect
    assert_match(/No visible issue/, result['content'].first['text'])
  end

  # --- write tools --------------------------------------------------------

  # Core's REST API answers 403 to these tokens: they may edit but not view.
  def test_issue_write_tools_refuse_a_token_without_view_issues
    issue      = Issue.find(1)
    start_date = issue.start_date
    watchers   = issue.watcher_user_ids
    journals   = issue.journals.count

    edit = bearer('edit_issues')
    assert_invisible_issue call_tool(edit, 'update_issue', { issue: 1, start_date: '2006-07-01' })
    assert_invisible_issue call_tool(edit, 'update_issue', { issue: 1, add_watcher_users: ['me'] })
    notes = bearer('add_issue_notes')
    assert_invisible_issue call_tool(notes, 'add_issue_note', { issue: 1, notes: 'Hidden' })
    assert_invisible_issue call_tool(notes, 'add_issue_attachment', { issue: 1, filename: 'a.txt', content: 'x' })

    issue.reload
    assert_equal start_date, issue.start_date
    assert_equal watchers, issue.watcher_user_ids
    assert_equal journals, issue.journals.count
  end

  def test_issue_write_tools_accept_a_token_with_view_issues
    result = call_tool(bearer('view_issues add_issue_notes'), 'add_issue_note', { issue: 1, notes: 'Seen' })
    assert_not result['isError'], result.inspect
  end

  def test_update_news_refuses_a_token_without_view_news
    title  = News.find(1).title
    result = call_tool(bearer('manage_news'), 'update_news', { news: 1, title: 'Hidden' })
    assert result['isError'], result.inspect
    assert_match(/No visible news/, result['content'].first['text'])
    assert_equal title, News.find(1).title

    result = call_tool(bearer('view_news manage_news'), 'update_news', { news: 1, title: 'Seen' })
    assert_not result['isError'], result.inspect
    assert_equal 'Seen', News.find(1).title
  end

  # --- private notes ------------------------------------------------------

  def journal_ids(headers)
    result = call_tool(headers, 'get_issue', { issue: 1 })
    assert_not result['isError'], result.inspect
    result['structuredContent']['journals'].map { |journal| journal['id'] }
  end

  def test_private_notes_need_the_view_private_notes_scope
    Role.find(1).add_permission!(:view_private_notes)
    theirs = Journal.create!(journalized: Issue.find(1), user: User.find(1), notes: 'Theirs', private_notes: true)
    own    = Journal.create!(journalized: Issue.find(1), user: User.find(2), notes: 'Own', private_notes: true)

    narrow = journal_ids(bearer('view_project view_issues'))
    assert_not_includes narrow, theirs.id
    assert_includes narrow, own.id

    assert_includes journal_ids(bearer('view_project view_issues view_private_notes')), theirs.id
    assert_includes journal_ids('X-Redmine-API-Key' => User.find(2).api_key), theirs.id
  end

  def test_view_private_notes_is_advertised
    get '/.well-known/oauth-protected-resource'
    assert_includes JSON.parse(response.body)['scopes_supported'], 'view_private_notes'
  end
end
