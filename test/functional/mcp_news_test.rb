# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The news tools, read and write, each under the permission core has for it.
class McpNewsTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules,
           :news, :comments

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  # --- read -------------------------------------------------------------------

  def test_list_news_lists_what_the_caller_may_read_newest_first
    result = state(call_tool('list_news', {}))

    assert_equal News.visible(User.find(2)).count, result['total_count']
    dates = result['news'].map { |row| row['created_on'] }
    assert_equal dates.sort.reverse, dates
    assert(result['news'].none? { |row| row.key?('description') })
  end

  def test_list_news_of_a_project_with_its_descriptions
    result = state(call_tool('list_news', { 'project' => 'ecookbook', 'include_description' => true, 'limit' => 1 }))

    assert_equal Project.find(1).news.count, result['total_count']
    assert_equal 1, result['returned']
    assert result['has_more']
    assert result['news'].first['description'].present?
    assert_equal 'ecookbook', result['news'].first['project']['identifier']
  end

  def test_list_news_between_two_dates
    news = News.find(1)
    day  = news.created_on.to_date.iso8601

    result = state(call_tool('list_news', { 'from' => day, 'to' => day }))
    assert_includes result['news'].map { |row| row['id'] }, news.id
    assert_equal News.visible(User.find(2)).where(created_on: news.created_on.to_date.all_day).count, result['total_count']

    assert_equal 0, state(call_tool('list_news', { 'to' => '1999-12-31' }))['total_count']
  end

  def test_list_news_refuses_dates_it_cannot_use_and_a_project_without_news
    assert_match 'from must not be after to', refusal(call_tool('list_news', { 'from' => '2026-02-01', 'to' => '2026-01-01' }))
    assert_match 'from must be an ISO-8601 date', refusal(call_tool('list_news', { 'from' => 'last week' }))

    Project.find(1).disable_module!(:news)
    assert_match 'The news module is not enabled for project ecookbook', refusal(call_tool('list_news', { 'project' => 'ecookbook' }))
  end

  def test_get_news_returns_the_item_and_its_comments
    result = state(call_tool('get_news', { 'news' => 1 }))

    assert_equal News.find(1).title, result['title']
    assert_equal News.find(1).comments.count, result['comments'].size
    assert result['comments'].first['content'].present?
    assert_match 'No visible news with id', refusal(call_tool('get_news', { 'news' => 999_999 }))
  end

  def test_news_tools_refuse_a_token_without_view_news
    assert_match 'Unknown tool', call_with_scopes('view_project', 'list_news').dig('error', 'message')
    assert_match 'Unknown tool', call_with_scopes('view_project', 'get_news', { 'news' => 1 }).dig('error', 'message')
  end

  # --- write --------------------------------------------------------------------

  def test_create_news_then_update_it
    created = state(call_tool('create_news', { 'project' => 'ecookbook', 'title' => 'Released', 'summary' => 'Out now',
                                               'description' => 'The **1.0** is out.' }))
    news = News.find(created['id'])
    assert_equal 'Released', news.title
    assert_equal 'Out now', news.summary
    assert_equal User.find(2), news.author
    assert_equal 'ecookbook', created['project_identifier']

    updated = state(call_tool('update_news', { 'news' => news.id, 'title' => 'Released at last' }))
    assert_equal 'Released at last', updated['title']
    assert_equal 'Out now', news.reload.summary
  end

  def test_create_news_reports_what_core_refuses
    assert_no_difference 'News.count' do
      text = refusal(call_tool('create_news', { 'project' => 'ecookbook', 'title' => 'x' * 61, 'description' => 'Body' }))
      assert_match 'Could not create news: ', text
    end

    Project.find(1).disable_module!(:news)
    assert_match 'The news module is not enabled', refusal(call_tool('create_news', { 'project' => 'ecookbook', 'title' => 'T',
                                                                                      'description' => 'Body' }))
  end

  def test_create_news_needs_manage_news
    Role.find_each { |role| role.remove_permission!(:manage_news) }
    post_mcp rpc('tools/call', { 'name' => 'create_news',
                                 'arguments' => { 'project' => 'ecookbook', 'title' => 'T', 'description' => 'Body' } }),
             api_key_headers(User.find(2))
    assert_match 'Unknown tool', json_body.dig('error', 'message')
  end

  # The role may manage news everywhere it is a manager; the project asked for decides.
  def test_create_news_is_refused_in_a_project_where_the_role_lacks_it
    Role.find(2).remove_permission!(:manage_news)
    assert_no_difference 'News.count' do
      text = refusal(call_tool('create_news', { 'project' => 'onlinestore', 'title' => 'T', 'description' => 'Body' }))
      assert_match(/do not have permission|not enabled/, text)
    end
  end
end
