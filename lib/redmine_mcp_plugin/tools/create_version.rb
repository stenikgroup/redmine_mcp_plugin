# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateVersion < Tool
      tool 'create_version',
           title: 'Create version',
           description: 'Add a version (milestone) to a project. get_project lists the existing ones. ' \
                        'End with the url.',
           permission: :manage_versions,
           plain: %w[name description],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'name' => { 'type' => 'string', 'description' => 'Up to 60 characters, unique in the project.' },
               'due_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'description' => { 'type' => 'string', 'description' => 'Up to 255 characters.' },
               'status' => { 'type' => 'string', 'enum' => %w[open locked closed],
                             'description' => 'An issue can be assigned to an open version only.' },
               'sharing' => { 'type' => 'string', 'enum' => %w[none descendants hierarchy tree system],
                              'description' => 'Which other projects may use the version.' },
               'wiki_page_title' => { 'type' => 'string', 'description' => 'Wiki page shown on the version.' },
               'default_project_version' => { 'type' => 'boolean',
                                              'description' => 'Make it the target version of new issues in the project.' },
               'custom_field_values' => { 'type' => 'object',
                                          'description' => 'By field id; a value, or its label when it names one value.' }
             },
             'required' => %w[project name],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize_open!(:manage_versions, project)

        version    = project.versions.build
        problems   = []
        attributes = version_attributes_from(version, arguments, problems)
        refuse_blocked!(version, problems)

        version.safe_attributes = attributes
        require_custom_fields!(version)
        save_or_refuse!(version, 'create the version')

        version_state(version)
      end
    end
  end
end
