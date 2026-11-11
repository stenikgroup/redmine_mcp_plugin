# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Built on core's ProjectQuery, so the filters, sortable and groupable
    # fields are the ones Redmine's own project list offers this user.
    class ListProjects < Tool
      include QueryTool

      AUTHORISED_FILTERS = { 'id' => { '=' => :project }, 'parent_id' => { '=' => :project } }.freeze

      tool 'list_projects',
           title: 'List projects',
           description: 'List the projects visible to the authenticated user; status 1 is active, 5 closed. ' \
                        'filters narrow by any project field, custom fields included: call with ' \
                        'describe: true for the filters, operators, values, sortable and groupable fields ' \
                        'this Redmine accepts, or describe: "<field>" for one filter. total_count answers ' \
                        '"how many".',
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
               'custom_fields' => { 'type' => 'array',
                                    'description' => 'Custom field ids to return with each project.' },
               'sort' => { 'type' => 'string', 'description' => 'field:asc or field:desc; desc by default.' },
               'group_by' => { 'type' => 'string',
                               'description' => 'Count the whole filtered set per group, e.g. "cf_<id>". Fields from describe.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap.' },
               'limit' => { 'type' => 'integer', 'description' => 'Maximum projects to return.', 'minimum' => 1 }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        # base_scope reads User.current rather than this tool's user.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

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

        results(query, arguments, custom_field_ids!(arguments['custom_fields']))
      end

      def results(query, arguments, fields)
        # As a scope around the query the name lands in core's own SQL, so the
        # group counts cover it as well.
        scope, counts = named(arguments['name']).scoping do
          [query.results_scope, (query.result_count_by_group if query.grouped?)]
        end
        limit    = limit_for(arguments)
        offset   = offset_for(arguments)
        projects = scope.offset(offset).limit(limit)
        projects = projects.preload(:custom_values) if fields
        parents  = visible_parent_ids(projects)

        payload = paged(total: scope.count, offset: offset, key: :projects,
                        rows: projects.map { |project| summarise(project, parents, fields) })
        payload[:groups] = group_rows(counts) if counts
        payload
      end

      # name also matches the identifier, which no core filter does.
      def named(needle)
        return Project.all if needle.blank?

        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(needle.to_s)}%"
        Project.where('LOWER(projects.name) LIKE LOWER(:p) OR LOWER(projects.identifier) LIKE LOWER(:p)', p: pattern)
      end

      # Core's API names a parent only to a caller who can see it.
      def visible_parent_ids(projects)
        Project.visible(user).where(id: projects.filter_map(&:parent_id)).pluck(:id)
      end

      # Refused rather than left out: a field missing from every row would read as "no value".
      def custom_field_ids!(raw)
        return nil if raw.blank?

        ids     = Array(raw).map(&:to_s)
        unknown = ids - ProjectCustomField.visible(user).where(id: ids).pluck(:id).map(&:to_s)
        return ids if unknown.empty?

        raise ToolError, "No visible project custom field with id #{unknown.join(', ')}. " \
                         'get_project lists the custom fields of a project with their ids'
      end

      # Their values are the whole project list, which this tool already pages.
      def describe_filter(field, filter)
        return super unless AUTHORISED_FILTERS.key?(field)

        { field: field, name: filter[:name], type: filter[:type].to_s, operators: operators_for(filter[:type]),
          values: nil, note: 'Project ids from this tool, or "mine".' }
      end

      # Redmine filters only by the fields with "Used as a filter" on; for one
      # without it the spelling suggestions would name other fields.
      def unknown_filter!(query, field)
        id   = field.to_s[/\Acf_(\d+)\z/, 1]
        name = ProjectCustomField.visible(user).where(is_filter: false).find_by(id: id)&.name
        super if name.nil?

        raise ToolError, "#{field} (#{name}) is not \"Used as a filter\" in Redmine, so nothing can filter by it. " \
                         "Read it with custom_fields: [#{id}]"
      end

      def summarise(project, parents, fields)
        row = {
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
        row[:custom_fields] = custom_fields_for(project, fields) if fields
        row
      end

      # Core's own rule per project, so a field restricted to roles the caller
      # lacks there is absent from that row.
      def custom_fields_for(project, fields)
        project.visible_custom_field_values(user)
               .select { |value| fields.include?(value.custom_field_id.to_s) }
               .map { |value| labelled_custom_field_row(value) }
      end
    end
  end
end
