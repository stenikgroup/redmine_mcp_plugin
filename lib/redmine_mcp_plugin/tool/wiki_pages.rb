# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # The wiki of a project: the module, the permission and the page, checked in
    # that order.
    module WikiPages
      private

      # Both wiki tools need these three checks, in this order.
      #
      # The module check comes first because allowed_to? returns false for a
      # disabled module, so a project whose wiki is merely switched off otherwise
      # reports "You do not have permission" -- which sent one reviewer looking
      # for a permissions bug that was not there. Naming the real cause leaks
      # nothing: get_project already returns enabled_modules to anyone who can
      # see the project.
      def fetch_wiki(project)
        require_module!(project, :wiki)
        authorize!(:view_wiki_pages, project)

        wiki = project.wiki
        raise ToolError, "Project #{project.identifier} has no wiki" if wiki.nil? || !wiki.visible?(user)

        wiki
      end

      # The wiki for a tool that needs `permission` and not view_wiki_pages, as
      # core's own actions: editing or reading the history is granted apart.
      def wiki_for(project, permission)
        require_module!(project, :wiki)
        authorize!(permission, project)
        project.wiki || raise(ToolError, "Project #{project.identifier} has no wiki")
      end

      def fetch_wiki_page(wiki, title)
        page = wiki.find_page(title.to_s)
        raise ToolError, "No wiki page titled #{title.inspect}" if page.nil?

        page
      end
    end
  end
end
