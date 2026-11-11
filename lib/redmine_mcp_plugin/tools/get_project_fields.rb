# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # The lookup before update_projects, as get_issue_fields is for issues: the
    # same guards and the same option lists the write checks against.
    class GetProjectFields < Tool
      include ProjectFields

      tool 'get_project_fields',
           title: 'Get project fields',
           description: 'Report what the authenticated user may set on a project: the settable fields, its ' \
                        'custom fields with their allowed values, the modules, trackers, issue custom fields, ' \
                        'parents, default versions, assignees and queries it may use, and whether it may ' \
                        'close or reopen it. Call this before update_projects.',
           permission: %i[edit_project close_project],
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id.' }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      class << self
        # Of use only beside update_projects, and its permissions would
        # otherwise stay advertised as scopes in read-only mode.
        def installed? = super && !Settings.read_only?
      end

      private

      def perform(arguments)
        project  = fetch_project(arguments['project'])
        blocked  = FIELDS.keys.to_h { |name| [name, field_block(project, name)] }.compact
        settable = FIELDS.keys - blocked.keys
        reply = {
          project_identifier: project.identifier,
          status: project.active? ? 'active' : 'closed',
          settable_fields: settable,
          blocked_fields: blocked.map { |name, reason| { field: name, reason: reason } },
          identifier: 'fixed',
          can_close: settable.include?('status') && project.active?,
          can_reopen: settable.include?('status') && !project.active?
        }
        # Only the lists of what can be set: the rest would be options of nothing.
        reply[:custom_fields]   = custom_fields_for(project) if settable.include?('custom_field_values')
        reply[:enabled_modules] = module_options.map { |name| { name: name, enabled: project.module_enabled?(name) } } if settable.include?('add_enabled_modules')
        reply.merge!(parents_for(project)) if settable.include?('parent')
        reply.merge!(issue_tracking_for(project)) if settable.include?('add_trackers')
        reply
      end

      def custom_fields_for(project)
        project.editable_custom_field_values(user).map do |value|
          field = value.custom_field
          row = { id: field.id, name: field.name, format: field.field_format, required: field.is_required?,
                  multiple: field.multiple?, rendered: field.full_text_formatting?, value: custom_field_row(value)[:value] }
          next row.merge(settable: false, reason: 'computed by Redmine') if computed?(field)

          row.merge(capped(:possible_values, field.possible_values_options(project)) { |option| labelled_option(option) })
        end
      end

      # Core gives plain strings for a list field, and [label, value] pairs for
      # the formats stored as ids and for bool.
      def labelled_option(option)
        label, value = option.is_a?(Array) ? option : [option, option]
        { value: value.to_s, label: label.to_s }
      end

      # allowed_parents asks the roles only; the token has to allow each as well.
      def parents_for(project)
        allowed = project.allowed_parents(user)
        parents = allowed.compact.lazy.select { |parent| parent == project.parent || user.allowed_to?(:add_subprojects, parent) }
        capped(:allowed_parents, parents) { |parent| { identifier: parent.identifier, name: parent.name } }
          .merge(top_level_allowed: project.parent_id.nil? || allowed.include?(nil))
      end

      def issue_tracking_for(project)
        own = project.issue_custom_field_ids
        {
          trackers: Tracker.sorted.map { |tracker| { id: tracker.id, name: tracker.name, enabled: project.tracker_ids.include?(tracker.id) } },
          issue_custom_fields: IssueCustomField.sorted.map do |field|
            { id: field.id, name: field.name, enabled: field.is_for_all? || own.include?(field.id), for_all: field.is_for_all? }
          end,
          default_versions: version_options(project).map { |version| { id: version.id, name: version.name } },
          default_issue_queries: query_options(project).map { |query| { id: query.id, name: query.name } }
        }.merge(capped(:default_assignees, assignee_options(project)) { |principal| { id: principal.id, name: principal.name } })
      end

      # A long list is cut and says so; list_users and list_projects page the whole.
      def capped(key, items)
        first = items.first(MAX_OPTIONS + 1)
        list  = { key => first.first(MAX_OPTIONS).map { |item| yield item } }
        first.size > MAX_OPTIONS ? list.merge("#{key}_truncated": true) : list
      end
    end
  end
end
