# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Built on core's IssueQuery rather than hand-written conditions, so the
    # filters this accepts are the ones Redmine itself accepts -- custom fields
    # and filters registered by installed plugins included -- without a list
    # kept in step by hand.
    class SearchIssues < Tool
      # Their values are the user directory or the project list. Both are large
      # and both already have a paged tool of their own, so describe names the
      # tool instead of inlining thousands of rows.
      USER_FILTERS    = %w[assigned_to_id author_id watcher_id updated_by last_updated_by].freeze
      PROJECT_FILTERS = %w[project_id subproject_id].freeze
      MAX_VALUES      = 50

      tool 'search_issues',
           title: 'Search issues',
           description: 'Search issues visible to the authenticated user. All filters are optional ' \
                        'and are combined with AND. Returns newest-updated first. total_count answers ' \
                        '"how many": limit 1 is enough to count, do not page to count. Call with ' \
                        'describe: true to list the filters, operators, sortable fields and values ' \
                        'this Redmine accepts, including custom fields.',
           permission: :view_issues,
           schema: {
             'type' => 'object',
             'properties' => {
               'describe' => { 'type' => 'boolean',
                               'description' => 'Return the available filters and sortable fields instead of issues.' },
               'project' => { 'type' => %w[string integer],
                             'description' => 'Restrict to one project (identifier or numeric id).' },
               'query' => { 'type' => 'string', 'description' => 'Text searched across subject, description and notes.' },
               'status' => { 'type' => 'string', 'enum' => %w[open closed all],
                             'description' => 'Issue status filter. Defaults to open.' },
               'tracker' => { 'type' => 'string', 'description' => 'Tracker name, e.g. Bug.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'version' => { 'type' => 'string', 'description' => 'Target version name. Needs project.' },
               'assigned_to_me' => { 'type' => 'boolean', 'description' => 'Only issues assigned to the authenticated user.' },
               'assigned_to_id' => { 'type' => 'integer', 'description' => 'User id of the assignee, from list_users.' },
               'author_id' => { 'type' => 'integer', 'description' => 'User id of the author, from list_users.' },
               'created_since' => { 'type' => 'string', 'description' => 'Only issues created on or after this ISO-8601 date.' },
               'updated_since' => { 'type' => 'string', 'format' => 'date',
                                    'description' => 'Only issues updated on or after this ISO-8601 date.' },
               'due_before' => { 'type' => 'string', 'description' => 'Only issues due on or before this ISO-8601 date.' },
               'query_id' => { 'type' => 'integer', 'description' => 'Id of a saved query to run, from list_queries.' },
               'filters' => { 'type' => 'object',
                              'description' => 'Any other filter, keyed by field name from describe. A value may be ' \
                                               '{"operator": "><", "values": ["1", "5"]}, or a bare string or array, ' \
                                               'which means operator "=".' },
               'sort' => { 'type' => 'string',
                           'description' => 'field:direction, e.g. "priority:desc". Direction defaults to desc.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap. Defaults to 0.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1, 'description' => 'Maximum issues to return.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = arguments['project'].present? ? fetch_project(arguments['project']) : nil
        # .visible filters by role but not by OAuth scope -- see the note on
        # Tool. This is the check that honours a narrowed token.
        authorize!(:view_issues, project) if project

        # IssueQuery#base_scope calls Issue.visible with no argument, so it
        # reads User.current rather than this tool's user. The controller sets
        # them to the same object; assert that rather than depend on it.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

        saved = arguments['query_id'].present?
        query = build_query(arguments, project)
        return describe(query) if arguments['describe']

        apply_filters!(query, arguments, project)
        apply_sort!(query, arguments['sort'], saved)
        raise ToolError, "Invalid search: #{query.errors.full_messages.join('; ')}" unless query.valid?

        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        rows   = query.issues(offset: offset, limit: limit).map { |issue| summarise(issue) }
        paged(total: query.issue_count, offset: offset, key: :issues, rows: rows)
      end

      # A saved query is read and never saved, so the stored row is untouched.
      def build_query(arguments, project)
        # name '_' because Query validates its presence and a transient query
        # has none; this is what core's retrieve_query does (queries_helper.rb:368).
        return IssueQuery.new(name: '_', project: project) if arguments['query_id'].blank?

        query = IssueQuery.visible(user).find_by(id: arguments['query_id'].to_i)
        raise ToolError, "No visible saved query with id #{arguments['query_id'].inspect}" if query.nil?

        # Before anything memoises available_filters, which vary by project.
        query.project = project if project
        query
      end

      def apply_filters!(query, arguments, project)
        explicit = arguments['filters'].is_a?(Hash) ? arguments['filters'] : {}
        reject_conflicts!(arguments, explicit)

        case arguments['status'].presence
        when 'closed' then set_filter!(query, 'status_id', 'c')
        when 'all'    then set_filter!(query, 'status_id', '*')
        when 'open'   then set_filter!(query, 'status_id', 'o')
        end

        set_filter!(query, 'any_searchable', '~', arguments['query']) if arguments['query'].present?
        set_filter!(query, 'assigned_to_id', '=', 'me')              if arguments['assigned_to_me']
        set_filter!(query, 'assigned_to_id', '=', arguments['assigned_to_id']) if arguments['assigned_to_id'].present?
        set_filter!(query, 'author_id', '=', arguments['author_id']) if arguments['author_id'].present?

        set_filter!(query, 'tracker_id', '=', tracker_id(arguments['tracker']))   if arguments['tracker'].present?
        set_filter!(query, 'priority_id', '=', priority_id(arguments['priority'])) if arguments['priority'].present?
        set_filter!(query, 'fixed_version_id', '=', version_id(project, arguments['version'])) if arguments['version'].present?

        set_filter!(query, 'created_on', '>=', iso_date(arguments['created_since'], 'created_since')) if arguments['created_since'].present?
        set_filter!(query, 'updated_on', '>=', iso_date(arguments['updated_since'], 'updated_since')) if arguments['updated_since'].present?
        set_filter!(query, 'due_date', '<=', iso_date(arguments['due_before'], 'due_before')) if arguments['due_before'].present?

        explicit.each do |field, spec|
          operator, values = operator_and_values(spec)
          set_filter!(query, field.to_s, operator, values)
        end
      end

      def reject_conflicts!(arguments, explicit)
        if arguments['status'].present? && explicit.key?('status_id')
          raise ToolError, 'Pass status or filters["status_id"], not both'
        end
        return unless arguments['assigned_to_me'] && arguments['assigned_to_id'].present?

        raise ToolError, 'Pass assigned_to_me or assigned_to_id, not both'
      end

      # add_filter drops an unknown field, and a value that is not an Array,
      # without saying so (query.rb:735). A dropped filter widens the result,
      # which reads to the caller exactly like an answer, so check first.
      def set_filter!(query, field, operator, values = '')
        available = query.available_filters[field]
        unless available
          raise ToolError, "Unknown filter #{field.inspect}. Call with describe: true for the ones this Redmine accepts"
        end

        legal = Query.operators_by_filter_type[available[:type]] || []
        unless legal.include?(operator)
          raise ToolError, "Operator #{operator.inspect} is not valid for #{field.inspect}. Valid: #{legal.join(', ')}"
        end

        query.add_filter(field, operator, Array(values).map(&:to_s))
      end

      def operator_and_values(spec)
        return ['=', Array(spec)] unless spec.is_a?(Hash)

        [spec['operator'].presence&.to_s || '=', Array(spec['values'] || '')]
      end

      def apply_sort!(query, sort, saved)
        if sort.blank?
          # Today's documented order. A saved query keeps the order it stores.
          query.sort_criteria = [%w[updated_on desc]] unless saved
          return
        end

        field, direction = sort.to_s.split(':', 2)
        direction = direction.presence || 'desc'
        legal = sortable_fields(query)

        raise ToolError, "Cannot sort by #{field.inspect}. Sortable: #{legal.join(', ')}" unless legal.include?(field)
        raise ToolError, "sort direction must be asc or desc, got #{direction.inspect}" unless %w[asc desc].include?(direction)

        query.sort_criteria = [[field, direction]]
      end

      def sortable_fields(query)
        query.sortable_columns.select { |_name, sortable| sortable.present? }.keys.sort
      end

      # --- describe -----------------------------------------------------------

      def describe(query)
        {
          filters: query.available_filters.map { |field, filter| describe_filter(field, filter) },
          sortable: sortable_fields(query)
        }
      end

      def describe_filter(field, filter)
        entry = { field: field, name: filter[:name], type: filter[:type].to_s,
                  operators: Query.operators_by_filter_type[filter[:type]] || [] }

        # Returning before reading filter[:values] also skips evaluating its
        # lambda, which is a query per filter.
        return entry.merge(values: nil, note: 'Ids come from list_users.')    if user_valued?(field, filter)
        return entry.merge(values: nil, note: 'Ids come from list_projects.') if PROJECT_FILTERS.include?(field)

        values = Array(filter[:values])
        return entry if values.empty?

        entry.merge(values: values.first(MAX_VALUES).map { |value| labelled(value) },
                    values_truncated: values.size > MAX_VALUES)
      end

      def user_valued?(field, filter)
        USER_FILTERS.include?(field) || filter[:field]&.field_format == 'user'
      end

      # A filter's values are plain strings, or [label, value] pairs.
      def labelled(value)
        label, stored = value.is_a?(Array) ? value : [value, value]
        { value: stored.to_s, label: label.to_s }
      end

      # --- named filter resolution -------------------------------------------

      def tracker_id(name)
        tracker = Tracker.find_by(name: name.to_s)
        raise ToolError, "No tracker named #{name.inspect}" if tracker.nil?

        tracker.id
      end

      def priority_id(name)
        priority = IssuePriority.find_by(name: name.to_s)
        raise ToolError, "No priority named #{name.inspect}" if priority.nil?

        priority.id
      end

      def version_id(project, name)
        raise ToolError, 'version needs a project' if project.nil?

        version = project.shared_versions.find_by(name: name.to_s)
        raise ToolError, "Project #{project.identifier} has no version named #{name.inspect}" if version.nil?

        version.id
      end

      def iso_date(value, name)
        Date.iso8601(value.to_s).iso8601
      rescue ArgumentError
        raise ToolError, "#{name} must be an ISO-8601 date, got #{value.inspect}"
      end

      def summarise(issue)
        {
          id: issue.id,
          subject: issue.subject,
          project: issue.project&.name,
          project_identifier: issue.project&.identifier,
          tracker: issue.tracker&.name,
          status: issue.status&.name,
          priority: issue.priority&.name,
          author: issue.author&.name,
          assigned_to: issue.assigned_to&.name,
          done_ratio: issue.done_ratio,
          created_on: iso(issue.created_on),
          updated_on: iso(issue.updated_on)
        }
      end
    end
  end
end
