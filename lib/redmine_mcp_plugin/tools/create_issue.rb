# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateIssue < Tool
      tool 'create_issue',
           title: 'Create issue',
           description: 'Create a new issue in a project. Call get_issue_fields first to learn which ' \
                        'custom fields this user may set and which values are allowed. Report the ' \
                        'saved state from the reply, not what was requested. After a successful ' \
                        'write, always finish by asking the user to check the result at the ' \
                        'returned url.',
           permission: :add_issues,
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                             'description' => 'Project identifier or numeric id.' },
               'subject' => { 'type' => 'string', 'description' => 'Issue subject.' },
               'description' => { 'type' => 'string' },
               'tracker' => { 'type' => 'string', 'description' => 'Tracker name. Defaults to the project default.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name. Defaults to the Redmine default.' },
               'assigned_to' => { 'type' => 'string', 'description' => 'Login of the user to assign to.' },
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
        attributes = { 'subject' => arguments['subject'].to_s,
                       'description' => arguments['description'].to_s }

        if (tracker_name = arguments['tracker'].presence)
          tracker = project.trackers.find_by(name: tracker_name.to_s)
          raise ToolError, "Project #{project.identifier} has no tracker named #{tracker_name.inspect}" if tracker.nil?

          # add_issues is granted per tracker, and core would silently substitute
          # a permitted one -- which an agent reports as success. Refuse instead.
          unless issue.allowed_target_trackers(user).where(id: tracker.id).exists?
            raise ToolError, 'You do not have permission to create issues with tracker ' \
                             "#{tracker_name.inspect} in project #{project.identifier}"
          end

          attributes['tracker_id'] = tracker.id
        end

        if (priority_name = arguments['priority'].presence)
          priority = IssuePriority.active.find_by(name: priority_name.to_s)
          raise ToolError, "No active priority named #{priority_name.inspect}" if priority.nil?

          attributes['priority_id'] = priority.id
        end

        if (login = arguments['assigned_to'].presence)
          assignee = project.assignable_users.find_by(login: login.to_s)
          raise ToolError, "#{login.inspect} is not an assignable user on #{project.identifier}" if assignee.nil?

          attributes['assigned_to_id'] = assignee.id
        end

        if (values = custom_field_values_from(arguments))
          attributes['custom_field_values'] = values
        end

        issue.safe_attributes = attributes
        raise ToolError, "Could not create issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        issue_state(issue, custom_field_ids(arguments))
      end
    end
  end
end
