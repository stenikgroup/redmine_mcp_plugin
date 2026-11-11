# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class LogTime < Tool
      tool 'log_time',
           title: 'Log spent time',
           description: 'Log spent time on an issue, or on a project when there is no issue, for the ' \
                        'authenticated user unless user names someone else. Call list_enumerations with the project first: activities differ per ' \
                        'project, and it lists the custom fields a time entry needs there, with the ' \
                        'required ones and their allowed values. If refused, tell the user and ask ' \
                        'rather than guess. End with the url.',
           permission: :log_time,
           scopes: %i[log_time_for_other_users],
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
               'user' => { 'type' => %w[integer string],
                           'description' => 'User id from list_users, or "me" (the default). Someone else needs the ' \
                                            'permission to log time for other users.' },
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
        save_or_refuse!(entry, 'log time')

        time_entry_state(entry, custom_field_ids(arguments))
      end

      def attributes_from(entry, arguments, project)
        attributes = { 'hours' => arguments['hours'], 'activity_id' => time_entry_activity(project, arguments['activity']).id }
        attributes['comments'] = arguments['comments'].to_s if arguments.key?('comments')
        attributes['user_id']  = time_entry_user_id(entry, arguments['user']) unless arguments['user'].nil?

        values = custom_field_values_for(entry, arguments['custom_field_values'])
        attributes['custom_field_values'] = values if values

        attributes
      end

      def spent_on(arguments)
        date = arguments['spent_on'].presence
        return user.today if date.nil?

        Date.iso8601(date.to_s)
      rescue ArgumentError
        raise ToolError, "spent_on must be an ISO-8601 date, got #{date.inspect}"
      end
    end
  end
end
