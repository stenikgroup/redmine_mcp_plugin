# frozen_string_literal: true

module RedmineMcpPlugin
  # What a user may set on an existing project, for get_project_fields and
  # update_projects. A module, not more helpers on Tool: only these two need it.
  #
  # Every guard is core's own check and every option list is the one core's
  # project settings form offers this user, so the report never lists what a
  # write would refuse.
  module ProjectFields
    # parameter => the core attribute it sets. status has none: core closes
    # and reopens through actions of their own.
    FIELDS = {
      'name' => 'name', 'description' => 'description', 'homepage' => 'homepage', 'is_public' => 'is_public',
      'parent' => 'parent_id', 'inherit_members' => 'inherit_members', 'status' => nil,
      'add_enabled_modules' => 'enabled_module_names', 'remove_enabled_modules' => 'enabled_module_names',
      'add_trackers' => 'tracker_ids', 'remove_trackers' => 'tracker_ids',
      'add_issue_custom_fields' => 'issue_custom_field_ids', 'remove_issue_custom_fields' => 'issue_custom_field_ids',
      'default_version' => 'default_version_id', 'default_assigned_to' => 'default_assigned_to_id',
      'default_issue_query' => 'default_issue_query_id', 'custom_field_values' => 'custom_field_values'
    }.freeze

    # The model takes these on any project; the form has them on its "Issue
    # tracking" tab, which exists only with the module.
    ISSUE_TRACKING = %w[add_trackers remove_trackers add_issue_custom_fields remove_issue_custom_fields
                        default_version default_assigned_to default_issue_query].freeze

    # Core drops these attributes silently without the permission.
    GATED = { 'is_public' => :select_project_publicity, 'enabled_module_names' => :select_project_modules }.freeze

    MAX_OPTIONS = 50

    private

    # Why this user cannot set the parameter on this project whatever the
    # value, or nil. edit_project is no read permission, so core refuses it on
    # a closed project; close_project is one.
    def field_block(project, name)
      return (needs(:close_project) unless user.allowed_to?(:close_project, project)) if name == 'status'
      return project.active? ? needs(:edit_project) : 'the project is closed; reopen it first' unless user.allowed_to?(:edit_project, project)

      attribute = FIELDS[name]
      unless project.safe_attribute?(attribute, user)
        return GATED[attribute] ? needs(GATED[attribute]) : 'the parent project is not visible to you'
      end

      'the issue tracking module is not enabled' if ISSUE_TRACKING.include?(name) && !project.module_enabled?(:issue_tracking)
    end

    def needs(permission)
      "needs #{permission_labels(permission)}"
    end

    # --- the options of core's form -----------------------------------------

    def module_options
      Redmine::AccessControl.available_project_modules.map(&:to_s)
    end

    # allowed_parents asks the roles only; the token has to allow it as well.
    def parent_allowed?(project, parent)
      project.allowed_parents(user).include?(parent) && user.allowed_to?(:add_subprojects, parent)
    end

    def version_options(project)
      project.shared_versions.open.to_a
    end

    def assignee_options(project)
      project.assignable_users.to_a
    end

    def query_options(project)
      IssueQuery.only_public.where(project_id: [nil, project.id]).to_a
    end

    # --- values --------------------------------------------------------------

    # The attributes for core's safe_attributes=. Every check runs, and each
    # refusal is charged to its parameter.
    def project_attributes(project, fields, problems)
      fields.except('status').each_with_object({}) do |(name, value), attributes|
        blocked(problems, name) do
          reason = field_block(project, name)
          raise ToolError, reason if reason

          attributes[FIELDS[name]] = attribute_value(project, name, value, fields, attributes)
        end
      end
    end

    def attribute_value(project, name, value, fields, attributes)
      case name
      when 'parent'              then parent_id(project, value)
      when 'default_version'     then clearable(value) { version_id(project, value) }
      when 'default_assigned_to' then clearable(value) { assignee_id(project, value) }
      when 'default_issue_query' then clearable(value) { query_id(project, value) }
      when 'custom_field_values' then custom_values(project, value)
      when /\A(?:add|remove)_/
        verb, kind = name.split('_', 2)
        # The other list of the pair may have changed it already.
        current = attributes[FIELDS[name]] || project.public_send(FIELDS[name]).map(&:to_s)
        items   = set_items(kind, value, Array(fields["#{verb == 'add' ? 'remove' : 'add'}_#{kind}"]))
        verb == 'add' ? current | items : current - items
      else value
      end
    end

    # "none" clears an optional reference. The one the project has may stay,
    # as core's selects keep it on offer.
    def clearable(value)
      value.to_s == 'none' ? '' : yield
    end

    def parent_id(project, value)
      if value.to_s == 'none'
        return '' if project.parent_id.nil? || project.allowed_parents(user).include?(nil)

        raise ToolError, "#{needs(:add_project)} to make it a top-level project"
      end

      parent = fetch_project(value)
      return parent.id if parent == project.parent
      raise ToolError, 'is this project or one of its subprojects' if parent == project || parent.is_descendant_of?(project)
      raise ToolError, "#{parent.identifier} is not active" unless parent.active?
      raise ToolError, "#{needs(:add_subprojects)} in #{parent.identifier}" unless parent_allowed?(project, parent)

      parent.id
    end

    def version_id(project, value)
      return project.default_version_id if value.to_s == project.default_version_id.to_s

      options = version_options(project)
      found   = options.select { |version| SchemaValidator.integerish?(value) ? version.id == value.to_i : version.name == value.to_s }
      return found.first.id if found.size == 1

      listed = options.first(MAX_OPTIONS).map { |version| "#{version.name} (#{version.id})" }.join(', ')
      raise ToolError, "more than one open version is named #{value.inspect}; pass the id: #{listed}" if found.size > 1

      raise ToolError, "no open version #{value.inspect} of this project or shared with it. Open versions: #{listed.presence || 'none'}"
    end

    def assignee_id(project, value)
      id = user_id_from(value, 'default_assigned_to')
      return id if id == project.default_assigned_to_id || assignee_options(project).any? { |principal| principal.id == id }

      raise ToolError, "user #{id} cannot be assigned issues in this project"
    end

    def query_id(project, value)
      raise InvalidArgument, 'default_issue_query must be a query id, or "none"' unless SchemaValidator.integerish?(value)
      return value.to_i if value.to_i == project.default_issue_query_id || query_options(project).any? { |query| query.id == value.to_i }

      raise ToolError, "query #{value} is not a public query of this project or of all projects"
    end

    # Core keeps only the fields this user may edit here and drops the rest.
    def custom_values(project, raw)
      values  = custom_field_values_from(raw) || {}
      unknown = values.keys - project.editable_custom_field_values(user).map { |value| value.custom_field_id.to_s }
      if unknown.any?
        # By name only where the user sees the field somewhere; elsewhere the
        # name would be more than Redmine shows them.
        names = CustomField.visible(user).where(id: unknown).pluck(:id, :name).to_h
        raise ToolError, "#{unknown.map { |id| names[id.to_i] || "custom field #{id}" }.join(', ')} cannot be set on this project"
      end

      computed = project.editable_custom_field_values(user).map(&:custom_field)
                        .select { |field| values.key?(field.id.to_s) && computed?(field) }
      raise ToolError, "#{computed.map(&:name).join(', ')} is computed by Redmine and would be overwritten" if computed.any?

      values
    end

    # computed_custom_field recomputes these on every save, also on projects,
    # where its form does not mark them read-only.
    def computed?(field)
      field.respond_to?(:is_computed?) && field.is_computed?
    end

    # The names or ids of one add_ or remove_ list, as core stores them.
    def set_items(kind, values, opposite)
      values = Array(values).map(&:to_s)
      both   = values & opposite.map(&:to_s)
      raise ToolError, "#{both.join(', ')} is in both the add and the remove list" if both.any?

      case kind
      when 'enabled_modules'     then known!(values, module_options, 'module')
      when 'trackers'            then known!(values, Tracker.sorted.pluck(:name, :id).to_h, 'tracker')
      when 'issue_custom_fields' then own_issue_fields!(values)
      end
    end

    def known!(values, options, what)
      names   = options.is_a?(Hash) ? options.keys : options
      unknown = values - names
      raise ToolError, "no #{what} named #{unknown.join(', ')}. Known: #{names.join(', ')}" if unknown.any?

      options.is_a?(Hash) ? values.map { |name| options[name].to_s } : values
    end

    # The form shows a field for all projects ticked and disabled.
    def own_issue_fields!(values)
      fields  = IssueCustomField.where(id: values.select { |id| SchemaValidator.integerish?(id) }).index_by { |f| f.id.to_s }
      unknown = values - fields.keys
      raise ToolError, "no issue custom field with id #{unknown.join(', ')}" if unknown.any?

      for_all = fields.values.select(&:is_for_all?)
      raise ToolError, "#{for_all.map(&:name).join(', ')} is for all projects and is not set per project" if for_all.any?

      values
    end

    # --- state ---------------------------------------------------------------

    # reply key => the parameters that change it.
    STATE = {
      'name' => %w[name], 'description' => %w[description], 'homepage' => %w[homepage], 'is_public' => %w[is_public],
      'parent' => %w[parent], 'inherit_members' => %w[inherit_members], 'status' => %w[status],
      'enabled_modules' => %w[add_enabled_modules remove_enabled_modules], 'trackers' => %w[add_trackers remove_trackers],
      'issue_custom_fields' => %w[add_issue_custom_fields remove_issue_custom_fields],
      'default_version' => %w[default_version], 'default_assigned_to' => %w[default_assigned_to],
      'default_issue_query' => %w[default_issue_query]
    }.freeze

    # What this user may see of the project's settings, read from the database.
    # `fields` adds what core changes beside them: memberships and target versions.
    def project_state(id, fields = {})
      project = Project.find(id)
      state = {
        'name' => project.name, 'description' => project.description, 'homepage' => project.homepage,
        'is_public' => project.is_public?, 'parent' => parent_name(project),
        'inherit_members' => project.inherit_members?, 'status' => project.active? ? 'active' : 'closed',
        'enabled_modules' => project.enabled_module_names.sort, 'trackers' => project.trackers.map(&:name),
        'issue_custom_fields' => project.issue_custom_fields.sorted.map(&:name),
        'default_version' => project.default_version&.name, 'default_assigned_to' => project.default_assigned_to&.name,
        'default_issue_query' => project.default_issue_query&.name,
        'custom_fields' => project.visible_custom_field_values(user).to_h { |value| [value.custom_field_id, custom_field_row(value)] }
      }
      state['members'] = project.memberships.count if fields.key?('parent') || fields.key?('inherit_members')
      # A move makes core clear the target version of issues it is no longer shared with.
      state['issues_with_target_version'] = versioned_issues(project) if fields.key?('parent')
      # Closing and reopening take every subproject along.
      state['subprojects'] = project.descendants.pluck(:id, :status).to_h if fields.key?('status')
      state
    end

    def parent_name(project)
      return nil if project.parent.nil?

      project.parent.visible?(user) ? project.parent.identifier : '(not visible)'
    end

    def versioned_issues(project)
      ids = project.self_and_descendants.pluck(:id)
      Issue.joins(:fixed_version).where("#{Version.table_name}.project_id IN (:ids) OR #{Issue.table_name}.project_id IN (:ids)", ids: ids).count
    end

    # => [changes, parameters sent whose value was stored already]
    def project_changes(before, after, fields)
      changes = (before.keys - %w[custom_fields subprojects]).filter_map do |key|
        { field: key, old: before[key], new: after[key] } if before[key] != after[key]
      end
      before['custom_fields'].each do |id, row|
        now = after['custom_fields'][id]
        changes << { field: 'custom_field_values', id: id, name: row[:name], old: row[:value], new: now && now[:value] } if now != row
      end
      touched   = changes.map { |change| change[:field] }
      unchanged = fields.keys.select { |name| name != 'custom_field_values' && !touched.intersect?(STATE.select { |_k, v| v.include?(name) }.keys) }
      unchanged += Array(fields['custom_field_values']&.keys).reject { |id| changes.any? { |c| c[:id].to_s == id.to_s } }
                                                             .map { |id| "custom_field_values[#{id}]" }
      [changes, unchanged]
    end
  end
end
