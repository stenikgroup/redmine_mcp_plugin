# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteAttachment < Tool
      tool 'delete_attachment',
           title: 'Delete attachment',
           description: 'Delete an attachment for good: a file of an issue, a wiki page, a project or a ' \
                        'version. On an issue the removal is recorded in its history. Name the file and get ' \
                        'explicit confirmation before calling.',
           permission: %i[edit_issues edit_own_issues manage_files delete_wiki_pages_attachments],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'attachment' => { 'type' => 'integer', 'description' => 'Attachment id, from get_issue or list_files.' }
             },
             'required' => %w[attachment],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        attachment = Attachment.find_by(id: arguments['attachment'].to_i)
        container  = attachment&.container
        # The right to delete, as core, not the right to read a file. An issue is
        # the exception core makes: its attachments_deletable? needs the issue
        # visible too, and Issue#visible? honours the token's view_issues scope.
        # The same message as for a missing id, so a hidden issue is not confirmed.
        if container.nil? || attachment.project.nil? || !attachment.project.visible?(user) ||
           (container.is_a?(Issue) && !container.visible?(user))
          raise ToolError, "No visible attachment with id #{arguments['attachment'].inspect}"
        end
        raise ToolError, "Project #{attachment.project.identifier} is closed; reopen it first" if attachment.project.closed?

        authorize_delete!(attachment, container)
        # As core: an issue journals the removal, and the association runs its callbacks.
        container.init_journal(user) if container.respond_to?(:init_journal)
        container.attachments.delete(attachment)

        { deleted: true, id: attachment.id, filename: attachment.filename,
          container: { type: container.class.name, id: container.id } }
      end

      # Core's rule is the container's attachments_deletable?. An issue's goes
      # through attributes_editable?, which misses OAuth scopes, so it is checked as an edit.
      def authorize_delete!(attachment, container)
        return authorize_edit!(container) if container.is_a?(Issue)

        raise ToolError, 'You do not have permission to do that' unless attachment.deletable?(user)
      end
    end
  end
end
