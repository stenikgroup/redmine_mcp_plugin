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
          Tools::SearchIssues,
          Tools::ListQueries,
          Tools::GetIssue,
          Tools::GetAttachment,
          Tools::ListWikiPages,
          Tools::GetWikiPage,
          Tools::ListWikiPageVersions,
          Tools::ListFiles,
          Tools::Search,
          Tools::ListNews,
          Tools::GetNews,
          Tools::ListEnumerations,
          Tools::ListUsers,
          Tools::ListTimeEntries,
          Tools::ListMemberships,
          Tools::GetIssueFields,
          Tools::CreateIssue,
          Tools::UpdateIssue,
          Tools::CopyIssue,
          Tools::AddIssueNote,
          Tools::UpdateIssueNote,
          Tools::AddIssueAttachment,
          Tools::UpdateIssueChecklists,
          Tools::UpdateIssueRelations,
          Tools::LogTime,
          Tools::UpdateTimeEntry,
          Tools::CreateNews,
          Tools::UpdateNews,
          Tools::UpdateWikiPage,
          Tools::AddFile,
          Tools::CreateProject,
          Tools::UpdateProject,
          Tools::CloseProject,
          Tools::ReopenProject,
          Tools::CreateVersion,
          Tools::UpdateVersion,
          Tools::CreateIssueCategory,
          Tools::UpdateIssueCategory,
          Tools::UpdateMembership
        ]
      end
    end
  end
end
