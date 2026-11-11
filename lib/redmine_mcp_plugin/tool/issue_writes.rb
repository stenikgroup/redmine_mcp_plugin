# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # The fields create_issue, update_issue and copy_issue take: each resolved
    # against core's own list, and each refusal charged to its parameter.
    module IssueWrites
      include Checklists
      include CustomFields
      include Watchers

      # parameter => [core attribute, kind]. The plain kinds (text, date, integer,
      # number, boolean) need no resolver, so a new such field is one row here and
      # one schema line. tracker is settled by the tool before the others, since
      # it decides what the others are checked against.
      WRITE_ATTRIBUTES = {
        'subject'             => %w[subject text],
        'description'         => %w[description text],
        'tracker'             => %w[tracker_id tracker],
        'status'              => %w[status_id status],
        'priority'            => %w[priority_id priority],
        'category'            => %w[category_id category],
        'fixed_version'       => %w[fixed_version_id fixed_version],
        'assigned_to'         => %w[assigned_to_id assigned_to],
        'parent'              => %w[parent_issue_id parent],
        'start_date'          => %w[start_date date],
        'due_date'            => %w[due_date date],
        'done_ratio'          => %w[done_ratio done_ratio],
        'estimated_hours'     => %w[estimated_hours number],
        'is_private'          => %w[is_private boolean],
        'watcher_users'       => %w[watcher_user_ids watcher_users],
        'custom_field_values' => %w[custom_field_values custom_field_values]

      }.freeze
      PARAMETER_NAMES = WRITE_ATTRIBUTES.to_h { |name, (attribute, _kind)| [attribute, name] }.freeze

      # "none" clears these; parent handles it on its own path.
      CLEARABLE = %w[date category fixed_version assigned_to].freeze

      DONE_RATIO_COMPUTED = { 'status'    => 'computed from the status on this Redmine',
                              'checklist' => 'computed from the checklist by redmine_checklists' }.freeze

      private

      def parameter_name(attribute) = PARAMETER_NAMES.fetch(attribute, attribute)

      # Null means not sent; so does an empty custom_field_values object.
      def sent_fields(arguments)
        WRITE_ATTRIBUTES.keys.select { |name| !arguments[name].nil? && arguments[name] != {} }
      end

      # Every per-field check runs and each refusal is charged to its parameter,
      # so one message names everything the caller has to change.
      def issue_attributes_from(issue, arguments, problems)
        WRITE_ATTRIBUTES.each_with_object({}) do |(name, (attribute, kind)), attributes|
          value = arguments[name]
          next if value.nil?

          unless issue.safe_attribute?(attribute, user)
            problems << blocked_name(issue, attribute)
            next
          end

          clear  = value == 'none' && CLEARABLE.include?(kind)
          result = clear ? '' : blocked(problems, name) { issue_value(issue, name, kind, value) }
          attributes[attribute] = result unless result.nil?
        end
      end

      def issue_value(issue, name, kind, value)
        case kind
        when 'text'                then value.to_s
        when 'date'                then iso_date(value, name)
        when 'status'              then allowed_status_id(issue, value)
        when 'priority'            then priority_id(value)
        when 'category'            then issue_category_id(issue, value)
        when 'fixed_version'       then issue_version_id(issue, value)
        when 'assigned_to'         then assignee_id(issue, value)
        when 'parent'              then parent_attribute(issue, value)
        when 'done_ratio'          then done_ratio_value(issue, value)
        when 'watcher_users'       then watcher_ids(issue, value, name)
        when 'custom_field_values' then custom_field_values_for(issue, value)
        else value
        end
      end

      def blocked_name(issue, key)
        name  = parameter_name(key)
        cause = blocked_cause(issue, key)
        cause ? "#{name} (#{cause})" : name
      end

      # Core gates three safe attributes on a permission, named by its label so
      # the user knows what to ask for; the rest come from the tracker or workflow.
      def blocked_cause(issue, key)
        needs = case key
                when 'parent_issue_id'  then %i[manage_subtasks]
                when 'watcher_user_ids' then %i[add_issue_watchers]
                when 'is_private'
                  issue.author_id == user.id ? %i[set_issues_private set_own_issues_private] : %i[set_issues_private]
                end
        return "needs #{permission_labels(needs)}" if needs&.none? { |p| user.allowed_to?(p, issue.project) }
        return "disabled on tracker #{issue.tracker&.name}" if issue.disabled_core_fields.include?(key)
        return 'read-only by workflow' if issue.read_only_attribute_names(user).include?(key)

        nil
      end

      # The tracker decides the fields, the statuses and the custom fields, so it
      # is settled before the other checks; one the caller may not use refuses at
      # once, since nothing else can be checked against it.
      def change_tracker!(issue, name, problems)
        return problems << blocked_name(issue, 'tracker_id') unless issue.safe_attribute?('tracker_id', user)

        issue.tracker = tracker_for(issue, name)
      end

      # add_issues is granted per tracker, and core would silently substitute a
      # permitted one -- which an agent reports as success. Refuse instead. Core
      # applies the same rule when an existing issue changes tracker.
      def tracker_for(issue, name)
        allowed = issue.allowed_target_trackers(user)
        project = issue.project
        if name.blank?
          trackers = allowed.to_a
          raise ToolError, 'You do not have permission to do that' if trackers.empty?
          return trackers.first if trackers.one?

          raise ToolError, "Pass tracker. #{project.identifier} allows: #{trackers.map(&:name).join(', ')}"
        end

        tracker = project.trackers.find_by(name: name.to_s)
        raise ToolError, "Project #{project.identifier} has no tracker named #{name.inspect}" if tracker.nil?

        unless allowed.where(id: tracker.id).exists?
          # One core rule, two acts: creating with a tracker, or moving an issue to one.
          act = issue.new_record? ? 'create issues with' : 'move issues to'
          raise ToolError, "You do not have permission to #{act} tracker #{name.inspect} in project #{project.identifier}"
        end

        tracker
      end

      # Core keeps the old status silently when the workflow has no such transition.
      def allowed_status_id(issue, name)
        status = IssueStatus.find_by(name: name.to_s)
        raise ToolError, "No issue status named #{name.inspect}" if status.nil?
        return status.id if status.id == issue.status_id

        allowed = issue.new_statuses_allowed_to(user)
        return status.id if allowed.any? { |s| s.id == status.id }

        names = allowed.map(&:name)
        raise ToolError, "#{name.inspect} is not allowed here; allowed: #{names.any? ? names.join(', ') : 'none'}"
      end

      def priority_id(name)
        priority = IssuePriority.active.find_by(name: name.to_s)
        raise ToolError, "No active priority named #{name.inspect}" if priority.nil?

        priority.id
      end

      # Name or id against the project's own list; names are unique per project.
      def issue_category_id(issue, value)
        categories = issue.project.issue_categories.to_a
        category   = categories.detect { |c| c.id.to_s == value.to_s || c.name == value.to_s }
        return category.id if category

        raise ToolError, "No category #{value.inspect} in #{issue.project.identifier}. " \
                         "Categories: #{categories.map(&:name).join(', ')}"
      end

      # Core's own list for this issue; shared versions of other projects may repeat a name.
      def issue_version_id(issue, value)
        versions = issue.assignable_versions
        found    = versions.select { |v| v.id.to_s == value.to_s || v.name == value.to_s }
        return found.first.id if found.one?

        choices = (found.any? ? found : versions).map { |v| "#{v.name} (#{v.project.identifier}) id #{v.id}" }.join(', ')
        raise ToolError, "Version #{value.inspect} is ambiguous here; pass the id: #{choices}" if found.any?

        raise ToolError, "No assignable version #{value.inspect} for #{issue.project.identifier}. Versions: #{choices}"
      end

      def done_ratio_value(issue, value)
        computed = done_ratio_computed_from(issue)
        raise ToolError, DONE_RATIO_COMPUTED.fetch(computed) if computed

        value
      end

      # What overwrites done_ratio here, or nil when it is a field. Core computes
      # it from the status under its setting. redmine_checklists, under its own,
      # recomputes it from the items with a journal-less update on every edit and
      # tick (Checklist.recalc_issue_done_ratio, from its edit hook and its
      # controller) once the issue has items, so a value sent now would not last.
      def done_ratio_computed_from(issue)
        return 'status' unless Issue.use_field_for_done_ratio?
        return 'checklist' if checklist_done_ratio?(issue)

        nil
      end

      # Core's own rule, which also admits the author and the current assignee.
      def assignee_id(issue, value)
        id = user_id_from(value, 'assigned_to')
        return id if issue.assignable_users.any? { |principal| principal.id == id }

        raise ToolError, "#{id} is not assignable on #{issue.project.identifier}"
      end

      # Core says only "Parent task is invalid" for several causes; name them with
      # its own predicates.
      def parent_attribute(issue, value)
        return '' if value == 'none'
        raise InvalidArgument, 'parent must be an issue id, or "none"' unless SchemaValidator.integerish?(value)

        parent = fetch_issue(value)
        if !issue.new_record? && issue.is_or_is_ancestor_of?(parent)
          raise ToolError, "##{parent.id} is this issue or one of its subtasks"
        end
        unless issue.valid_parent_project?(parent)
          raise ToolError, "##{parent.id} is in #{parent.project.identifier}, outside what the " \
                           "cross-project subtasks setting (#{cross_project_label}) allows"
        end

        parent.id.to_s
      end

      def cross_project_label
        setting = Setting.cross_project_subtasks
        I18n.t(setting.present? ? "label_cross_project_#{setting}" : :label_disabled, locale: caller_locale)
      end

      # Charged to custom_field_values, as the refusals before the assignment are.
      def require_issue_custom_fields!(issue)
        problems = []
        blocked(problems, 'custom_field_values') { require_custom_fields!(issue, issue.required_attribute_names(user)) }
        refuse_blocked!(issue, problems)
      end
    end
  end
end
