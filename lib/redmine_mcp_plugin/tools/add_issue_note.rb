# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class AddIssueNote < Tool
      tool 'add_issue_note',
           title: 'Add note to issue',
           description: 'Append a note (comment) to an existing issue. End with the url.',
           permission: :add_issue_notes,
           scopes: %i[set_notes_private],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'notes' => { 'type' => 'string', 'description' => 'The note text.' },
               'private' => { 'type' => 'boolean',
                              'description' => 'Mark the note private. Requires the set_notes_private permission.' }
             },
             'required' => %w[issue notes],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = fetch_issue(arguments['issue'])
        authorize_note!(issue)
        raise ToolError, 'notes must not be empty' if arguments['notes'].to_s.strip.empty?

        # Issue delegates private_notes= to current_journal and swallows it when
        # there is none, so the journal has to exist before the note is marked.
        issue.init_journal(user, arguments['notes'].to_s)

        if arguments['private']
          authorize!(:set_notes_private, issue.project)
          issue.private_notes = true
        end
        raise ToolError, "Could not add note: #{issue.errors.full_messages.join('; ')}" unless issue.save

        { issue_id: issue.id, journal_id: issue.current_journal&.id,
          created_on: iso(issue.current_journal&.created_on), url: absolute_url(:issue_url, issue) }
      end
    end
  end
end
