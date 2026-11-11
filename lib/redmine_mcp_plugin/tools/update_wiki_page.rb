# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateWikiPage < Tool
      include WikiPages

      tool 'update_wiki_page',
           title: 'Create or update a wiki page',
           description: 'Write a wiki page: creates it when the title is new, otherwise replaces its whole ' \
                        'text and keeps the previous one in the history. Read the page first and pass its ' \
                        'version, so an edit made meanwhile is refused instead of overwritten. Watchers may ' \
                        'be emailed. End with the url.',
           permission: :edit_wiki_pages,
           scopes: %i[rename_wiki_pages protect_wiki_pages],
           rendered: %w[text],
           plain: %w[comments],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'title' => { 'type' => 'string', 'description' => 'Wiki page title.' },
               'text' => { 'type' => 'string', 'description' => 'The whole page.' },
               'comments' => { 'type' => 'string', 'description' => 'What changed, for the history. Up to 1024 characters.' },
               'version' => { 'type' => 'integer', 'minimum' => 1,
                              'description' => 'The version read with get_wiki_page; refused when the page moved on.' },
               'parent_title' => { 'type' => 'string',
                                   'description' => 'Parent page title, or "" for none. On an existing page it ' \
                                                    'needs the permission to rename wiki pages.' }
             },
             'required' => %w[project title text],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        raise ToolError, "Project #{project.identifier} is closed; reopen it first" if project.closed?

        page = wiki_for(project, :edit_wiki_pages).find_or_new_page(arguments['title'].to_s)
        # Core's rule for a protected page.
        raise ToolError, "#{page.title} is protected: editing it needs #{permission_labels(:protect_wiki_pages)}" unless page.editable_by?(user)

        created = page.new_record?
        set_parent!(page, arguments['parent_title']) unless arguments['parent_title'].nil?
        save!(page, content_for(page, arguments))

        { title: page.title, project_identifier: project.identifier, version: page.content.version, created: created,
          parent_title: page.parent&.title, updated_on: iso(page.content.updated_on),
          url: absolute_url(:project_wiki_page_url, project, page.title) }
      end

      # Core drops the parent of an existing page without rename_wiki_pages.
      def set_parent!(page, title)
        unless page.safe_attribute?('parent_title', user)
          raise ToolError, "Cannot set parent_title (needs #{permission_labels(:rename_wiki_pages)}) on this page"
        end

        page.safe_attributes = { 'parent_title' => title.to_s }
      end

      def content_for(page, arguments)
        content = page.content || WikiContent.new(page: page)
        content.comments = arguments['comments']
        content.version  = arguments['version'] if arguments['version']
        content.text     = arguments['text'].to_s
        content.author   = user
        content
      end

      def save!(page, content)
        return if page.save_with_content(content)

        raise ToolError, "Could not save the page: #{(page.errors.full_messages + content.errors.full_messages).uniq.join('; ')}"
      rescue ActiveRecord::StaleObjectError
        raise ToolError, "#{page.title} was edited since that version; read it again with get_wiki_page"
      end
    end
  end
end
