# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateIssueCategory < Tool
      tool 'create_issue_category',
           title: 'Create issue category',
           description: 'Add an issue category to a project. get_project lists the existing ones.',
           permission: :manage_categories,
           plain: %w[name],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'name' => { 'type' => 'string', 'description' => 'Up to 60 characters, unique in the project.' },
               'assigned_to' => { 'type' => %w[integer string],
                                  'description' => 'User id, or "me": new issues of this category with no assignee ' \
                                                   'are assigned to them.' }
             },
             'required' => %w[project name],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        require_module!(project, :issue_tracking)
        authorize_open!(:manage_categories, project)

        category = project.issue_categories.build
        category.safe_attributes = category_attributes_from(category, arguments)
        save_or_refuse!(category, 'create the category')

        category_state(category)
      end
    end
  end
end
