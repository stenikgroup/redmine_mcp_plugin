# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetProject < Tool
      tool 'get_project',
           title: 'Get project',
           description: 'Fetch one project by identifier or numeric id, with its enabled modules, trackers, ' \
                        "issue categories, versions and the project custom fields visible to the caller. #{CUSTOM_FIELD_LABELS}",
           permission: :view_project,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id.' }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project_state(fetch_project(arguments['project']))
      end
    end
  end
end
