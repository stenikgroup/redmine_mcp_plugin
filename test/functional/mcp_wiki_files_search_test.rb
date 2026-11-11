# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Writing the wiki and reading its history, the Files module, and the search
# box: each under the permission core has for it.
class McpWikiFilesSearchTest < Redmine::ControllerTest
  include McpTestHelper

  tests McpController
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules,
           :projects_trackers, :workflows, :versions, :attachments, :news, :documents,
           :wikis, :wiki_pages, :wiki_contents, :wiki_content_versions,
           :boards, :messages, :repositories, :changesets

  def setup
    Setting.rest_api_enabled = '1'
    enable_mcp('read_only' => '0')
    User.current = nil
    set_tmp_attachments_directory
    # jsmith is a manager on ecookbook; the role is given what each test then takes away.
    Role.find(1).add_permission!(:edit_wiki_pages, :view_wiki_edits, :rename_wiki_pages, :protect_wiki_pages,
                                 :view_files, :manage_files)
  end

  def teardown
    Setting.clear_cache
    User.current = nil
  end

  def state(result)
    assert result, json_body.inspect
    assert_not result['isError'], result.inspect
    result['structuredContent']
  end

  def refusal(result)
    assert result, json_body.inspect
    assert result['isError'], result.inspect
    result['content'].first['text']
  end

  def call_as(scopes, name, arguments)
    application = Doorkeeper::Application.create!(name: 'MCP test', redirect_uri: 'https://client.example/callback',
                                                  scopes: scopes)
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: 2, scopes: scopes,
                                            expires_in: 2.hours)
    post_mcp rpc('tools/call', { 'name' => name, 'arguments' => arguments }),
             'Authorization' => "Bearer #{token.plaintext_token}"
    json_body
  end

  # --- wiki ---------------------------------------------------------------

  def test_update_wiki_page_creates_a_page
    saved = state(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'Release notes',
                                                  'text' => '# Notes', 'comments' => 'First draft',
                                                  'parent_title' => 'CookBook_documentation' }))

    assert saved['created']
    assert_equal 1, saved['version']
    assert_equal 'CookBook_documentation', saved['parent_title']
    page = Project.find(1).wiki.find_page('Release notes')
    assert_equal '# Notes', page.content.text
    assert_equal 2, page.content.author_id
  end

  def test_update_wiki_page_replaces_the_text_and_keeps_the_history
    page   = Project.find(1).wiki.find_page('Another_page')
    before = page.content.version

    saved = state(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'Another_page',
                                                  'text' => 'Rewritten', 'version' => before }))
    assert_not saved['created']
    assert_equal before + 1, saved['version']
    assert_equal 'Rewritten', page.reload.content.text

    # The version read before that edit is now stale.
    stale = refusal(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'Another_page',
                                                    'text' => 'Lost update', 'version' => before }))
    assert_match 'was edited since that version', stale
    assert_equal 'Rewritten', page.reload.content.text
  end

  def test_update_wiki_page_refuses_a_protected_page_without_its_permission
    page = Project.find(1).wiki.find_page('CookBook_documentation')
    assert page.protected?
    Role.find_each { |role| role.remove_permission!(:protect_wiki_pages) }

    text = refusal(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'CookBook_documentation', 'text' => 'X' }))
    assert_match 'is protected: editing it needs ', text
  end

  def test_update_wiki_page_moves_an_existing_page_only_with_rename_wiki_pages
    Role.find_each { |role| role.remove_permission!(:rename_wiki_pages) }
    text = refusal(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'Another_page', 'text' => 'X',
                                                   'parent_title' => '' }))
    assert_match 'parent_title (needs ', text
  end

  def test_update_wiki_page_needs_the_wiki_module_and_refuses_a_blank_text
    assert_match 'Missing required argument: text',
                 refusal(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'Empty', 'text' => '' }))
    Project.find(1).disable_module!(:wiki)
    assert_match 'wiki module is not enabled',
                 refusal(call_tool('update_wiki_page', { 'project' => 'ecookbook', 'title' => 'Any', 'text' => 'X' }))
  end

  def test_wiki_history_and_an_earlier_version
    history = state(call_tool('list_wiki_page_versions', { 'project' => 'ecookbook', 'title' => 'CookBook_documentation' }))
    numbers = history['versions'].map { |version| version['version'] }
    assert_equal numbers.sort.reverse, numbers
    assert_equal history['total_count'], WikiPage.find(1).content.versions.count
    assert history['versions'].first.key?('author')

    oldest = state(call_tool('get_wiki_page', { 'project' => 'ecookbook', 'title' => 'CookBook_documentation',
                                                'version' => numbers.last }))
    assert_equal numbers.last, oldest['version']
    assert_equal numbers.first, oldest['current_version']
    assert_equal WikiPage.find(1).content.versions.find_by(version: numbers.last).text, oldest['text']

    assert_match 'has no version 999',
                 refusal(call_tool('get_wiki_page', { 'project' => 'ecookbook', 'title' => 'CookBook_documentation',
                                                      'version' => 999 }))
  end

  def test_an_earlier_version_needs_view_wiki_edits
    scopes = 'view_project view_wiki_pages'
    title  = { 'project' => 'ecookbook', 'title' => 'CookBook_documentation' }

    assert_not call_as(scopes, 'get_wiki_page', title)['result']['isError']
    assert_match 'do not have permission', refusal(call_as(scopes, 'get_wiki_page', title.merge('version' => 1))['result'])
    assert call_as(scopes, 'list_wiki_page_versions', title)['error'].present?
    assert call_as(scopes, 'update_wiki_page', title.merge('text' => 'X'))['error'].present?
  end

  # --- files ----------------------------------------------------------------

  def test_add_file_then_list_files
    added = state(call_tool('add_file', { 'project' => 'ecookbook', 'filename' => 'notes.md', 'content' => '# Notes',
                                          'description' => 'Meeting notes' }))
    assert_equal 'notes.md', added['filename']
    assert_equal 'Meeting notes', added['description']
    assert_equal Project.find(1), Attachment.find(added['id']).container

    on_version = state(call_tool('add_file', { 'project' => 'ecookbook', 'filename' => 'changes.txt', 'content' => 'Fixes',
                                               'version' => 2 }))
    assert_equal 2, on_version['version']['id']

    files = state(call_tool('list_files', { 'project' => 'ecookbook' }))['files']
    assert_includes files.map { |file| file['filename'] }, 'notes.md'
    assert_equal 2, files.detect { |file| file['filename'] == 'changes.txt' }['version']['id']
    assert files.all? { |file| file.key?('digest') && file.key?('downloads') }
  end

  def test_add_file_refuses_an_empty_file_a_foreign_version_and_a_disabled_module
    arguments = { 'project' => 'ecookbook', 'filename' => 'notes.md', 'content' => 'X' }
    assert_no_difference 'Attachment.count' do
      assert_match 'Missing required argument: content', refusal(call_tool('add_file', arguments.merge('content' => '')))
      assert_match 'has no version with id 999999', refusal(call_tool('add_file', arguments.merge('version' => 999_999)))
      Project.find(1).disable_module!(:files)
      assert_match 'files module is not enabled', refusal(call_tool('add_file', arguments))
      assert_match 'files module is not enabled', refusal(call_tool('list_files', { 'project' => 'ecookbook' }))
    end
  end

  # --- search ---------------------------------------------------------------

  def test_search_in_a_project_finds_issues_and_names_what_was_searched
    result = state(call_tool('search', { 'q' => 'recipe', 'project' => 'ecookbook' }))

    assert_operator result['total_count'], :>, 0
    assert_includes result['searched_types'], 'issues'
    assert_not_includes result['searched_types'], 'projects'
    assert(result['results'].all? { |row| row['title'].present? && row['type'].present? })
    assert_equal result['total_count'], result['count_by_type'].values.sum
  end

  def test_search_keeps_to_the_requested_types
    result = state(call_tool('search', { 'q' => 'ecookbook', 'types' => ['projects'] }))
    assert_equal ['projects'], result['searched_types']
    assert_includes result['results'].map { |row| row['title'] }.join, 'eCookbook'

    assert_match 'No search type invoices', refusal(call_tool('search', { 'q' => 'recipe', 'types' => ['invoices'] }))
    assert_match 'no word to search for', refusal(call_tool('search', { 'q' => 'a' }))
  end

  # Core's search reads through role-based SQL, blind to a token's scopes.
  def test_search_leaves_out_the_types_a_token_may_not_view
    scoped = state(call_as('view_project search_project view_news', 'search', { 'q' => 'recipe' })['result'])
    assert_equal %w[news projects], scoped['searched_types'].sort
    assert_empty scoped['results'].select { |row| row['type'].to_s.start_with?('issue') }

    text = refusal(call_as('view_project search_project view_news', 'search', { 'q' => 'recipe', 'types' => ['issues'] })['result'])
    assert_match 'You may read none of these types here', text
  end
end
