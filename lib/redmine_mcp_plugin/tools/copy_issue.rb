# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CopyIssue < Tool
      tool 'copy_issue',
           title: 'Copy issue',
           description: 'Create a new issue as a copy of another, in the same project or in project. The copy ' \
                        'keeps the fields, custom fields and parent of the source, starts at the default ' \
                        'status, and is linked to it as "copied to" unless link is false. Any field sent ' \
                        'replaces the copied value, as in create_issue. Refused by name when the role or ' \
                        'workflow forbids; then tell the user and ask. End with the url.',
           permission: :copy_issues,
           scopes: %i[add_issues manage_subtasks add_issue_watchers set_issues_private set_own_issues_private],
           rendered: %w[description],
           plain: %w[subject],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Id of the issue to copy.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Target project identifier or numeric id. Defaults to the source\'s.' },
               'copy_attachments' => { 'type' => 'boolean', 'description' => 'Copy the attachments. Default true.' },
               'copy_subtasks' => { 'type' => 'boolean', 'description' => 'Copy the subtasks too. Default false.' },
               'link' => { 'type' => 'boolean', 'description' => 'Relate the copy to the source. Default true.' },
               'subject' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'tracker' => { 'type' => 'string', 'description' => 'Tracker name. Defaults to the source\'s.' },
               'status' => { 'type' => 'string', 'description' => 'Status name.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'category' => { 'type' => %w[string integer], 'description' => 'Name or id.' },
               'fixed_version' => { 'type' => %w[string integer], 'description' => 'Target version, name or id.' },
               'assigned_to' => { 'type' => %w[integer string], 'description' => 'User id, or "me".' },
               'parent' => { 'type' => %w[integer string], 'description' => 'Parent issue id, or "none".' },
               'start_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'due_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'done_ratio' => { 'type' => 'integer' },
               'estimated_hours' => { 'type' => 'number' },
               'is_private' => { 'type' => 'boolean' },
               'custom_field_values' => { 'type' => 'object',
                                         'description' => 'By field id from get_issue_fields; a value, or its label ' \
                                                          'when it names one value.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      OPTIONS = %w[issue project copy_attachments copy_subtasks link tracker].freeze

      private

      def perform(arguments)
        source  = fetch_issue(arguments['issue'])
        authorize!(:copy_issues, source.project)
        project = arguments['project'].present? ? fetch_project(arguments['project']) : source.project
        raise ToolError, "Project #{project.identifier} is closed; reopen it first" if project.closed?

        issue = copy_of(source, project, arguments)
        # add_issues decides the trackers of the target project, as for a new issue.
        issue.tracker = tracker_for(issue, arguments['tracker'].presence || source.tracker.name)

        # Every per-field check runs; one refusal then names each blocked parameter.
        problems   = []
        attributes = issue_attributes_from(issue, arguments.except(*OPTIONS), problems)
        refuse_blocked!(issue, problems)

        issue.safe_attributes = attributes
        require_issue_custom_fields!(issue)
        raise ToolError, "Could not copy issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        issue_state(stored(issue), arguments.except(*OPTIONS)).merge(copied_from: source.id)
      end

      # As core's controller builds a copy: the journal carries the "copied to"
      # relation on the source, the watchers follow only with add_issue_watchers.
      def copy_of(source, project, arguments)
        issue = Issue.new
        issue.init_journal(user)
        issue.copy_from(source, attachments: arguments['copy_attachments'] != false,
                                subtasks: arguments['copy_subtasks'] == true,
                                watchers: user.allowed_to?(:add_issue_watchers, project),
                                link: arguments['link'] != false)
        issue.parent_issue_id = source.parent_id
        issue.project = project
        issue.author  = user
        issue
      end
    end
  end
end
