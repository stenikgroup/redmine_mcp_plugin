# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Built on core's IssueQuery, so the filters accepted are Redmine's own --
    # custom fields and plugin filters included -- with no list kept by hand.
    class SearchIssues < Tool
      include QueryTool

      NAMED_FILTERS = { 'status' => 'status_id', 'query' => 'any_searchable', 'tracker' => 'tracker_id',
                        'priority' => 'priority_id', 'version' => 'fixed_version_id',
                        'assigned_to' => 'assigned_to_id', 'author' => 'author_id',
                        'created_since' => 'created_on', 'updated_since' => 'updated_on',
                        'due_before' => 'due_date' }.freeze

      # A relation filter names issues under "=" and a project under "=p".
      RELATION = { '=' => :issue, '=p' => :project }.freeze

      AUTHORISED_FILTERS = {
        'project_id'       => { '=' => :project },
        'subproject_id'    => { '=' => :project },
        'issue_id'         => { '=' => :issue },
        'parent_id'        => { '=' => :issue, '~' => :issue },
        'child_id'         => { '=' => :issue, '~' => :issue },
        'fixed_version_id' => { '=' => :version },
        'category_id'      => { '=' => :category }
      }.merge(IssueRelation::TYPES.keys.to_h { |type| [type, RELATION] }).freeze

      tool 'search_issues',
           title: 'Search issues',
           description: 'Search issues visible to the authenticated user. All filters are optional ' \
                        'and are combined with AND. Returns newest-updated first. total_count answers ' \
                        '"how many": limit 1 is enough to count, do not page to count. Call with ' \
                        'describe: true to list the filters, operators, sortable fields and values ' \
                        'this Redmine accepts, including custom fields. With group_by, groups covers ' \
                        'the whole filtered set, not just the returned page.',
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
               'assigned_to' => { 'type' => %w[integer string],
                                  'description' => 'Assignee: a user id from list_users, or "me".' },
               'author' => { 'type' => %w[integer string],
                             'description' => 'Author: a user id from list_users, or "me".' },
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
               'group_by' => { 'type' => 'string',
                               'description' => 'Group the whole filtered set and return a count per group, ' \
                                                'e.g. "assigned_to". Fields from describe.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap. Defaults to 0.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1, 'description' => 'Maximum issues to return.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = arguments['project'].present? ? fetch_project(arguments['project']) : nil
        # .visible honours roles but not OAuth scopes; this honours the token.
        authorize!(:view_issues, project) if project

        # base_scope reads User.current rather than this tool's user; the
        # controller sets them to the same object, so assert it rather than trust it.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

        saved = arguments['query_id'].present?
        query = build_query(arguments, project)
        return describe(query) if arguments['describe']

        apply_filters!(query, arguments, project)
        apply_sort!(query, arguments['sort'], default: [%w[updated_on desc]], saved: saved)
        apply_group_by!(query, arguments['group_by'])
        raise ToolError, "Invalid search: #{query.errors.full_messages.join('; ')}" unless query.valid?

        limit   = limit_for(arguments)
        offset  = offset_for(arguments)
        # Core preloads only the query's columns; the rows name these too.
        rows    = query.issues(offset: offset, limit: limit, include: %i[author tracker assigned_to])
                       .map { |issue| summarise(issue) }
        payload = paged(total: query.issue_count, offset: offset, key: :issues, rows: rows)
        # Counted in SQL over the whole filtered set, not the page.
        payload[:groups] = group_rows(query.result_count_by_group) if query.grouped?
        payload
      end

      # A saved query is read and never saved, so the stored row is untouched.
      def build_query(arguments, project)
        # A name because Query validates its presence; core does the same for
        # the transient query behind its own issue list.
        return IssueQuery.new(name: '_', project: project) if arguments['query_id'].blank?

        query = IssueQuery.visible(user).find_by(id: arguments['query_id'].to_i)
        raise ToolError, "No visible saved query with id #{arguments['query_id'].inspect}" if query.nil?

        # Before anything memoises available_filters, which vary by project.
        query.project = project if project
        query
      end

      def apply_filters!(query, arguments, project)
        explicit = explicit_filters(arguments)
        reject_conflicts!(arguments, explicit)
        authorize_filters!(query, explicit, :view_issues)

        case arguments['status'].presence
        when 'closed' then set_filter!(query, 'status_id', 'c')
        when 'all'    then set_filter!(query, 'status_id', '*')
        when 'open'   then set_filter!(query, 'status_id', 'o')
        end

        set_filter!(query, 'any_searchable', '~', arguments['query']) if arguments['query'].present?
        set_filter!(query, 'assigned_to_id', '=', user_ref!(arguments['assigned_to'], 'assigned_to')) if arguments['assigned_to'].present?
        set_filter!(query, 'author_id', '=', user_ref!(arguments['author'], 'author'))                if arguments['author'].present?

        set_filter!(query, 'tracker_id', '=', tracker_id(arguments['tracker']))   if arguments['tracker'].present?
        set_filter!(query, 'priority_id', '=', priority_id(arguments['priority'])) if arguments['priority'].present?
        set_filter!(query, 'fixed_version_id', '=', version_id(project, arguments['version'])) if arguments['version'].present?

        set_filter!(query, 'created_on', '>=', iso_date(arguments['created_since'], 'created_since')) if arguments['created_since'].present?
        set_filter!(query, 'updated_on', '>=', iso_date(arguments['updated_since'], 'updated_since')) if arguments['updated_since'].present?
        set_filter!(query, 'due_date', '<=', iso_date(arguments['due_before'], 'due_before')) if arguments['due_before'].present?

        apply_explicit_filters!(query, explicit)
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
