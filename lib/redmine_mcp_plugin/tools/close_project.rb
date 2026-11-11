# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CloseProject < Tool
      include ProjectStructure

      tool 'close_project',
           title: 'Close project',
           description: 'Close a project and its subprojects: they stay readable and nothing in them can be ' \
                        'changed until reopen_project. Get explicit confirmation before calling. End with the url.',
           permission: :close_project,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_readable_project(arguments['project'])
        authorize!(:close_project, project)
        raise ToolError, "Project #{project.identifier} is already closed" unless project.active?

        project.close
        saved_project_state(project)
      end
    end
  end
end
