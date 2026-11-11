# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateProject < Tool
      include ProjectStructure

      tool 'create_project',
           title: 'Create project',
           description: 'Create a project, or a subproject with parent. What is left out takes the instance ' \
                        'defaults (visibility, modules, trackers). A project cannot be deleted from here: show ' \
                        'the user the name, identifier, parent and visibility and get explicit confirmation ' \
                        'before calling. End with the url.',
           permission: %i[add_project add_subprojects],
           scopes: %i[select_project_publicity select_project_modules manage_members],
           rendered: %w[description],
           plain: %w[name],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'name' => { 'type' => 'string', 'description' => 'Up to 255 characters.' },
               'identifier' => { 'type' => 'string',
                                 'description' => 'Up to 100 characters: lower case letters, digits, dashes and ' \
                                                  'underscores, not only digits. It cannot be changed afterwards.' },
               'parent' => { 'type' => %w[string integer], 'description' => 'Parent project identifier or numeric id.' },
               'description' => { 'type' => 'string', 'description' => 'Shown on the project overview.' },
               'homepage' => { 'type' => 'string', 'description' => 'URL, up to 255 characters.' },
               'is_public' => { 'type' => 'boolean',
                                'description' => 'Public projects are readable by every user, and by anonymous ' \
                                                 'visitors where the instance allows them.' },
               'enabled_modules' => { 'type' => 'array', 'items' => { 'type' => 'string' },
                                      'description' => 'Module names, replacing the list: issue_tracking, time_tracking, ' \
                                                       'news, documents, files, wiki, repository, boards, calendar, gantt.' },
               'trackers' => { 'type' => 'array', 'items' => { 'type' => %w[string integer] },
                               'description' => 'Tracker names from list_enumerations, replacing the list.' },
               'inherit_members' => { 'type' => 'boolean', 'description' => 'Inherit the members of the parent project.' },
               'custom_field_values' => { 'type' => 'object',
                                          'description' => 'By field id from get_project; a value, or its label when ' \
                                                          'it names one value.' }
             },
             'required' => %w[name identifier],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project    = Project.new
        problems   = []
        # Core checks the parent of every new project, sent or not: a root project needs add_project.
        attributes = project_attributes_from(project, { 'parent' => 'none' }.merge(arguments.compact), problems)
        refuse_blocked!(project, problems)

        project.safe_attributes = attributes
        require_custom_fields!(project)
        save_or_refuse!(project, 'create the project')
        # As core's controller: a non-administrator becomes a member of what they create.
        project.add_default_member(user) unless user.admin?

        saved_project_state(project)
      end
    end
  end
end
