# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListProjects < Tool
      tool 'list_projects',
           title: 'List projects',
           description: 'List the Redmine projects visible to the authenticated user. Pass include_custom_fields ' \
                        'to read the project custom fields of every row, as get_project gives them for one.',
           permission: :view_project,
           schema: {
             'type' => 'object',
             'properties' => {
               'name' => { 'type' => 'string',
                           'description' => 'Optional case-insensitive substring to filter project name or identifier by.' },
               'include_custom_fields' => { 'type' => 'boolean',
                                            'description' => 'Add the project custom fields visible to the caller ' \
                                                             'to each row. Default false.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'description' => 'Maximum projects to return.', 'minimum' => 1 }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        scope = Project.visible(user).order(:lft)
        if (needle = arguments['name'].presence)
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(needle.to_s)}%"
          scope = scope.where('LOWER(projects.name) LIKE LOWER(:p) OR LOWER(projects.identifier) LIKE LOWER(:p)', p: pattern)
        end

        limit    = limit_for(arguments)
        offset   = offset_for(arguments)
        projects = scope.offset(offset).limit(limit)
        rows = if arguments['include_custom_fields']
                 with_custom_fields(projects.preload(:custom_values).to_a)
               else
                 projects.map { |project| summarise(project) }
               end
        paged(total: scope.count, offset: offset, key: :projects, rows: rows)
      end

      def summarise(project)
        {
          id: project.id,
          identifier: project.identifier,
          name: project.name,
          description: project.description,
          status: project.status,
          is_public: project.is_public?,
          parent_id: project.parent_id,
          created_on: iso(project.created_on),
          updated_on: iso(project.updated_on)
        }
      end

      # Project#visible_custom_field_values per row loads the field list and the
      # caller's membership once per project. The same rule runs here on data
      # loaded once for the whole page.
      def with_custom_fields(projects)
        fields = ProjectCustomField.sorted.preload(:roles).reject { |field| excluded_custom_field?(field.id) }
        roles  = fields.all? { |field| field.visible? || user.admin? } ? {} : roles_by_project(projects)
        projects.map do |project|
          visible = fields.select { |field| visible_field?(field, roles[project.id]) }
          summarise(project).merge(custom_fields: visible.map { |field| stored_row(project, field) })
        end
      end

      # ProjectCustomField#visible_by?.
      def visible_field?(field, roles)
        field.visible? || user.admin? || field.roles.intersect?(roles.to_a)
      end

      # Custom values are preloaded. A field with no stored value reads blank, as core's does.
      def stored_row(project, field)
        values = project.custom_values.select { |v| v.custom_field_id == field.id }.map(&:value)
        custom_field_row(CustomFieldValue.new(custom_field: field, customized: project,
                                              value: field.multiple? ? values : values.first))
      end

      # User#roles_for_project for a page of projects, in two queries instead of
      # one per project: the caller's memberships, then the roles a public
      # project gives its non-members (or anonymous users) in place of the builtin one.
      def roles_by_project(projects)
        ids = projects.map(&:id)
        members = user.memberships.where(project_id: ids).preload(:roles).index_by(&:project_id)
        group_class = user.builtin_role.anonymous? ? GroupAnonymous : GroupNonMember
        overrides = Member.where(project_id: ids).joins(:principal).where(users: { type: group_class.name })
                          .preload(:roles).index_by(&:project_id)

        projects.to_h do |project|
          [project.id, project_roles(project, members[project.id], overrides[project.id])]
        end
      end

      def project_roles(project, member, override)
        return [] if project.archived?
        return member.roles.to_a if member
        return [] unless project.is_public?

        override ? override.roles.to_a : [user.builtin_role]
      end
    end
  end
end
