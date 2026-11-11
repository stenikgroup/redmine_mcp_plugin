# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteVersion < Tool
      include ProjectStructure

      tool 'delete_version',
           title: 'Delete version',
           description: 'Delete a version for good. Redmine refuses one that issues target, that a custom ' \
                        'field refers to, or that has files. Get explicit confirmation before calling.',
           permission: :manage_versions,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'version' => { 'type' => 'integer', 'description' => 'Version id from get_project.' }
             },
             'required' => %w[version],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        version = fetch_version(arguments['version'])
        authorize_open!(:manage_versions, version.project)
        raise ToolError, "Cannot delete this version: #{blockers(version).join(', ')}" unless version.deletable?

        version.destroy
        { deleted: true, id: version.id, project_identifier: version.project.identifier }
      end

      # What core's deletable? looks at, named.
      def blockers(version)
        causes = []
        causes << "#{version.fixed_issues.count} issues target it" if version.fixed_issues.any?
        causes << "#{version.attachments.count} files are attached to it" if version.attachments.any?
        causes.presence || ['a custom field value refers to it']
      end
    end
  end
end
