# frozen_string_literal: true

module RedmineMcpPlugin
  # This plugin's own tools; Endpoint.tools appends those other plugins add.
  #
  # Explicit list, not a Dir.glob over the tools directory. A glob means a stray
  # file dropped into plugins/redmine_mcp_plugin/lib/.../tools/ becomes a live,
  # authenticated endpoint; requiring an edit here makes adding a tool a visible
  # act in the diff.
  module Registry
    class << self
      def all
        [
          Tools::WhoAmI,
          Tools::ListProjects,
          Tools::GetProject,
          Tools::GetProjectFields,
          Tools::UpdateProjects,
          Tools::SearchIssues,
          Tools::ListQueries,
          Tools::GetIssue,
          Tools::GetAttachment,
          Tools::ListWikiPages,
          Tools::GetWikiPage,
          Tools::ListNews,
          Tools::GetNews,
          Tools::ListEnumerations,
          Tools::ListUsers,
          Tools::ListTimeEntries,
          Tools::GetIssueFields,
          Tools::CreateIssue,
          Tools::UpdateIssue,
          Tools::AddIssueNote,
          Tools::UpdateIssueNote,
          Tools::AddIssueAttachment,
          Tools::UpdateIssueChecklists,
          Tools::UpdateIssueRelations,
          Tools::LogTime,
          Tools::CreateNews,
          Tools::UpdateNews
        ]
      end
    end
  end
end
