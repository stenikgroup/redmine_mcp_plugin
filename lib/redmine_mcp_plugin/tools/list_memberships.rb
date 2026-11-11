# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListMemberships < Tool
      include ProjectStructure

      tool 'list_memberships',
           title: 'List project members',
           description: 'List the members of a project, users and groups, each with its roles; a role marked ' \
                        'inherited comes from a group or the parent project. For a caller who may manage ' \
                        'members, manageable_roles lists the roles update_membership accepts.',
           permission: :view_members,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer], 'description' => 'Project identifier or numeric id.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1 }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize!(:view_members, project)

        scope  = project.memberships
        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        rows   = scope.includes(:principal, member_roles: :role).order(:id).offset(offset).limit(limit)
                      .map { |member| membership_row(member) }
        result = paged(total: scope.count, offset: offset, key: :memberships, rows: rows)
        result[:manageable_roles] = user.managed_roles(project).map { |role| role_row(role) } if user.allowed_to?(:manage_members, project)
        result
      end
    end
  end
end
