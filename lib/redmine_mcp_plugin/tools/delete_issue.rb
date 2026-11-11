# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteIssue < Tool
      tool 'delete_issue',
           title: 'Delete issue',
           description: 'Delete an issue for good, with its subtasks, notes, attachments and relations. It ' \
                        'cannot be undone: name the issue and what goes with it, and get explicit ' \
                        'confirmation before calling. When time is logged on it, time_entries says what ' \
                        'becomes of that time.',
           permission: :delete_issues,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'time_entries' => { 'type' => 'string', 'enum' => %w[destroy nullify reassign],
                                   'description' => 'Needed when time is logged on the issue or its subtasks: ' \
                                                    'destroy deletes it, nullify keeps it on the project, ' \
                                                    'reassign moves it to reassign_to.' },
               'reassign_to' => { 'type' => 'integer', 'description' => 'Issue id of the same project, with reassign.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = fetch_issue(arguments['issue'])
        raise ToolError, "Project #{issue.project.identifier} is closed; reopen it first" if issue.project.closed?
        # delete_issues is granted per tracker: authorize! covers the scope, deletable? the tracker.
        authorize!(:delete_issues, issue.project)
        raise ToolError, 'You do not have permission to do that' unless issue.deletable?(user)

        ids     = Issue.self_and_descendants([issue]).pluck(:id)
        entries = TimeEntry.where(issue_id: ids)
        hours   = entries.sum(:hours).to_f
        Issue.transaction do
          settle_time!(issue, entries, ids, hours, arguments) if hours.positive?
          issue.reload.destroy
        end

        { deleted: true, id: issue.id, project_identifier: issue.project.identifier,
          deleted_issue_ids: ids, hours: hours, time_entries: (arguments['time_entries'] if hours.positive?) }
      end

      # Core's form asks; its API deletes the time without a word.
      def settle_time!(issue, entries, ids, hours, arguments)
        case arguments['time_entries']
        when 'destroy' then nil
        when 'nullify'
          raise ToolError, 'A time entry needs an issue on this Redmine; pass destroy or reassign' if Setting.timelog_required_fields.include?('issue_id')

          entries.update_all(issue_id: nil)
        when 'reassign'
          target = issue.project.issues.find_by(id: arguments['reassign_to'])
          raise ToolError, "reassign_to must be an issue of #{issue.project.identifier}" if target.nil?
          raise ToolError, "##{target.id} is about to be deleted too" if ids.include?(target.id)

          entries.update_all(issue_id: target.id, project_id: target.project_id)
        else
          raise ToolError, "#{hours} hours are logged on this issue or its subtasks; pass time_entries: destroy, nullify or reassign"
        end
      end
    end
  end
end
