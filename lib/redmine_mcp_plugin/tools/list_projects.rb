# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Built on core's ProjectQuery, so the filters, sortable and groupable
    # fields are the ones Redmine's own project list offers this user.
    class ListProjects < Tool
      include QueryTool
      include CustomFields

      AUTHORISED_FILTERS = { 'id' => { '=' => :project }, 'parent_id' => { '=' => :project } }.freeze
      PROJECT_NOTE       = 'Project ids from this tool, or "mine".'

      tool 'list_projects',
           title: 'List projects',
           description: 'List the Redmine projects visible to the authenticated user; status 1 is active, 5 closed. ' \
                        'filters narrow by any project field, custom fields included: call with describe: true ' \
                        'for the filters, operators, values, sortable and groupable fields this Redmine accepts, ' \
                        'or describe: "<field>" for one filter. total_count answers "how many": limit 1 is enough ' \
                        'to count. With group_by, groups covers the whole filtered set. Pass include_custom_fields ' \
                        "to read the project custom fields of every row, as get_project gives them for one. #{CUSTOM_FIELD_LABELS}",
           permission: :view_project,
           schema: {
             'type' => 'object',
             'properties' => {
               'describe' => { 'type' => %w[boolean string],
                               'description' => 'true: the available filters, sortable and groupable fields instead of projects; a field name: that filter only.' },
               'name' => { 'type' => 'string',
                           'description' => 'Optional case-insensitive substring to filter project name or identifier by.' },
               'filters' => { 'type' => 'object',
                              'description' => 'Any filter, keyed by field name from describe. A value may be ' \
                                               '{"operator": "><", "values": ["1", "5"]}, or a bare string or array, ' \
                                               'which means operator "=".' },
               'include_custom_fields' => { 'type' => 'boolean',
                                            'description' => 'Add the project custom fields visible to the caller ' \
                                                             'to each row. Default false.' },
               'sort' => { 'type' => 'string',
                           'description' => 'field:asc or field:desc; desc by default. Left out: the project tree.' },
               'group_by' => { 'type' => 'string',
                               'description' => 'Group the whole filtered set and return a count per group, ' \
                                                'e.g. "cf_<id>". Fields from describe.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'description' => 'Maximum projects to return.', 'minimum' => 1 }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        query = ProjectQuery.new(name: '_')
        # Core's project list starts as "active only" and loads what its columns
        # show; this tool lists closed projects too and builds its own rows.
        query.filters = {}
        query.column_names = %w[name]
        return describe(query, arguments['describe']) if arguments['describe']

        explicit = explicit_filters(arguments)
        authorize_filters!(query, explicit, :view_project)
        apply_explicit_filters!(query, explicit)
        # Core's own order then, the project tree.
        apply_sort!(query, arguments['sort'], default: [])
        apply_group_by!(query, arguments['group_by'])
        raise ToolError, "Invalid search: #{query.errors.full_messages.join('; ')}" unless query.valid?

        results(query, arguments)
      end

      def results(query, arguments)
        # As a scope around the query the name lands in core's own SQL, so the
        # group counts cover it as well.
        scope, counts = named(arguments['name']).scoping do
          [query.results_scope, (query.result_count_by_group if query.grouped?)]
        end
        offset   = offset_for(arguments)
        projects = scope.offset(offset).limit(limit_for(arguments))
        projects = projects.preload(:custom_values) if arguments['include_custom_fields']
        projects = projects.to_a
        parents  = visible_parent_ids(projects)
        rows = if arguments['include_custom_fields']
                 with_custom_fields(projects, parents)
               else
                 projects.map { |project| summarise(project, parents) }
               end

        payload = paged(total: scope.count, offset: offset, key: :projects, rows: rows)
        payload[:groups] = group_rows(counts) if counts
        payload
      end

      # name also matches the identifier, which no core filter does.
      def named(needle)
        return Project.all if needle.blank?

        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(needle.to_s)}%"
        Project.where('LOWER(projects.name) LIKE LOWER(:p) OR LOWER(projects.identifier) LIKE LOWER(:p)', p: pattern)
      end

      # Core's API names a parent only to a caller who can see it; one query for the page.
      def visible_parent_ids(projects)
        Project.visible(user).where(id: projects.filter_map(&:parent_id)).pluck(:id)
      end

      # Their values are the whole project list, which this tool already pages.
      def describe_filter(field, filter)
        return super unless AUTHORISED_FILTERS.key?(field)

        { field: field, name: filter[:name], type: filter[:type].to_s, operators: operators_for(filter[:type]),
          values: nil, note: PROJECT_NOTE }
      end

      # Redmine filters only by the fields with "Used as a filter" on; for one
      # without it the spelling suggestions would name other fields.
      def unknown_filter!(query, field)
        id   = field.to_s[/\Acf_(\d+)\z/, 1]
        name = ProjectCustomField.visible(user).where(is_filter: false).find_by(id: id)&.name unless excluded_custom_field?(id.to_i)
        super if name.nil?

        raise ToolError, "#{field} (#{name}) is not \"Used as a filter\" in Redmine, so nothing can filter by it. " \
                         'Read it with include_custom_fields: true'
      end

      def summarise(project, parents)
        {
          id: project.id,
          identifier: project.identifier,
          name: project.name,
          description: project.description,
          status: project.status,
          is_public: project.is_public?,
          parent_id: (project.parent_id if parents.include?(project.parent_id)),
          created_on: iso(project.created_on),
          updated_on: iso(project.updated_on)
        }
      end

      # Project#visible_custom_field_values per row loads the field list and the
      # caller's membership once per project. The same rule runs here on data
      # loaded once for the whole page, and the labels are looked up once for it too.
      def with_custom_fields(projects, parents)
        fields = ProjectCustomField.sorted.preload(:roles).reject { |field| excluded_custom_field?(field.id) }
        roles  = fields.all? { |field| field.visible? || user.admin? } ? {} : roles_by_project(projects)
        values = projects.to_h do |project|
          visible = fields.select { |field| visible_field?(field, roles[project.id]) }
          [project, visible.map { |field| stored_value(project, field) }]
        end
        labels = custom_value_labels(values.values.flatten)
        values.map do |project, stored|
          summarise(project, parents).merge(custom_fields: stored.map { |value| custom_field_row(value, labels) })
        end
      end

      # ProjectCustomField#visible_by?.
      def visible_field?(field, roles)
        field.visible? || user.admin? || field.roles.intersect?(roles.to_a)
      end

      # Custom values are preloaded. A field with no stored value reads blank, as core's does.
      def stored_value(project, field)
        values = project.custom_values.select { |v| v.custom_field_id == field.id }.map(&:value)
        CustomFieldValue.new(custom_field: field, customized: project, value: field.multiple? ? values : values.first)
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
