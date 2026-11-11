# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateMembership < Tool
      include ProjectStructure

      tool 'update_membership',
           title: 'Add or update a project member',
           description: 'Give a user or a group roles in a project: adds the member, or replaces the roles of ' \
                        'an existing one. roles is the whole list the member keeps, among the manageable_roles ' \
                        'of list_memberships; inherited roles and roles the caller may not manage stay as they ' \
                        'are. Roles grant access to the project: get explicit confirmation before calling.',
           permission: :manage_members,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'principal' => { 'type' => %w[integer string],
                                'description' => 'User id from list_users, a group id, or "me".' },
               'roles' => { 'type' => 'array', 'items' => { 'type' => %w[string integer] }, 'description' => 'Role names or ids, at least one.' }
             },
             'required' => %w[project principal roles],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize_open!(:manage_members, project)

        id     = user_id_from(arguments['principal'], 'principal')
        member = project.memberships.find_by(user_id: id) || Member.new(project: project, principal: new_principal(id))
        roles  = roles_from(project, arguments['roles'])

        member.set_editable_role_ids(roles.map(&:id), user)
        save_or_refuse!(member, member.new_record? ? 'add the member' : 'update the member')

        membership_row(Member.find(member.id)).merge(project_identifier: project.identifier,
                                                     url: absolute_url(:settings_project_url, project, tab: 'members'))
      end

      # Any user or group, as core's API, which checks only that the principal exists.
      def new_principal(id)
        Principal.where(type: %w[User Group]).find_by(id: id) || raise(ToolError, "No user or group with id #{id}")
      end

      # Core keeps the roles the caller may manage and drops the others silently.
      def roles_from(project, values)
        manageable = user.managed_roles(project)
        Array(values).map do |value|
          role = manageable.detect { |r| r.id.to_s == value.to_s || r.name.casecmp?(value.to_s) }
          next role if role

          raise ToolError, "You may not give role #{value.inspect} here; roles: #{manageable.map(&:name).join(', ')}"
        end
      end
    end
  end
end
