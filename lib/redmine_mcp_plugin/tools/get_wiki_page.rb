# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetWikiPage < Tool
      include WikiPages

      tool 'get_wiki_page',
           title: 'Get wiki page',
           description: 'Fetch the text of one wiki page, or of an earlier version from list_wiki_page_versions.',
           permission: :view_wiki_pages,
           scopes: %i[view_wiki_edits],
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id.' },
               'title' => { 'type' => 'string', 'description' => 'Wiki page title.' },
               'version' => { 'type' => 'integer', 'minimum' => 1,
                              'description' => 'An earlier version. Defaults to the current one.' }
             },
             'required' => %w[project title],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        wiki    = fetch_wiki(project)

        page = wiki.find_page(arguments['title'].to_s)
        raise ToolError, "No wiki page titled #{arguments['title'].inspect}" if page.nil? || !page.visible?(user)

        # Core's rule: an earlier version is history, which view_wiki_edits grants.
        authorize!(:view_wiki_edits, project) if arguments['version']
        content = page.content_for_version(arguments['version'])
        raise ToolError, "#{page.title} has no version #{arguments['version']}" if content.nil?

        {
          title: page.title,
          project_identifier: project.identifier,
          version: content.version,
          current_version: page.content&.version,
          text: content.text,
          author: content.author&.name,
          comments: content.comments,
          parent_title: page.parent&.title,
          updated_on: iso(content.updated_on),
          url: absolute_url(:project_wiki_page_url, project, page.title)
        }
      end
    end
  end
end
