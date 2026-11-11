# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateProject < Tool
      tool 'update_project',
           title: 'Update project',
           description: 'Change a project\'s name, description, homepage, visibility, parent, modules, trackers ' \
                        'or custom fields. Only what is sent changes; enabled_modules and trackers replace the ' \
                        'whole list, so read get_project first. Disabling a module hides its content from ' \
                        'everyone, and is_public opens the project to every user: get explicit confirmation ' \
                        'for either. End with the url.',
           permission: :edit_project,
           scopes: %i[select_project_publicity select_project_modules manage_members add_subprojects add_project],
           rendered: %w[description],
           plain: %w[name],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'name' => { 'type' => 'string', 'description' => 'Up to 255 characters.' },
               'parent' => { 'type' => %w[string integer],
                             'description' => 'Parent project identifier or numeric id, or "none" for a root project.' },
               'description' => { 'type' => 'string', 'description' => 'Shown on the project overview.' },
               'homepage' => { 'type' => 'string', 'description' => 'URL, up to 255 characters.' },
               'is_public' => { 'type' => 'boolean',
                                'description' => 'Public projects are readable by every user, and by anonymous ' \
                                                 'visitors where the instance allows them.' },
               'enabled_modules' => { 'type' => 'array',
                                      'description' => 'Module names, replacing the list: issue_tracking, time_tracking, ' \
                                                       'news, documents, files, wiki, repository, boards, calendar, gantt.' },
               'trackers' => { 'type' => 'array', 'description' => 'Tracker names from list_enumerations, replacing the list.' },
               'inherit_members' => { 'type' => 'boolean', 'description' => 'Inherit the members of the parent project.' },
               'custom_field_values' => { 'type' => 'object',
                                          'description' => 'By field id from get_project; a value, or its label when ' \
                                                          'it names one value.' }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_readable_project(arguments['project'])
        authorize_open!(:edit_project, project)

        problems   = []
        attributes = project_attributes_from(project, arguments.except('project'), problems)
        refuse_blocked!(project, problems)
        raise ToolError, 'Pass at least one field to change' if attributes.empty?

        project.safe_attributes = attributes
        require_custom_fields!(project)
        save_or_refuse!(project, 'update the project')

        saved_project_state(project)
      end
    end
  end
end
