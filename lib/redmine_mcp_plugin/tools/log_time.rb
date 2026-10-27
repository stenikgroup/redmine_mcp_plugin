# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class LogTime < Tool
      tool 'log_time',
           title: 'Log spent time',
           description: 'Log spent time on an issue, or on a project when there is no issue. Time is ' \
                        'always logged for the authenticated user and cannot be logged for anyone ' \
                        'else. Call list_enumerations with the project first: activities differ per ' \
                        'project, and it lists the custom fields a time entry needs there, with the ' \
                        'required ones and their allowed values. If refused, tell the user and ask ' \
                        'rather than guess. End with the url.',
           permission: :log_time,
           plain: %w[comments],
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
               'custom_field_values' => { 'type' => 'object',
                                         'description' => 'By field id from list_enumerations with the project; ' \
                                                          'a value, or its label when it names one value.' }
             },
             'required' => %w[hours activity],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = fetch_issue(arguments['issue']) if arguments['issue'].present?
        raise ToolError, 'Pass issue, or project when there is no issue' if issue.nil? && arguments['project'].blank?

        project = issue ? issue.project : fetch_project(arguments['project'])
        authorize!(:log_time, project)

        entry = TimeEntry.new(project: project, issue: issue, author: user, user: user,
                              spent_on: spent_on(arguments))
        entry.safe_attributes = attributes_from(entry, arguments, project)
        require_custom_fields!(entry)
        raise ToolError, "Could not log time: #{entry.errors.full_messages.join('; ')}" unless entry.save

        entry_state(entry, custom_field_ids(arguments))
      end

      def attributes_from(entry, arguments, project)
        attributes = { 'hours' => arguments['hours'], 'activity_id' => activity_for(project, arguments['activity']).id }
        attributes['comments'] = arguments['comments'].to_s if arguments.key?('comments')

        values = custom_field_values_for(entry, arguments['custom_field_values'])
        attributes['custom_field_values'] = values if values

        attributes
      end

      # Activities are per project; one from the global list fails validation.
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
        state = {
          id: entry.id,
          hours: entry.hours.to_f,
          activity: entry.activity&.name,
          spent_on: entry.spent_on&.iso8601,
          comments: entry.comments,
          issue_id: entry.issue_id,
          project_identifier: entry.project&.identifier,
          url: entry.issue ? absolute_url(:issue_url, entry.issue) : absolute_url(:project_time_entries_url, entry.project)
        }
        # No key when none were sent: an empty list reads as "no custom fields".
        state[:custom_fields] = saved_custom_fields(entry, ids) if ids.any?
        state
      end
    end
  end
end
