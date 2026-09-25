# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Built on core's TimeEntryQuery, so the filters, sortable and groupable
    # fields are the ones Redmine's own Spent time list offers this user.
    class ListTimeEntries < Tool
      include QueryTool

      NAMED_FILTERS = { 'issue' => 'issue_id', 'user' => 'user_id', 'activity' => 'activity_id',
                        'from' => 'spent_on', 'to' => 'spent_on' }.freeze

      AUTHORISED_FILTERS = {
        'project_id'             => { '=' => :project },
        'subproject_id'          => { '=' => :project },
        'issue_id'               => { '=' => :issue, '~' => :issue },
        'issue.parent_id'        => { '=' => :issue, '~' => :issue },
        'issue.fixed_version_id' => { '=' => :version },
        'issue.category_id'      => { '=' => :category }
      }.freeze

      tool 'list_time_entries',
           title: 'List spent time',
           description: 'List and total the time entries visible to the authenticated user. ' \
                        'total_hours and groups cover the whole filtered set, not just the returned ' \
                        'page, so limit 1 is enough to answer "how many hours". Use group_by to ' \
                        'total per person, project, activity, issue or date. Call with describe: true ' \
                        'to list the filters, operators, sortable and groupable fields this Redmine ' \
                        'accepts, including custom fields.',
           permission: :view_time_entries,
           schema: {
             'type' => 'object',
             'properties' => {
               'describe' => { 'type' => 'boolean',
                               'description' => 'Return the available filters, sortable and groupable fields instead of entries.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Restrict to one project (identifier or numeric id).' },
               'issue' => { 'type' => 'integer', 'description' => 'Restrict to one issue id.' },
               'user' => { 'type' => %w[integer string],
                           'description' => 'Who spent the time: a user id from list_users, or "me".' },
               'activity' => { 'type' => 'string', 'description' => 'Activity name, from list_enumerations.' },
               'from' => { 'type' => 'string', 'description' => 'Only time spent on or after this ISO-8601 date.' },
               'to' => { 'type' => 'string', 'description' => 'Only time spent on or before this ISO-8601 date.' },
               'group_by' => { 'type' => 'string',
                               'description' => 'Total per group, e.g. "user", "project", "activity", "issue". ' \
                                                'Fields from describe.' },
               'filters' => { 'type' => 'object',
                              'description' => 'Any other filter, keyed by field name from describe. A value may be ' \
                                               '{"operator": "><", "values": ["1", "5"]}, or a bare string or array, ' \
                                               'which means operator "=".' },
               'sort' => { 'type' => 'string',
                           'description' => 'field:direction, e.g. "spent_on:asc". Direction defaults to desc.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap. Defaults to 0.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1, 'description' => 'Maximum entries to return.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = arguments['project'].present? ? fetch_project(arguments['project']) : nil

        # base_scope reads User.current rather than this tool's user.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

        # The issue decides the scope, so it has to be resolved before the query
        # is built. describe reads no entries and needs none.
        issue = fetch_issue(arguments['issue']) if arguments['issue'].present? && !arguments['describe']
        # Core omits an issue's spent time without this permission; TimeEntry
        # .visible would answer zero instead, which reads as nobody logged any.
        authorize!(:view_time_entries, issue.project) if issue
        scoped = scope_project(project, issue)
        # Only the project actually queried is authorised.
        authorize!(:view_time_entries, scoped) if scoped

        query = TimeEntryQuery.new(name: '_', project: scoped)
        return describe(query) if arguments['describe']

        apply_filters!(query, arguments, issue, scoped)
        apply_sort!(query, arguments['sort'], default: [%w[spent_on desc]])
        apply_group_by!(query, arguments['group_by'])
        raise ToolError, "Invalid search: #{query.errors.full_messages.join('; ')}" unless query.valid?

        results(query, arguments, note_for(project, issue))
      end

      # An issue id is exact where a project name is remembered, so a mismatch
      # answers the issue rather than ANDing the two into a false zero.
      def scope_project(project, issue)
        return project if project.nil? || issue.nil? || in_project?(issue, project)

        issue.project
      end

      def in_project?(issue, project)
        issue.project == project || issue.project.is_descendant_of?(project)
      end

      def note_for(project, issue)
        return nil if project.nil? || issue.nil? || in_project?(issue, project)

        "Issue ##{issue.id} is in #{issue.project.identifier} (#{issue.project.name}), " \
        "not #{project.identifier} (#{project.name}). Answered for the issue; " \
        'the project you named was not used.'
      end

      def results(query, arguments, note = nil)
        limit   = limit_for(arguments)
        offset  = offset_for(arguments)
        scope   = query.results_scope.preload(:activity, :user, :project, :custom_values, issue: :project)
        rows    = scope.offset(offset).limit(limit).map { |entry| summarise(entry) }

        payload = paged(total: scope.count, offset: offset, key: :entries, rows: rows)
        # Core's SQL aggregates cover the whole filtered set, not the page.
        payload[:total_hours] = query.total_for(:hours)
        payload[:groups] = group_rows(query.result_count_by_group, query.total_by_group_for(:hours)) if query.grouped?
        payload[:note] = note if note
        payload
      end

      def apply_filters!(query, arguments, issue, project)
        explicit = explicit_filters(arguments)
        reject_conflicts!(arguments, explicit)
        reject_issue_list!(explicit['issue_id'])
        authorize_filters!(query, explicit, :view_time_entries)

        # No project_id filter: query.project scopes the query already.
        set_filter!(query, 'issue_id', '=', issue.id)                                 if issue
        set_filter!(query, 'user_id', '=', user_ref!(arguments['user'], 'user'))      if arguments['user'].present?
        set_filter!(query, 'activity_id', '=', activity_id(project, arguments['activity'])) if arguments['activity'].present?

        apply_spent_on!(query, arguments)
        apply_explicit_filters!(query, explicit)
      end

      # Core reads one id for issue_id under "="; a list would be cut to the first.
      def reject_issue_list!(spec)
        return if spec.nil?

        operator, values = operator_and_values(spec)
        return unless operator == '=' && ids_in(values).size > 1

        raise ToolError, 'filters["issue_id"] takes one id with "="; use "~" for an issue and its subtasks, ' \
                         'or one call per issue'
      end

      # One filter, not two: Query#filters is keyed by field, so a second
      # spent_on filter would replace the first rather than narrow it.
      def apply_spent_on!(query, arguments)
        from = iso_date(arguments['from'], 'from') if arguments['from'].present?
        to   = iso_date(arguments['to'], 'to')     if arguments['to'].present?

        if from && to then set_filter!(query, 'spent_on', '><', [from, to])
        elsif from    then set_filter!(query, 'spent_on', '>=', from)
        elsif to      then set_filter!(query, 'spent_on', '<=', to)
        end
      end

      # The filter matches the system activity, so a project override resolves
      # to its parent.
      def activity_id(project, name)
        scope    = project ? project.activities : TimeEntryActivity.shared.active
        activity = scope.find_by(name: name.to_s)
        raise ToolError, "No time entry activity named #{name.inspect}" if activity.nil?

        activity.parent_id || activity.id
      end

      def summarise(entry)
        {
          id: entry.id,
          user: entry.user && { id: entry.user_id, name: entry.user.name },
          hours: entry.hours.to_f,
          activity: entry.activity&.name,
          spent_on: entry.spent_on&.iso8601,
          project: entry.project && { id: entry.project_id, identifier: entry.project.identifier,
                                      name: entry.project.name },
          issue: issue_field(entry),
          comments: entry.comments,
          custom_fields: custom_fields_for(entry)
        }
      end

      # Core shows the id always and the subject only when the issue is visible
      # to the caller, who may see a project's time without seeing its issues.
      def issue_field(entry)
        return nil if entry.issue.nil?

        { id: entry.issue_id, subject: (entry.issue.subject if entry.issue.visible?(user)) }
      end

      # Core's own rule, which honours the roles a field is restricted to.
      def custom_fields_for(entry)
        entry.visible_custom_field_values(user).map do |value|
          { id: value.custom_field_id, name: value.custom_field.name, value: value.value }
        end
      end
    end
  end
end
