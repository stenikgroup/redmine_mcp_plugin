# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateIssue < Tool
      tool 'create_issue',
           title: 'Create issue',
           description: 'Create a new issue in a project. Call get_issue_fields first to learn which ' \
                        'custom fields this user may set and which values are allowed. End with the url.',
           permission: :add_issues,
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                             'description' => 'Project identifier or numeric id.' },
               'subject' => { 'type' => 'string', 'description' => 'Issue subject.' },
               'description' => { 'type' => 'string' },
               'tracker' => { 'type' => 'string',
                              'description' => 'Tracker name. Required when the project allows more than one.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name. Defaults to the Redmine default.' },
               'assigned_to' => { 'type' => %w[integer string],
                                  'description' => 'User id from list_users, or "me".' },
               'custom_fields' => { 'type' => 'object',
                                    'description' => 'Custom field values keyed by numeric field id, e.g. {"7": "3"}. ' \
                                                     'Send the value from get_issue_fields possible_values, never the label.' }
             },
             'required' => %w[project subject],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize!(:add_issues, project)

        issue = Issue.new(project: project, author: user)
        # The tracker decides the custom fields and the default status, so it goes first.
        issue.tracker = tracker_for(project, issue.allowed_target_trackers(user), arguments['tracker'])

        attributes = { 'subject' => arguments['subject'].to_s }
        # Only when sent: a tracker may disable the field, and an absent one must not trip the check.
        attributes['description'] = arguments['description'].to_s unless arguments['description'].nil?

        if (priority_name = arguments['priority'].presence)
          priority = IssuePriority.active.find_by(name: priority_name.to_s)
          raise ToolError, "No active priority named #{priority_name.inspect}" if priority.nil?

          attributes['priority_id'] = priority.id
        end

        attributes['assigned_to_id'] = assignee_id(issue, arguments['assigned_to']) if arguments['assigned_to'].present?

        if (values = custom_field_values_from(arguments))
          attributes['custom_field_values'] = values
        end

        refuse_unknown_custom_fields!(issue, custom_field_ids(arguments))
        refuse_unsettable!(issue, attributes)
        issue.safe_attributes = attributes
        raise ToolError, "Could not create issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        issue_state(issue, custom_field_ids(arguments))
      end

      # add_issues is granted per tracker, and core would silently substitute
      # a permitted one -- which an agent reports as success. Refuse instead.
      def tracker_for(project, allowed, name)
        if name.blank?
          trackers = allowed.to_a
          raise ToolError, 'You do not have permission to do that' if trackers.empty?
          return trackers.first if trackers.one?

          raise ToolError, "Pass tracker. #{project.identifier} allows: #{trackers.map(&:name).join(', ')}"
        end

        tracker = project.trackers.find_by(name: name.to_s)
        raise ToolError, "Project #{project.identifier} has no tracker named #{name.inspect}" if tracker.nil?
        unless allowed.where(id: tracker.id).exists?
          raise ToolError, 'You do not have permission to create issues with tracker ' \
                           "#{name.inspect} in project #{project.identifier}"
        end

        tracker
      end
    end
  end
end
