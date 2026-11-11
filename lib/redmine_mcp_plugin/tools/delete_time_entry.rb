# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteTimeEntry < Tool
      tool 'delete_time_entry',
           title: 'Delete time entry',
           description: 'Delete a time entry for good. Your own entries, or anyone\'s where your role may edit ' \
                        'time entries; say whose entry it is and get explicit confirmation before calling.',
           permission: %i[edit_time_entries edit_own_time_entries],
           scopes: %i[view_time_entries],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'time_entry' => { 'type' => 'integer', 'description' => 'Time entry id from list_time_entries.' }
             },
             'required' => %w[time_entry],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        entry = TimeEntry.visible(user).find_by(id: arguments['time_entry'].to_i)
        raise ToolError, "No visible time entry with id #{arguments['time_entry'].inspect}" if entry.nil? || !entry.visible?(user)
        raise ToolError, "Project #{entry.project.identifier} is closed; reopen it first" if entry.project.closed?
        # Core's rule: edit_time_entries for anyone's entry, edit_own_time_entries for one's own.
        unless entry.editable_by?(user)
          own = entry.user_id == user.id
          raise ToolError, own ? 'You do not have permission to do that' : "Deleting another user's time needs #{permission_labels(:edit_time_entries)}"
        end
        raise ToolError, "Could not delete the time entry: #{entry.errors.full_messages.join('; ')}" unless entry.destroy && entry.destroyed?

        { deleted: true, id: entry.id, hours: entry.hours.to_f, user: entry.user&.name,
          issue_id: entry.issue_id, project_identifier: entry.project.identifier }
      end
    end
  end
end
