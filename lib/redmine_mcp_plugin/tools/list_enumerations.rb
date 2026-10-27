# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListEnumerations < Tool
      tool 'list_enumerations',
           title: 'List trackers, statuses, priorities and activities',
           description: 'List the trackers, issue statuses, priorities and time entry activities ' \
                        'configured on this Redmine. Pass project to get what log_time needs there: the ' \
                        'activities that project accepts, which differ per project, and the custom fields ' \
                        'a time entry takes, with the required ones and their allowed values.',
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

        payload = {
          trackers: Tracker.sorted.map { |t| { id: t.id, name: t.name } },
          issue_statuses: IssueStatus.sorted.map { |s| { id: s.id, name: s.name, is_closed: s.is_closed? } },
          priorities: IssuePriority.active.map { |p| { id: p.id, name: p.name, is_default: p.is_default? } },
          time_entry_activities: TimeEntryActivity.available_activities(project).map do |a|
            { id: a.id, name: a.name, is_default: a.is_default? }
          end
        }
        # What log_time would be refused without, visible to those who may log there.
        if project && user.allowed_to?(:log_time, project)
          payload[:time_entry_custom_fields] = custom_field_rows(TimeEntry.new(project: project, author: user, user: user))
        end
        payload
      end
    end
  end
end
