# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetIssueFields < Tool
      tool 'get_issue_fields',
           title: 'Get settable issue fields',
           description: 'Report what the authenticated user may set on an issue: the attributes it may ' \
                        'set, its custom fields with their allowed values, which are required or read-only, the ' \
                        'statuses the issue may move to, the trackers, categories, versions, assignees and ' \
                        'watchers it may use. Call this before create_issue or update_issue. Pass issue for ' \
                        'an existing issue, or project (and optionally tracker) for one not yet created. When ' \
                        'a required value is not clear from the conversation, ask the user for it; never invent one.',
           permission: :view_issues,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Id of an existing issue.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id, for an issue not yet created.' },
               'tracker' => { 'type' => 'string',
                              'description' => 'Tracker name. With issue, the tracker it would move to; otherwise ' \
                                               'defaults to the first the user may create in.' }
             },
             'additionalProperties' => false
           }

      MAX_TAGS = 100

      private

      def perform(arguments)
        issue    = build_issue(arguments)
        project  = issue.project
        computed = done_ratio_computed_from(issue)

        payload = {
          issue_id: issue.id,
          project_identifier: project&.identifier,
          tracker: issue.tracker&.name,
          # Parameter names, from the same core rule the write tools refuse by.
          settable_attributes: WRITE_ATTRIBUTES.select { |_name, (attribute, _kind)| issue.safe_attribute?(attribute, user) }.keys,
          # Core mixes attribute names with custom field ids here; the ids are
          # reported on each custom field instead.
          required_attributes: core_attributes(issue.required_attribute_names(user)),
          read_only_attributes: core_attributes(issue.read_only_attribute_names(user)),
          done_ratio_field: computed.nil?,
          done_ratio_computed_from: computed,
          custom_fields: custom_fields_for(issue),
          allowed_statuses: issue.new_statuses_allowed_to(user).map do |status|
            { id: status.id, name: status.name, is_closed: status.is_closed? }
          end,
          allowed_trackers: issue.allowed_target_trackers(user).map { |t| { id: t.id, name: t.name } },
          categories: project.issue_categories.map { |c| { id: c.id, name: c.name } },
          fixed_versions: issue.assignable_versions.map { |v| { id: v.id, name: v.name, project: v.project.identifier } },
          assignable_users: issue.assignable_users.map { |u| { id: u.id, login: u.login, name: u.name } }
        }
        # A new issue has no items yet; the plugin takes over as soon as it has.
        if computed.nil? && issue.new_record? && checklist_done_ratio?(issue, adding: true)
          payload[:done_ratio_note] = 'redmine_checklists computes it once the issue has checklist items'
        end
        if user.allowed_to?(:add_issue_watchers, project)
          payload[:addable_watcher_users] = addable_watcher_users(issue).map { |p| principal_row(p) }
        end
        if plugin?(:redmine_checklists)
          payload[:checklists] = { edit: user.allowed_to?(:edit_checklists, project),
                                   done: user.allowed_to?(:done_checklists, project) || user.allowed_to?(:edit_checklists, project) }
        end
        payload[:tags] = tags_for(project) if plugin?(:redmineup_tags)
        payload
      end

      def build_issue(arguments)
        if arguments['issue'].present?
          issue = fetch_issue(arguments['issue'])
          authorize!(:view_issues, issue.project)
          move_to_tracker(issue, arguments['tracker']) if arguments['tracker'].present?
          issue
        elsif arguments['project'].present?
          new_issue(arguments)
        else
          raise ToolError, 'Pass issue for an existing issue, or project for one not yet created'
        end
      end

      # Core's edit form after a tracker change, in memory and never saved: the status, custom fields
      # and workflow rules follow the tracker. Refused as update_issue refuses the move.
      def move_to_tracker(issue, name)
        return if name == issue.tracker&.name

        problems = []
        change_tracker!(issue, name, problems)
        refuse_blocked!(issue, problems)
      end

      def new_issue(arguments)
        project = fetch_project(arguments['project'])
        authorize!(:add_issues, project)

        issue = Issue.new(project: project, author: user)
        # A tracker as well as a project, or core reports no custom fields at
        # all -- so build the issue the way core's new-issue form does.
        issue.tracker = resolve_tracker(project, issue.allowed_target_trackers(user), arguments['tracker'])
        issue
      end

      def resolve_tracker(project, allowed, name)
        if name.blank?
          tracker = allowed.first
          raise ToolError, "You may not create issues in project #{project.identifier}" if tracker.nil?

          return tracker
        end

        tracker = project.trackers.find_by(name: name.to_s)
        raise ToolError, "Project #{project.identifier} has no tracker named #{name.inspect}" if tracker.nil?
        raise ToolError, 'You do not have permission to do that' unless allowed.where(id: tracker.id).exists?

        tracker
      end

      def core_attributes(names)
        names.grep_v(/\A\d+\z/).sort
      end

      def custom_fields_for(issue)
        custom_field_rows(issue, issue.required_attribute_names(user))
      end

      # Tags are global; the plugin's own list, capped so a big instance stays readable.
      def tags_for(project)
        names = Issue.all_tags.map(&:name)
        { edit: user.allowed_to?(:edit_tags, project), create: user.allowed_to?(:create_tags, project),
          available: names.first(MAX_TAGS), truncated: names.size > MAX_TAGS }
      end
    end
  end
end
