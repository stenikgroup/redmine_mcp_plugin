# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # The checklists of redmine_checklists on an issue. Reached only while
    # Integrations says the plugin is usable.
    module Checklists
      private

      def checklist_done_ratio?(issue, adding: false)
        plugin?(:redmine_checklists) && RedmineChecklists.issue_done_ratio? &&
          (adding || issue.checklists.reject(&:is_section).any?)
      end

      # The plugin's listener recalculates the done ratio and, in the edition that
      # keeps a history of the list, journals the change; the light one does not.
      # It reads the issue and the journal, nothing else.
      def journal_checklists!(issue)
        RedmineChecklists::Hooks::ControllerIssuesHook.instance.controller_issues_edit_after_save(
          issue: issue, journal: issue.current_journal
        )
      end

      def checklist_row(item)
        { id: item.id, subject: item.subject, is_done: item.is_done, is_section: item.is_section, position: item.position }
      end
    end
  end
end
