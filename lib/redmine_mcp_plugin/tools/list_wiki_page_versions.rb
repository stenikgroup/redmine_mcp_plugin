# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListWikiPageVersions < Tool
      tool 'list_wiki_page_versions',
           title: 'List wiki page versions',
           description: 'List the history of a wiki page, newest first: version, author, comment and date. ' \
                        'get_wiki_page with version reads one.',
           permission: :view_wiki_edits,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'title' => { 'type' => 'string', 'description' => 'Wiki page title.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1 }
             },
             'required' => %w[project title],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        page    = fetch_wiki_page(wiki_for(project, :view_wiki_edits), arguments['title'])
        raise ToolError, "#{page.title} has no content" if page.content.nil?

        scope  = page.content.versions
        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        # As core's history: the text is not loaded.
        rows   = scope.select('id, author_id, comments, updated_on, version').preload(:author).reorder('version DESC')
                      .offset(offset).limit(limit).map do |version|
          { version: version.version, author: version.author&.name, comments: version.comments,
            updated_on: iso(version.updated_on) }
        end
        paged(total: scope.count, offset: offset, key: :versions, rows: rows)
          .merge(title: page.title, project_identifier: project.identifier)
      end
    end
  end
end
