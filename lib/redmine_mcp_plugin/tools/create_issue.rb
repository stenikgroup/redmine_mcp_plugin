# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Takes no checklist items: offered the parameter, agents filled it on every issue unasked.
    class CreateIssue < Tool
      tool 'create_issue',
           title: 'Create issue',
           description: 'Create an issue. Call get_issue_fields first for what this user may set. ' \
                        '"none" clears an optional date or reference. If refused, do not retry without ' \
                        'the refused fields: tell the user and ask. End with the url.',
           permission: :add_issues,
           scopes: %i[manage_subtasks add_issue_watchers set_issues_private set_own_issues_private],
           plugin_scopes: { redmineup_tags: %i[edit_tags create_tags] },
           plugin_properties: { redmineup_tags: %w[tag_list] },
           rendered: %w[description],
           plain: %w[subject],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'subject' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'tracker' => { 'type' => 'string',
                              'description' => 'Tracker name. Required when the project allows more than one.' },
               'status' => { 'type' => 'string', 'description' => 'Status name.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'category' => { 'type' => %w[string integer], 'description' => 'Name or id.' },
               'fixed_version' => { 'type' => %w[string integer], 'description' => 'Target version, name or id.' },
               'assigned_to' => { 'type' => %w[integer string], 'description' => 'User id, or "me".' },
               'parent' => { 'type' => 'integer', 'description' => 'Parent issue id.' },
               'start_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'due_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'done_ratio' => { 'type' => 'integer' },
               'estimated_hours' => { 'type' => 'number' },
               'is_private' => { 'type' => 'boolean' },
               'watcher_users' => { 'type' => 'array', 'description' => 'User or group ids, or "me".' },
               'tag_list' => { 'type' => 'array', 'description' => 'Tag names.' },
               'custom_field_values' => { 'type' => 'object',
                                         'description' => 'By field id from get_issue_fields; a value, or its label ' \
                                                          'when it names one value.' }
             },
             'required' => %w[project subject],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize!(:add_issues, project)

        issue = Issue.new(project: project, author: user)
        # The tracker decides the fields, the statuses and the custom fields, so it is settled first.
        issue.tracker = tracker_for(issue, arguments['tracker'])

        # Every per-field check runs; one refusal then names each blocked parameter.
        problems   = []
        attributes = issue_attributes_from(issue, arguments.except('tracker'), problems)
        tags = plugin?(:redmineup_tags) ? tag_attributes(issue, arguments, problems) : {}
        refuse_blocked!(issue, problems)

        # Indifferent access: the tags plugin reads its keys as symbols.
        issue.safe_attributes = attributes.merge(tags).with_indifferent_access
        # Once the status is set: a workflow may require a field there.
        require_issue_custom_fields!(issue)
        raise ToolError, "Could not create issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        issue_state(stored(issue), arguments)
      end
    end
  end
end
