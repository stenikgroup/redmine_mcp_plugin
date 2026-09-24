# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class LogTime < Tool
      tool 'log_time',
           title: 'Log spent time',
           description: 'Log spent time on an issue, or on a project when there is no issue. Time is ' \
                        'always logged for the authenticated user and cannot be logged for anyone ' \
                        'else. Activities differ per project: call list_enumerations with the project ' \
                        'to get the ones this project accepts. Report the saved state from the reply, ' \
                        'not what was requested. After a successful write, always finish by asking ' \
                        'the user to check the result at the returned url.',
           permission: :log_time,
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id to log against.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id, when there is no issue.' },
               'hours' => { 'type' => 'number', 'minimum' => 0, 'description' => 'Hours spent, e.g. 1.5.' },
               'activity' => { 'type' => 'string',
                               'description' => 'Activity name, from list_enumerations for this project.' },
               'spent_on' => { 'type' => 'string', 'description' => 'ISO-8601 date. Defaults to today.' },
               'comments' => { 'type' => 'string', 'description' => 'What the time was spent on.' },
               'custom_fields' => { 'type' => 'object',
                                    'description' => 'Custom field values keyed by numeric field id. Send the value, ' \
                                                     'never the label.' }
             },
             'required' => %w[hours],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = fetch_issue(arguments['issue'])
        raise ToolError, 'Pass issue, or project when there is no issue' if issue.nil? && arguments['project'].blank?

        project = issue ? issue.project : fetch_project(arguments['project'])
        authorize!(:log_time, project)

        entry = TimeEntry.new(project: project, issue: issue, author: user, user: user,
                              spent_on: spent_on(arguments))
        entry.safe_attributes = attributes_from(arguments, project)
        raise ToolError, "Could not log time: #{entry.errors.full_messages.join('; ')}" unless entry.save

        entry_state(entry, custom_field_ids(arguments))
      end

      def fetch_issue(id)
        return nil if id.blank?

        issue = Issue.visible(user).find_by(id: id.to_i)
        raise ToolError, "No visible issue with id #{id.inspect}" if issue.nil?

        issue
      end

      def attributes_from(arguments, project)
        attributes = { 'hours' => arguments['hours'] }
        attributes['comments'] = arguments['comments'].to_s if arguments.key?('comments')

        if (name = arguments['activity'].presence)
          attributes['activity_id'] = activity_for(project, name).id
        end

        if (values = custom_field_values_from(arguments))
          attributes['custom_field_values'] = values
        end

        attributes
      end

      # Activities are per project (project.rb:265). Picking from the global
      # list gives "Activity is not included in the list" on save.
      def activity_for(project, name)
        activity = project.activities.find_by(name: name.to_s)
        raise ToolError, "Project #{project.identifier} has no activity named #{name.inspect}" if activity.nil?

        activity
      end

      def spent_on(arguments)
        date = arguments['spent_on'].presence
        return user.today if date.nil?

        Date.iso8601(date.to_s)
      rescue ArgumentError
        raise ToolError, "spent_on must be an ISO-8601 date, got #{date.inspect}"
      end

      def entry_state(entry, ids)
        {
          id: entry.id,
          hours: entry.hours.to_f,
          activity: entry.activity&.name,
          spent_on: entry.spent_on&.iso8601,
          comments: entry.comments,
          issue_id: entry.issue_id,
          project_identifier: entry.project&.identifier,
          custom_fields: saved_custom_fields(entry, ids),
          url: entry.issue ? absolute_url(:issue_url, entry.issue) : absolute_url(:project_time_entries_url, entry.project)
        }
      end
    end
  end
end
