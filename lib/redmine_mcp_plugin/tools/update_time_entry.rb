# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateTimeEntry < Tool
      tool 'update_time_entry',
           title: 'Update time entry',
           description: 'Correct a time entry from list_time_entries: hours, activity, date, comment, custom ' \
                        'fields, whose time it is, or the issue or project it is logged on. Only what is sent changes. Your own entries, or ' \
                        'anyone\'s where your role may edit time entries; say whose entry it is and get ' \
                        'explicit confirmation before changing someone else\'s. End with the url.',
           permission: %i[edit_time_entries edit_own_time_entries],
           scopes: %i[view_time_entries log_time log_time_for_other_users],
           plain: %w[comments],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'time_entry' => { 'type' => 'integer', 'description' => 'Time entry id.' },
               'issue' => { 'type' => %w[integer string],
                            'description' => 'Issue id to move the entry to, or "none" to keep it on the project alone.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id to move the entry to.' },
               'hours' => { 'type' => 'number', 'minimum' => 0, 'description' => 'Hours spent, e.g. 1.5.' },
               'activity' => { 'type' => 'string',
                               'description' => 'Activity name, from list_enumerations for the entry\'s project.' },
               'spent_on' => { 'type' => 'string', 'description' => 'ISO-8601 date.' },
               'comments' => { 'type' => 'string', 'description' => 'What the time was spent on.' },
               'user' => { 'type' => %w[integer string],
                           'description' => 'User id from list_users, or "me". Someone else needs the permission to ' \
                                            'log time for other users.' },
               'custom_field_values' => { 'type' => 'object',
                                         'description' => 'By field id from list_enumerations with the project; ' \
                                                          'a value, or its label when it names one value.' }
             },
             'required' => %w[time_entry],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        entry = fetch_time_entry(arguments['time_entry'])
        raise ToolError, "Project #{entry.project.identifier} is closed; reopen it first" if entry.project.closed?
        # Core's rule: edit_time_entries for anyone's entry, edit_own_time_entries for one's own.
        unless entry.editable_by?(user)
          own = entry.user_id == user.id
          raise ToolError, own ? 'You do not have permission to do that' : "Editing another user's time needs #{permission_labels(:edit_time_entries)}"
        end

        attributes = attributes_from(entry, arguments)
        raise ToolError, 'Pass at least one field to change' if attributes.empty?

        entry.safe_attributes = attributes
        require_custom_fields!(entry)
        save_or_refuse!(entry, 'update the time entry')

        time_entry_state(TimeEntry.find(entry.id), custom_field_ids(arguments))
      end

      # TimeEntry.visible is SQL built on roles; #visible? also reads the token's scopes.
      def fetch_time_entry(id)
        entry = TimeEntry.visible(user).find_by(id: id.to_i)
        raise ToolError, "No visible time entry with id #{id.inspect}" if entry.nil? || !entry.visible?(user)

        entry
      end

      def attributes_from(entry, arguments)
        attributes = target_attributes(arguments)
        project    = Project.find_by(id: attributes['project_id']) || entry.project
        attributes['hours']       = arguments['hours'] unless arguments['hours'].nil?
        attributes['comments']    = arguments['comments'].to_s unless arguments['comments'].nil?
        attributes['spent_on']    = iso_date(arguments['spent_on'], 'spent_on') unless arguments['spent_on'].nil?
        attributes['activity_id'] = time_entry_activity(project, arguments['activity']).id unless arguments['activity'].nil?
        attributes['user_id']     = time_entry_user_id(entry, arguments['user']) unless arguments['user'].nil?

        values = custom_field_values_for(entry, arguments['custom_field_values'])
        attributes['custom_field_values'] = values if values
        attributes
      end

      # Core's rule for a move: the issue must be visible and its project allow
      # log_time, and an issue brings its project with it.
      def target_attributes(arguments)
        attributes = {}
        attributes['project_id'] = fetch_project(arguments['project']).id unless arguments['project'].nil?
        return attributes if arguments['issue'].nil?
        return attributes.merge('issue_id' => '') if arguments['issue'].to_s == 'none'
        raise InvalidArgument, 'issue must be an issue id, or "none"' unless SchemaValidator.integerish?(arguments['issue'])

        issue = fetch_issue(arguments['issue'])
        authorize!(:log_time, issue.project)
        attributes['project_id'] ||= issue.project_id
        attributes.merge('issue_id' => issue.id)
      end
    end
  end
end
