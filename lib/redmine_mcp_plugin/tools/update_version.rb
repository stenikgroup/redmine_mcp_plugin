# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateVersion < Tool
      tool 'update_version',
           title: 'Update version',
           description: 'Change a version\'s name, description, due date, status, sharing or wiki page. Only ' \
                        'what is sent changes. Narrowing sharing removes the version from the issues of the ' \
                        'projects that lose it. End with the url.',
           permission: :manage_versions,
           plain: %w[name description],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'version' => { 'type' => 'integer', 'description' => 'Version id from get_project.' },
               'name' => { 'type' => 'string', 'description' => 'Up to 60 characters, unique in the project.' },
               'due_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD, or "none" to clear it.' },
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
             'required' => %w[version],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        version = fetch_version(arguments['version'])
        authorize_open!(:manage_versions, version.project)

        problems   = []
        attributes = version_attributes_from(version, arguments, problems)
        refuse_blocked!(version, problems)
        raise ToolError, 'Pass at least one field to change' if attributes.empty?

        version.safe_attributes = attributes
        require_custom_fields!(version)
        save_or_refuse!(version, 'update the version')

        version_state(version)
      end
    end
  end
end
