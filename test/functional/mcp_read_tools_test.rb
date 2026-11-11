# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# The tools that only read: what each returns, and that it returns no more than
# the caller may see.
class McpReadToolsTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :watchers,
           :projects_trackers, :workflows, :custom_fields, :custom_fields_trackers,
           :custom_fields_projects, :custom_values, :time_entries, :versions, :journals, :journal_details,
           :queries, :attachments, :wikis, :wiki_pages, :wiki_contents, :wiki_content_versions,
           :issue_categories, :news, :documents, :boards, :messages

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('enabled' => '1')
    User.current = nil
    set_fixtures_attachments_directory
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  # --- visibility ---------------------------------------------------------

  def test_whoami_reports_the_authenticated_user
    post_mcp rpc('tools/call', { 'name' => 'whoami' }), api_key_headers(User.find(2))
    payload = json_body['result']['structuredContent']
    assert_equal 2, payload['id']
    assert_equal 'api_key', payload['authentication_mode']
    assert_nil payload['oauth_scopes']
  end

  # An invisible issue and a nonexistent one must be indistinguishable, or the
  # error message confirms the existence of records the caller cannot see.
  def test_invisible_issue_is_reported_as_not_found
    issue = Issue.find(4)
    issue.update_columns(is_private: true)
    post_mcp rpc('tools/call', { 'name' => 'get_issue', 'arguments' => { 'issue' => issue.id } }),
             api_key_headers(User.find(7))
    assert json_body['result']['isError']
    assert_match(/No visible issue/, json_body['result']['content'].first['text'])
  end

  def test_search_issues_only_returns_visible_rows
    user = User.find(7)
    post_mcp rpc('tools/call', { 'name' => 'search_issues', 'arguments' => { 'status' => 'all' } }),
             api_key_headers(user)
    returned = json_body['result']['structuredContent']['issues'].map { |i| i['id'] }
    assert_equal returned.sort, Issue.visible(user).where(id: returned).pluck(:id).sort
    assert Issue.count > returned.size, 'fixture set should be larger than what one user can see'
  end

  # list_users must not enumerate the directory: core's own users list is
  # admin-only and each role carries a users_visibility setting.
  def test_list_users_respects_users_visibility
    user = User.find(7)
    post_mcp rpc('tools/call', { 'name' => 'list_users' }), api_key_headers(user)
    total = json_body['result']['structuredContent']['total_count']
    assert_equal Principal.visible(user).where(type: 'User').active.count, total
  end

  # Core dropped Issue#addable_watcher_users (#43429); the plugin rebuilds the list
  # and must leave out current watchers and anyone outside the project.
  def test_get_issue_fields_lists_addable_watchers_without_current_ones
    issue = Issue.find(2)
    post_mcp rpc('tools/call', { 'name' => 'get_issue_fields', 'arguments' => { 'issue' => issue.id } }),
             api_key_headers(User.find(2))
    assert_not json_body['result']['isError'], json_body['result'].inspect
    ids = json_body['result']['structuredContent']['addable_watcher_users'].map { |p| p['id'] }
    assert ids.any?, 'a manager should be offered at least one watcher'
    assert_empty ids & issue.watcher_user_ids, 'current watchers must not be offered again'
    assert_empty ids - issue.project.principals.pluck(:id), 'only project members may watch'
  end

  # --- users and projects -----------------------------------------------------

  def test_list_users_filters_by_a_part_of_the_name_or_login
    result = state(call_tool('list_users', { 'name' => 'SMI' }))
    assert_includes result['users'].map { |row| row['login'] }, 'jsmith'
    assert(result['users'].all? { |row| "#{row['login']} #{row['name']}".downcase.include?('smi') })

    assert_equal 0, state(call_tool('list_users', { 'name' => 'no such person' }))['total_count']
  end

  def test_list_projects_filters_by_a_part_of_the_name_or_identifier
    result = state(call_tool('list_projects', { 'name' => 'COOK' }))
    assert_includes result['projects'].map { |row| row['identifier'] }, 'ecookbook'
    assert(result['projects'].all? { |row| "#{row['identifier']} #{row['name']}".downcase.include?('cook') })
  end

  # Core's API names a parent only to a caller who can see it.
  def test_projects_do_not_name_a_parent_the_caller_cannot_see
    hidden = Project.generate!(is_public: false)
    child  = Project.generate_with_parent!(hidden, is_public: true)
    row    = ->(result) { state(result)['projects'].detect { |project| project['id'] == child.id } }

    assert_nil row.call(call_tool('list_projects', { 'limit' => 100 }))['parent_id']
    assert_nil row.call(call_tool('list_projects', { 'limit' => 100, 'include_custom_fields' => true }))['parent_id']
    assert_nil state(call_tool('get_project', { 'project' => child.id }))['parent_id']

    admin = User.find(1)
    assert_equal hidden.id, row.call(call_tool('list_projects', { 'limit' => 100 }, admin))['parent_id']
    assert_equal hidden.id, state(call_tool('get_project', { 'project' => child.id }, admin))['parent_id']
  end

  def test_a_list_pages_with_offset_and_limit
    first  = state(call_tool('list_projects', { 'limit' => 1 }))
    second = state(call_tool('list_projects', { 'limit' => 1, 'offset' => 1 }))

    assert_equal 1, first['returned']
    assert first['has_more']
    assert_equal 1, second['offset']
    assert_not_equal first['projects'].first['id'], second['projects'].first['id']
  end

  # max_results is the administrator's ceiling, whatever the caller asks for.
  def test_a_limit_above_max_results_is_capped
    enable_mcp('max_results' => '2')
    assert_equal 2, state(call_tool('list_projects', { 'limit' => 50 }))['returned']
  end

  # --- wiki ------------------------------------------------------------------------

  def test_list_wiki_pages_lists_the_pages_of_a_project
    result = state(call_tool('list_wiki_pages', { 'project' => 'ecookbook' }))
    assert_equal Project.find(1).wiki.pages.count, result['total_count']
    assert_includes result['pages'].map { |page| page['title'] }, 'CookBook_documentation'
    assert(result['pages'].all? { |page| page['version'].present? })

    paged = state(call_tool('list_wiki_pages', { 'project' => 'ecookbook', 'limit' => 2, 'offset' => 1 }))
    assert_equal 2, paged['returned']
    assert_equal result['pages'][1]['title'], paged['pages'].first['title']
  end

  def test_wiki_tools_name_a_disabled_module_and_a_missing_page
    assert_match 'No wiki page titled "Nope"', refusal(call_tool('get_wiki_page', { 'project' => 'ecookbook', 'title' => 'Nope' }))

    Project.find(1).disable_module!(:wiki)
    assert_match 'The wiki module is not enabled for project ecookbook', refusal(call_tool('list_wiki_pages', { 'project' => 'ecookbook' }))
  end

  def test_wiki_tools_refuse_a_project_the_role_may_not_read_the_wiki_of
    Role.find_each { |role| role.remove_permission!(:view_wiki_pages) }
    post_mcp rpc('tools/call', { 'name' => 'list_wiki_pages', 'arguments' => { 'project' => 'ecookbook' } }),
             api_key_headers(User.find(2))
    assert_match 'Unknown tool', json_body.dig('error', 'message')
  end

  # --- saved queries ------------------------------------------------------------------

  def test_list_queries_lists_what_the_caller_may_run
    visible = IssueQuery.visible(User.find(2))
    result  = state(call_tool('list_queries', { 'limit' => 100 }))

    assert_equal visible.count, result['total_count']
    assert_equal visible.pluck(:id).sort, result['queries'].map { |row| row['id'] }.sort
    assert(result['queries'].all? { |row| row.key?('is_public') && row.key?('is_global') })
  end

  def test_list_queries_keeps_to_a_project_and_a_name
    in_project = state(call_tool('list_queries', { 'project' => 'ecookbook', 'limit' => 100 }))
    assert_equal IssueQuery.visible(User.find(2)).global_or_on_project(Project.find(1)).count, in_project['total_count']
    assert(in_project['queries'].all? { |row| row['is_global'] || row['project_identifier'] == 'ecookbook' })

    query = IssueQuery.visible(User.find(2)).first
    named = state(call_tool('list_queries', { 'name' => query.name.upcase }))
    assert_includes named['queries'].map { |row| row['id'] }, query.id
  end

  # --- attachments ------------------------------------------------------------------------

  def test_get_attachment_returns_a_text_file_with_its_content
    set_tmp_attachments_directory
    enable_mcp('read_only' => '0')
    added  = state(call_tool('add_issue_attachment', { 'issue' => 1, 'filename' => 'trace.log', 'content' => "line one\nline two" }))
    result = state(call_tool('get_attachment', { 'attachment' => added['id'] }))

    assert_equal 'trace.log', result['filename']
    assert_equal "line one\nline two", result['content']
    assert_not result.key?('content_omitted')
  end

  def test_get_attachment_says_why_a_content_is_left_out
    with_settings file_max_size_displayed: 0 do
      assert_equal 'larger than 0 KB', state(call_tool('get_attachment', { 'attachment' => 1 }))['content_omitted']
    end

    binary = Attachment.generate!(container: Issue.find(1), filename: 'picture.png')
    assert_equal 'binary', state(call_tool('get_attachment', { 'attachment' => binary.id }))['content_omitted']

    gone = Attachment.generate!(container: Issue.find(1), filename: 'gone.txt')
    gone.update_columns(disk_filename: 'no_such_file.txt', filesize: 10)
    assert_equal 'file missing on disk', state(call_tool('get_attachment', { 'attachment' => gone.id }))['content_omitted']
  end

  # The same answer for a missing file and one of an issue the caller cannot see.
  def test_get_attachment_does_not_confirm_a_file_the_caller_cannot_see
    hidden = Attachment.generate!(container: Issue.generate!(project: Project.generate!(is_public: false)), filename: 'secret.txt')

    assert_match 'No visible attachment with id', refusal(call_tool('get_attachment', { 'attachment' => hidden.id }))
    assert_match 'No visible attachment with id', refusal(call_tool('get_attachment', { 'attachment' => 999_999 }))
  end

  # --- the fields of an issue ------------------------------------------------------------------

  def test_get_issue_fields_for_an_issue_not_yet_created
    enable_mcp('read_only' => '0')
    result = state(call_tool('get_issue_fields', { 'project' => 'ecookbook', 'tracker' => 'Feature request' }))
    assert_kind_of Array, result['custom_fields']

    default = state(call_tool('get_issue_fields', { 'project' => 'ecookbook' }))
    assert_kind_of Array, default['custom_fields']
  end

  def test_get_issue_fields_for_an_issue_as_another_tracker
    enable_mcp('read_only' => '0')
    result = state(call_tool('get_issue_fields', { 'issue' => 1, 'tracker' => 'Feature request' }))
    assert_kind_of Array, result['custom_fields']
    assert_equal 1, Issue.find(1).tracker_id
  end

  def test_get_issue_fields_refuses_what_it_cannot_describe
    assert_match 'Pass issue for an existing issue, or project for one not yet created', refusal(call_tool('get_issue_fields', {}))
    assert_match 'Project ecookbook has no tracker named "Nope"',
                 refusal(call_tool('get_issue_fields', { 'project' => 'ecookbook', 'tracker' => 'Nope' }))

    Role.find_each { |role| role.remove_permission!(:add_issues) }
    assert_match 'do not have permission', refusal(call_tool('get_issue_fields', { 'project' => 'ecookbook' }))
  end

  # --- search ---------------------------------------------------------------------------------

  def test_search_keeps_to_the_scope_asked_for
    mine = state(call_tool('search', { 'q' => 'ecookbook', 'scope' => 'my_projects', 'types' => ['projects'] }))
    assert_includes mine['results'].map { |row| row['title'] }.join, 'eCookbook'

    assert_equal 0, state(call_tool('search', { 'q' => 'ecookbook', 'scope' => 'bookmarks', 'types' => ['projects'] }))['total_count']

    family = state(call_tool('search', { 'q' => 'issue', 'project' => 'ecookbook', 'scope' => 'subprojects', 'types' => ['issues'] }))
    assert_kind_of Array, family['results']
  end
end
