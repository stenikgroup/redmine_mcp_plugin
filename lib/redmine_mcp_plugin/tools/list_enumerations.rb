# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListEnumerations < Tool
      tool 'list_enumerations',
           title: 'List trackers, statuses, priorities and activities',
           description: 'List the trackers, issue statuses, priorities and time entry activities ' \
                        'configured on this Redmine. Pass project to get the activities that project ' \
                        'accepts, which is what log_time needs: they differ per project.',
           permission: nil,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id. Narrows the activities to that project.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = arguments['project'].present? ? fetch_project(arguments['project']) : nil

        {
          trackers: Tracker.sorted.map { |t| { id: t.id, name: t.name } },
          issue_statuses: IssueStatus.sorted.map { |s| { id: s.id, name: s.name, is_closed: s.is_closed? } },
          priorities: IssuePriority.active.map { |p| { id: p.id, name: p.name, is_default: p.is_default? } },
          time_entry_activities: TimeEntryActivity.available_activities(project).map do |a|
            { id: a.id, name: a.name, is_default: a.is_default? }
          end
        }
      end
    end
  end
end
