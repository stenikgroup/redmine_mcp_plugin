# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssue < Tool
      tool 'update_issue',
           title: 'Update issue',
           description: 'Change an existing issue: status, assignee, priority, subject, description ' \
                        'and custom fields, with an optional note recorded in the same journal entry. ' \
                        'Call get_issue_fields first to learn what this user may set and which values ' \
                        'are allowed. Changes the role or workflow does not permit are refused by ' \
                        'name. End with the url.',
           permission: %i[edit_issues edit_own_issues],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'subject' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'status' => { 'type' => 'string',
                             'description' => 'Status name, from allowed_statuses in get_issue_fields.' },
               'assigned_to' => { 'type' => %w[integer string],
                                  'description' => 'User id from list_users, or "me".' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'custom_fields' => { 'type' => 'object',
                                    'description' => 'Custom field values keyed by numeric field id, e.g. {"7": "3"}. ' \
                                                     'Send the value from get_issue_fields possible_values, never the label.' },
               'notes' => { 'type' => 'string', 'description' => 'Note recorded with this change.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue      = fetch_issue(arguments['issue'])
        attributes = attributes_from(arguments, issue)
        notes      = arguments['notes'].to_s
        raise ToolError, 'Pass at least one field to change, or a note' if attributes.empty? && notes.strip.empty?

        authorize_edit!(issue) if attributes.any?
        authorize_note!(issue) unless notes.strip.empty?
        refuse_unsettable!(issue, attributes)
        refuse_status!(issue, attributes['status_id'], arguments['status']) if attributes.key?('status_id')
        refuse_unknown_custom_fields!(issue, custom_field_ids(arguments))

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

      # Core keeps the old status silently when the workflow has no such transition.
      def refuse_status!(issue, status_id, name)
        return if status_id == issue.status_id

        allowed = issue.new_statuses_allowed_to(user)
        return if allowed.any? { |status| status.id == status_id }

        names = allowed.map(&:name)
        raise ToolError, "Status #{name.inspect} is not allowed here. Allowed: #{names.any? ? names.join(', ') : 'none'}"
      end

      def attributes_from(arguments, issue)
        attributes = {}
        # nil means not sent, never "clear it".
        attributes['subject']     = arguments['subject'].to_s     unless arguments['subject'].nil?
        attributes['description'] = arguments['description'].to_s unless arguments['description'].nil?

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

        attributes['assigned_to_id'] = assignee_id(issue, arguments['assigned_to']) if arguments['assigned_to'].present?

        if (values = custom_field_values_from(arguments))
          attributes['custom_field_values'] = values
        end

        attributes
      end
    end
  end
end
