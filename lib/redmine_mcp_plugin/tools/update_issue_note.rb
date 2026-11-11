# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssueNote < Tool
      tool 'update_issue_note',
           title: 'Edit issue note',
           description: 'Edit a note on an issue, by the journal id from get_issue or the journal_id a ' \
                        'write returned. Your own notes, or anyone\'s where your role may edit notes; say ' \
                        'whose note it is and get explicit confirmation before editing someone else\'s. ' \
                        'End with the url.',
           permission: %i[edit_issue_notes edit_own_issue_notes],
           scopes: %i[set_notes_private],
           rendered: %w[notes],
           checks_blank: %w[notes],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'journal' => { 'type' => 'integer', 'description' => 'Journal id of the note.' },
               'notes' => { 'type' => 'string', 'description' => 'The new text; replaces the note.' },
               'private_notes' => { 'type' => 'boolean',
                                    'description' => 'Make the note private or public. Requires the set_notes_private permission.' }
             },
             'required' => %w[journal notes],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        journal = fetch_journal(arguments['journal'])
        raise ToolError, 'This journal has no note to edit; it records field changes only' if journal.notes.blank?
        # Core's rule: edit_issue_notes for anyone's note, edit_own_issue_notes for one's own.
        unless journal.editable_by?(user)
          own = journal.user_id == user.id
          raise ToolError, own ? 'You do not have permission to do that' : "Editing another user's note needs #{permission_labels(:edit_issue_notes)}"
        end
        # Core deletes a journal left with no note and no field changes, so an edit must never blank it.
        raise ToolError, 'notes must not be empty: Redmine deletes a note saved blank' if arguments['notes'].to_s.strip.empty?

        attributes = { 'notes' => arguments['notes'].to_s, 'updated_by' => user }
        private_notes = arguments['private_notes']
        if !private_notes.nil? && private_notes != journal.private_notes?
          authorize!(:set_notes_private, journal.project)
          attributes['private_notes'] = private_notes
        end

        journal.safe_attributes = attributes
        raise ToolError, "Could not update note: #{journal.errors.full_messages.join('; ')}" unless journal.save

        note_state(journal)
      end

      # Core's own edit path finds the note through this scope, private notes included.
      def fetch_journal(id)
        journal = Journal.visible(user).find_by(id: id.to_i)
        raise ToolError, "No visible journal with id #{id.inspect}" if journal.nil?

        journal
      end

      def note_state(journal)
        issue = journal.issue
        {
          journal_id: journal.id,
          issue_id: issue.id,
          author: journal.user&.name,
          notes: journal.notes,
          private_notes: journal.private_notes?,
          updated_on: iso(journal.updated_on),
          url: absolute_url(:issue_url, issue, anchor: "change-#{journal.id}")
        }
      end
    end
  end
end
