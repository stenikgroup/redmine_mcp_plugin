# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class AddFile < Tool
      tool 'add_file',
           title: 'Add a text file to a project',
           description: 'Add a text file to a project\'s Files module, on the project or on one of its ' \
                        'versions. Project members may be emailed. End with the url.',
           permission: :manage_files,
           plain: %w[description],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'filename' => { 'type' => 'string', 'description' => 'With extension, e.g. notes.md.' },
               'content' => { 'type' => 'string', 'description' => 'The file text.' },
               'description' => { 'type' => 'string' },
               'version' => { 'type' => 'integer', 'description' => 'Version id from get_project, to file it under that version.' }
             },
             'required' => %w[project filename content],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        raise ToolError, "Project #{project.identifier} is closed; reopen it first" if project.closed?

        require_module!(project, :files)
        authorize!(:manage_files, project)
        container = container_for(project, arguments['version'])
        content   = arguments['content'].to_s.b
        raise ToolError, 'content must not be empty' if content.empty?

        attachment = Attachment.new(file: content, author: user)
        attachment.filename     = arguments['filename'].to_s
        attachment.content_type = Redmine::MimeType.of(attachment.filename) || 'text/plain'
        save_or_refuse!(attachment, 'add the file')

        # Core's own path, mail included: the file is attached by its token.
        saved = Attachment.attach_files(container, [{ 'token' => attachment.token, 'description' => arguments['description'].to_s }])
        raise ToolError, 'Could not add the file' if saved[:files].blank?

        Mailer.deliver_attachments_added(saved[:files]) if Setting.notified_events.include?('file_added')
        row = attachment_row(saved[:files].first).merge(project_identifier: project.identifier,
                                                        files_url: absolute_url(:project_files_url, project))
        row[:version] = { id: container.id, name: container.name } if container.is_a?(Version)
        row
      end

      def container_for(project, version_id)
        return project if version_id.nil?

        project.versions.find_by(id: version_id) || raise(ToolError, "Project #{project.identifier} has no version with id #{version_id}")
      end
    end
  end
end
