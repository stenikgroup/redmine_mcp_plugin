# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssue < Tool
      tool 'update_issue',
           title: 'Update issue',
           description: 'Change an issue: any field get_issue_fields lists, custom fields, watchers, tags, ' \
                        'with an optional note in the same journal. Refused by name when the role or ' \
                        'workflow forbids; then do not retry without the refused fields: tell the user and ' \
                        'ask. "none" clears an optional date or reference. End with the url.',
           permission: %i[edit_issues edit_own_issues],
           scopes: %i[manage_subtasks add_issue_watchers delete_issue_watchers set_issues_private set_own_issues_private],
           plugin_scopes: { redmineup_tags: %i[edit_tags create_tags] },
           plugin_properties: { redmineup_tags: %w[add_tag_list remove_tag_list] },
           rendered: %w[description notes],
           plain: %w[subject],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'subject' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'tracker' => { 'type' => 'string', 'description' => 'Tracker name.' },
               'status' => { 'type' => 'string', 'description' => 'Status name.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'category' => { 'type' => %w[string integer], 'description' => 'Name or id.' },
               'fixed_version' => { 'type' => %w[string integer], 'description' => 'Target version, name or id.' },
               'assigned_to' => { 'type' => %w[integer string], 'description' => 'User id, or "me".' },
               'parent' => { 'type' => %w[integer string], 'description' => 'Parent issue id.' },
               'start_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'due_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'done_ratio' => { 'type' => 'integer' },
               'estimated_hours' => { 'type' => 'number' },
               'is_private' => { 'type' => 'boolean' },
               'add_watcher_users' => { 'type' => 'array', 'description' => 'User or group ids, or "me".' },
               'remove_watcher_users' => { 'type' => 'array', 'description' => 'User or group ids, or "me".' },
               'add_tag_list' => { 'type' => 'array', 'description' => 'Tag names.' },
               'remove_tag_list' => { 'type' => 'array', 'description' => 'Tag names.' },
               'custom_field_values' => { 'type' => 'object',
                                         'description' => 'By field id from get_issue_fields; a value, or its label ' \
                                                          'when it names one value.' },
               'notes' => { 'type' => 'string', 'description' => 'Note recorded with this change.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      class << self
        # The tags plugin is named only while it is installed.
        def mcp_description = plugin?(:redmineup_tags) ? super : super.sub(' tags,', '')
      end

      private

      def perform(arguments)
        issue  = fetch_issue(arguments['issue'])
        sent   = sent_fields(arguments)
        notes  = arguments['notes'].to_s
        others = (TAG_KEYS + WATCHER_KEYS).any? { |key| arguments[key].present? }
        raise ToolError, 'Pass at least one field to change, or a note' if sent.empty? && notes.strip.empty? && !others

        # Tool-level and uniform: editing this issue at all, noting on it at all.
        authorize_edit!(issue) if sent.any?
        authorize_note!(issue) unless notes.strip.empty?

        # The journal snapshots the record now, before anything is assigned, as
        # core's update does; a tracker change is journaled only that way. notes
        # delegates to the journal and is swallowed when there is none.
        issue.init_journal(user, notes)

        # Every per-field check runs; one refusal then names each blocked parameter.
        problems = []
        change_tracker!(issue, arguments['tracker'], problems) if sent.include?('tracker')
        attributes = issue_attributes_from(issue, arguments.except('tracker'), problems)
        attributes['tracker_id'] = issue.tracker_id if sent.include?('tracker')
        tags          = plugin?(:redmineup_tags) ? tag_attributes(issue, arguments, problems) : {}
        adds, removes = watcher_changes(issue, arguments, problems)
        refuse_blocked!(issue, problems)

        # Indifferent access: the tags plugin reads its keys as symbols.
        issue.safe_attributes = attributes.merge(tags).with_indifferent_access
        # Once the status and tracker are set: a workflow may require a field
        # at the new status, and a tracker move makes core recheck them all.
        require_issue_custom_fields!(issue)
        journal_tags!(issue) if tags.any?
        Issue.transaction do
          raise ToolError, "Could not update issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

          apply_watcher_changes!(issue, adds, removes)
        end

        issue_state(stored(issue), arguments).merge(journal_id: issue.current_journal&.id)
      end
    end
  end
end
