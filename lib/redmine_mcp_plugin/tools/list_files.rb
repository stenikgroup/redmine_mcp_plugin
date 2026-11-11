# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListFiles < Tool
      tool 'list_files',
           title: 'List project files',
           description: 'List the files of a project\'s Files module: those of the project and those attached ' \
                        'to its versions. get_attachment reads one.',
           permission: :view_files,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1 }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        require_module!(project, :files)
        authorize!(:view_files, project)

        # As core's index: the project's own files, then each version's.
        containers = [project] + project.versions.includes(:attachments).to_a.sort.reverse
        files      = containers.flat_map { |container| container.attachments.sort_by(&:filename).map { |file| [container, file] } }
        limit      = limit_for(arguments)
        offset     = offset_for(arguments)
        rows       = (files.slice(offset, limit) || []).map { |container, file| file_row(container, file) }
        paged(total: files.size, offset: offset, key: :files, rows: rows)
      end

      def file_row(container, file)
        row = attachment_row(file).merge(digest: file.digest, downloads: file.downloads)
        row[:version] = { id: container.id, name: container.name } if container.is_a?(Version)
        row
      end
    end
  end
end
