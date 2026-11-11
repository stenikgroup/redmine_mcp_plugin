# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssueCategory < Tool
      tool 'update_issue_category',
           title: 'Update issue category',
           description: 'Rename an issue category or change its default assignee. Only what is sent changes.',
           permission: :manage_categories,
           plain: %w[name],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'category' => { 'type' => 'integer', 'description' => 'Category id from get_project.' },
               'name' => { 'type' => 'string', 'description' => 'Up to 60 characters, unique in the project.' },
               'assigned_to' => { 'type' => %w[integer string],
                                  'description' => 'User id, "me", or "none" to clear it.' }
             },
             'required' => %w[category],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        category = fetch_issue_category(arguments['category'])
        require_module!(category.project, :issue_tracking)
        authorize_open!(:manage_categories, category.project)

        attributes = category_attributes_from(category, arguments)
        raise ToolError, 'Pass at least one field to change' if attributes.empty?

        category.safe_attributes = attributes
        save_or_refuse!(category, 'update the category')

        category_state(category)
      end
    end
  end
end
