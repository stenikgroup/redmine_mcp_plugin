# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ReopenProject < Tool
      include ProjectStructure

      tool 'reopen_project',
           title: 'Reopen project',
           description: 'Reopen a closed project and its closed subprojects. End with the url.',
           permission: :close_project,
           write: true,
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
        raise ToolError, "Project #{project.identifier} is not closed" unless project.closed?

        project.reopen
        saved_project_state(project)
      end
    end
  end
end
