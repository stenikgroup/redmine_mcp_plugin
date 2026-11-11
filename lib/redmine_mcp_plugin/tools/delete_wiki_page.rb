# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteWikiPage < Tool
      tool 'delete_wiki_page',
           title: 'Delete wiki page',
           description: 'Delete a wiki page for good, with its whole history and attachments. Get explicit ' \
                        'confirmation before calling. When the page has child pages, children says what ' \
                        'becomes of them.',
           permission: :delete_wiki_pages,
           scopes: %i[protect_wiki_pages],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'title' => { 'type' => 'string', 'description' => 'Wiki page title.' },
               'children' => { 'type' => 'string', 'enum' => %w[nullify destroy reassign],
                               'description' => 'Needed when the page has child pages: nullify makes them root ' \
                                                'pages, destroy deletes every descendant, reassign moves them ' \
                                                'under reassign_to.' },
               'reassign_to' => { 'type' => 'string', 'description' => 'Title of the new parent page, with reassign.' }
             },
             'required' => %w[project title],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        raise ToolError, "Project #{project.identifier} is closed; reopen it first" if project.closed?

        wiki = wiki_for(project, :delete_wiki_pages)
        page = fetch_wiki_page(wiki, arguments['title'])
        # Core's rule for a protected page.
        raise ToolError, "#{page.title} is protected: deleting it needs #{permission_labels(:protect_wiki_pages)}" unless page.editable_by?(user)

        descendants = page.descendants.map(&:title)
        WikiPage.transaction do
          settle_children!(wiki, page, descendants, arguments) if descendants.any?
          page.destroy
        end
        { deleted: true, title: page.title, project_identifier: project.identifier,
          descendants: descendants, children: (arguments['children'] if descendants.any?) }
      end

      # Core's form asks; its API leaves the children as root pages without a word.
      def settle_children!(wiki, page, descendants, arguments)
        case arguments['children']
        when 'nullify' then nil
        when 'destroy' then page.descendants.each(&:destroy)
        when 'reassign'
          target = wiki.find_page(arguments['reassign_to'].to_s)
          raise ToolError, 'reassign_to must be a page outside the one being deleted' if target.nil? || page.self_and_descendants.include?(target)

          page.children.each { |child| child.update_attribute(:parent, target) }
        else
          raise ToolError, "#{page.title} has child pages (#{descendants.join(', ')}); pass children: nullify, destroy or reassign"
        end
      end
    end
  end
end
