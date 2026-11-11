# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class Search < Tool
      # Each searchable type and the permission that lets a caller read it.
      TYPE_PERMISSIONS = { 'issues' => :view_issues, 'news' => :view_news, 'documents' => :view_documents,
                           'changesets' => :view_changesets, 'wiki_pages' => :view_wiki_pages,
                           'messages' => :view_messages, 'projects' => :view_project }.freeze
      DESCRIPTION_LENGTH = 500

      tool 'search',
           title: 'Search',
           description: 'Full-text search across what the user may read: issues, news, documents, changesets, ' \
                        'wiki pages, forum messages and projects, as Redmine\'s search box. For issues alone, ' \
                        'search_issues filters and sorts. Each result gives its type, title, an excerpt and its url.',
           permission: :search_project,
           scopes: TYPE_PERMISSIONS.values + %i[view_private_notes],
           schema: {
             'type' => 'object',
             'properties' => {
               'q' => { 'type' => 'string', 'description' => 'Words to look for.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id. Without it, every project.' },
               'scope' => { 'type' => 'string', 'enum' => %w[all my_projects bookmarks subprojects],
                            'description' => 'all (default without project), my_projects, bookmarks, or subprojects ' \
                                             'to include those of project.' },
               'types' => { 'type' => 'array', 'items' => { 'type' => 'string' },
                            'description' => 'Any of issues, news, documents, changesets, wiki_pages, messages, ' \
                                             'projects. Defaults to all the caller may read.' },
               'all_words' => { 'type' => 'boolean', 'description' => 'Every word must match. Default true.' },
               'titles_only' => { 'type' => 'boolean', 'description' => 'Search titles only. Default false.' },
               'open_issues' => { 'type' => 'boolean', 'description' => 'Leave closed issues out. Default false.' },
               'attachments' => { 'type' => 'string', 'enum' => %w[0 1 only],
                                  'description' => 'Attachment file names and descriptions: 0 leaves them out ' \
                                                   '(default), 1 adds them, only searches nothing else.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1 }
             },
             'required' => %w[q],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project  = arguments['project'].present? ? fetch_project(arguments['project']) : nil
        projects = projects_to_search(project, arguments['scope'])
        types    = types_for(projects, arguments['types'])
        fetcher  = Redmine::Search::Fetcher.new(
          arguments['q'].to_s, user, types, projects,
          all_words: arguments['all_words'] != false, titles_only: arguments['titles_only'] == true,
          attachments: arguments['attachments'].presence || '0', open_issues: arguments['open_issues'] == true,
          cache: false, params: {}
        )
        raise ToolError, 'q has no word to search for; a word needs at least two characters' if fetcher.tokens.blank?

        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        without_withheld_notes do
          rows = fetcher.results(offset, limit).map { |result| result_row(result) }
          paged(total: fetcher.result_count, offset: offset, key: :results, rows: rows)
            .merge(count_by_type: fetcher.result_count_by_type, searched_types: types)
        end
      end

      # Core's search matches an issue on its private notes under a condition
      # built from the roles alone. A caller without view_private_notes, which
      # for a token means without the scope, must not learn from a match what a
      # private note says. The fetcher queries lazily, so every read of it is
      # inside the block.
      def without_withheld_notes(&)
        return yield if user.allowed_to?(:view_private_notes, nil, global: true)

        WithheldPermissions.during(:view_private_notes, &)
      end

      # As core's controller.
      def projects_to_search(project, scope)
        case scope
        when 'all'         then nil
        when 'my_projects' then user.projects
        when 'bookmarks'   then Project.where(id: user.bookmarked_project_ids)
        when 'subprojects' then project&.self_and_descendants.to_a.presence
        else project
        end
      end

      # Core keeps, for one project, the types the user may view there. Its
      # search then reads through .visible scopes, which are SQL built on roles
      # and ignore a token's scopes, so each type also needs its view scope.
      def types_for(projects, requested)
        types = Redmine::Search.available_search_types.dup
        types.delete('projects') if projects.is_a?(Project)
        types = types.select { |type| readable_type?(type, projects) }
        wanted = Array(requested).map(&:to_s)
        unknown = wanted - TYPE_PERMISSIONS.keys
        raise ToolError, "No search type #{unknown.join(', ')}; types: #{TYPE_PERMISSIONS.keys.join(', ')}" if unknown.any?

        chosen = wanted.empty? ? types : types & wanted
        raise ToolError, 'You may read none of these types here' if chosen.empty?

        chosen
      end

      def readable_type?(type, projects)
        permission = TYPE_PERMISSIONS[type] || :"view_#{type}"
        return user.allowed_to?(permission, projects) if projects.is_a?(Project)

        user.allowed_to?(permission, nil, global: true)
      end

      def result_row(result)
        { id: result.id, type: result.event_type, title: result.event_title,
          description: result.event_description.to_s.truncate(DESCRIPTION_LENGTH),
          datetime: iso(result.event_datetime), url: result_url(result) }
      end

      def result_url(result)
        return nil if Setting.host_name.blank?

        Rails.application.routes.url_helpers.url_for(result.event_url.merge(Mailer.default_url_options))
      end
    end
  end
end
