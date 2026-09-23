# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateIssue < Tool
      tool 'create_issue',
           title: 'Create issue',
           description: 'Create a new issue in a project.',
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
               'assigned_to' => { 'type' => 'string', 'description' => 'Login of the user to assign to.' }
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

          # add_issues is granted per tracker, not per project
          # (app/views/roles/_form.html.erb:75), and the authorize! above only
          # checks the project. Core's own filter sits in safe_attributes=
          # (issue.rb:590): a tracker outside allowed_target_trackers is
          # silently dropped, and issue.rb:605 then substitutes
          # allowed_trackers.first.
          #
          # Refusing instead is a deliberate divergence from core. Core can
          # afford to drop it quietly because it is redisplaying a form to a
          # human who can see which tracker the select box settled on. We answer
          # an agent, which will report success to somebody who will not check,
          # and an issue filed under the wrong tracker reads exactly like one
          # filed correctly. So name the tracker and refuse.
          #
          # The instance method, not the class one, on purpose: it is the
          # identical call safe_attributes= makes, so this can never refuse a
          # tracker core would have accepted.
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

        issue.safe_attributes = attributes
        raise ToolError, "Could not create issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        { id: issue.id, subject: issue.subject, project_identifier: project.identifier,
          status: issue.status&.name, tracker: issue.tracker&.name, created_on: iso(issue.created_on) }
      end
    end
  end
end
