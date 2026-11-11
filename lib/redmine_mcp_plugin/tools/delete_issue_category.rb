# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteIssueCategory < Tool
      tool 'delete_issue_category',
           title: 'Delete issue category',
           description: 'Delete an issue category for good. Its issues lose their category, or take ' \
                        'reassign_to. Get explicit confirmation before calling.',
           permission: :manage_categories,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'category' => { 'type' => 'integer', 'description' => 'Category id from get_project.' },
               'reassign_to' => { 'type' => 'integer', 'description' => 'Category id of the same project its issues move to.' }
             },
             'required' => %w[category],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        category = fetch_issue_category(arguments['category'])
        project  = category.project
        require_module!(project, :issue_tracking)
        authorize_open!(:manage_categories, project)

        target = nil
        unless arguments['reassign_to'].nil?
          target = (project.issue_categories - [category]).detect { |c| c.id == arguments['reassign_to'] }
          raise ToolError, "reassign_to must be another category of #{project.identifier}" if target.nil?
        end

        issues = category.issues.count
        category.destroy(target)
        { deleted: true, id: category.id, project_identifier: project.identifier, issues: issues, reassigned_to: target&.id }
      end
    end
  end
end
