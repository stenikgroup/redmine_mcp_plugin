# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Built on core's TimeEntryQuery, so the filters, sortable and groupable
    # fields are the ones Redmine's own Spent time list offers this user.
    class ListTimeEntries < Tool
      include QueryTool

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
        # .visible filters by role but not by OAuth scope -- see the note on
        # Tool. This is the check that honours a narrowed token.
        authorize!(:view_time_entries, project) if project

        # TimeEntryQuery#base_scope calls TimeEntry.visible with no argument, so
        # it reads User.current rather than this tool's user.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

        query = TimeEntryQuery.new(name: '_', project: project)
        return describe(query) if arguments['describe']

        apply_filters!(query, arguments, project)
        apply_sort!(query, arguments['sort'], default: [%w[spent_on desc]])
        apply_group_by!(query, arguments['group_by'])
        raise ToolError, "Invalid search: #{query.errors.full_messages.join('; ')}" unless query.valid?

        results(query, arguments)
      end

      def results(query, arguments)
        limit   = limit_for(arguments)
        offset  = offset_for(arguments)
        scope   = query.results_scope.preload(:activity, :user, :project, issue: :project)
        rows    = scope.offset(offset).limit(limit).map { |entry| summarise(entry) }

        payload = paged(total: scope.count, offset: offset, key: :entries, rows: rows)
        # Totals come from core's own SQL aggregates over the whole filtered
        # set, never from the loaded page. hours is named rather than taken from
        # totalable_columns: this tool is about hours.
        payload[:total_hours] = query.total_for(:hours)
        payload[:groups] = group_rows(query.result_count_by_group, query.total_by_group_for(:hours)) if query.grouped?
        payload
      end

      def apply_filters!(query, arguments, project)
        explicit = arguments['filters'].is_a?(Hash) ? arguments['filters'] : {}

        set_filter!(query, 'project_id', '=', project.id)                    if project
        set_filter!(query, 'issue_id', '=', issue_id(arguments['issue']))    if arguments['issue'].present?
        set_filter!(query, 'user_id', '=', arguments['user'])                if arguments['user'].present?
        set_filter!(query, 'activity_id', '=', activity_id(project, arguments['activity'])) if arguments['activity'].present?

        apply_spent_on!(query, arguments)
        apply_explicit_filters!(query, explicit)
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

      def issue_id(id)
        issue = Issue.visible(user).find_by(id: id.to_i)
        raise ToolError, "No visible issue with id #{id.inspect}" if issue.nil?

        issue.id
      end

      # The filter matches the system activity, so a project override resolves
      # to its parent (time_entry_query.rb:113).
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
          comments: entry.comments
        }
      end

      # A caller may see time entries on a project without seeing every issue in
      # it. Core shows the id always and the subject only when the issue is
      # visible (application_helper.rb:306); its API sends the id alone
      # (timelog/index.api.rsb:6). Match that.
      def issue_field(entry)
        return nil if entry.issue.nil?

        { id: entry.issue_id, subject: (entry.issue.subject if entry.issue.visible?(user)) }
      end
    end
  end
end
