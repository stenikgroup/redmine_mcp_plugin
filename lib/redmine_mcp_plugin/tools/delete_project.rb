# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteProject < Tool
      tool 'delete_project',
           title: 'Delete project',
           description: 'Delete a project for good, with its subprojects and everything in them: issues, ' \
                        'time, wiki, files, news. It cannot be undone, and close_project is the reversible ' \
                        'way to retire one. Name the project and get explicit confirmation before calling. ' \
                        'The deletion runs in the background and the user is emailed when it ends: the reply says ' \
                        'scheduled, and deleted only once the project is gone.',
           permission: :delete_project,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'confirm' => { 'type' => 'string', 'description' => 'The project identifier, typed again, as on the web form.' }
             },
             'required' => %w[project confirm],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_readable_project(arguments['project'])
        authorize!(:delete_project, project)
        # Core's rule: an administrator, or delete_project on a project with no subproject.
        unless project.deletable?(user)
          raise ToolError, "Project #{project.identifier} has subprojects; only an administrator may delete it"
        end
        raise ToolError, "confirm must be the project identifier, #{project.identifier.inspect}" unless arguments['confirm'] == project.identifier

        subprojects = project.descendants.pluck(:identifier)
        DestroyProjectJob.schedule(project, user: user)
        # Read back, as every reply: core has only scheduled the deletion, and
        # the job may not have run, or may fail.
        { scheduled: true, deleted: !Project.exists?(project.id), id: project.id, identifier: project.identifier,
          subprojects: subprojects }
      end
    end
  end
end
