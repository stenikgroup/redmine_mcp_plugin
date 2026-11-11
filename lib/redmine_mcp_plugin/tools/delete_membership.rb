# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteMembership < Tool
      include ProjectStructure

      tool 'delete_membership',
           title: 'Remove a project member',
           description: 'Remove a user or a group from a project: they lose every role there, and with it ' \
                        'their access when the project is private. A member with an inherited role, or with ' \
                        'a role the caller may not manage, cannot be removed. Get explicit confirmation ' \
                        'before calling.',
           permission: :manage_members,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'principal' => { 'type' => %w[integer string],
                                'description' => 'User or group id from list_memberships, or "me".' }
             },
             'required' => %w[project principal],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize_open!(:manage_members, project)

        id     = user_id_from(arguments['principal'], 'principal')
        member = project.memberships.find_by(user_id: id)
        raise ToolError, "#{id} is not a member of #{project.identifier}" if member.nil?

        # Core's rule, which its API reports as a bare 422.
        unless member.deletable?(user)
          cause = member.any_inherited_role? ? 'a role is inherited from a group or the parent project' : 'you may not manage every role they hold'
          raise ToolError, "Cannot remove this member: #{cause}"
        end

        row = membership_row(member)
        member.destroy
        row.merge(deleted: true, project_identifier: project.identifier)
      end
    end
  end
end
