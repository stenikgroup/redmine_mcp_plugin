# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssue < Tool
      tool 'update_issue',
           title: 'Update issue',
           description: 'Change an existing issue: status, assignee, priority, subject, description ' \
                        'and custom fields, with an optional note recorded in the same journal entry. ' \
                        'Call get_issue_fields first to learn what this user may set and which values ' \
                        'are allowed. Redmine drops changes the workflow or the user\'s role does not ' \
                        'permit, so report the saved state from the reply, not what was requested. ' \
                        'After a successful write, always finish by asking the user to check the ' \
                        'result at the returned url.',
           permission: %i[edit_issues edit_own_issues],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'id' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'subject' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'status' => { 'type' => 'string',
                             'description' => 'Status name, from allowed_statuses in get_issue_fields.' },
               'assigned_to' => { 'type' => 'string', 'description' => 'Login of the user to assign to.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'custom_fields' => { 'type' => 'object',
                                    'description' => 'Custom field values keyed by numeric field id, e.g. {"7": "3"}. ' \
                                                     'Send the value from get_issue_fields possible_values, never the label.' },
               'notes' => { 'type' => 'string', 'description' => 'Note recorded with this change.' }
             },
             'required' => %w[id],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = Issue.visible(user).find_by(id: arguments['id'].to_i)
        raise ToolError, "No visible issue with id #{arguments['id'].inspect}" if issue.nil?

        attributes = attributes_from(arguments, issue)
        notes      = arguments['notes'].to_s
        raise ToolError, 'Pass at least one field to change, or a note' if attributes.empty? && notes.strip.empty?

        authorize_edit!(issue) if attributes.any?
        authorize_note!(issue) unless notes.strip.empty?

        # notes delegates to the journal and is swallowed when there is none,
        # so the journal has to exist first.
        issue.init_journal(user, notes)
        issue.safe_attributes = attributes
        raise ToolError, "Could not update issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        issue_state(issue, custom_field_ids(arguments)).merge(journal_id: issue.current_journal&.id)
      end

      # Core allows edit_issues, or edit_own_issues on one's own issue, per
      # tracker. attributes_editable? misses OAuth scopes; allowed_to? misses trackers.
      def authorize_edit!(issue)
        scoped = user.allowed_to?(:edit_issues, issue.project) ||
                 (issue.author_id == user.id && user.allowed_to?(:edit_own_issues, issue.project))
        raise ToolError, 'You do not have permission to do that' unless scoped && issue.attributes_editable?(user)
      end

      def attributes_from(arguments, issue)
        attributes = {}
        attributes['subject']     = arguments['subject'].to_s     if arguments.key?('subject')
        attributes['description'] = arguments['description'].to_s if arguments.key?('description')

        if (name = arguments['status'].presence)
          status = IssueStatus.find_by(name: name.to_s)
          raise ToolError, "No issue status named #{name.inspect}" if status.nil?

          attributes['status_id'] = status.id
        end

        if (name = arguments['priority'].presence)
          priority = IssuePriority.active.find_by(name: name.to_s)
          raise ToolError, "No active priority named #{name.inspect}" if priority.nil?

          attributes['priority_id'] = priority.id
        end

        if (login = arguments['assigned_to'].presence)
          assignee = issue.project.assignable_users.find_by(login: login.to_s)
          raise ToolError, "#{login.inspect} is not an assignable user on #{issue.project.identifier}" if assignee.nil?

          attributes['assigned_to_id'] = assignee.id
        end

        if (values = custom_field_values_from(arguments))
          attributes['custom_field_values'] = values
        end

        attributes
      end
    end
  end
end
