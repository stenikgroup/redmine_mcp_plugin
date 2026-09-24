# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetIssueFields < Tool
      tool 'get_issue_fields',
           title: 'Get settable issue fields',
           description: 'Report what the authenticated user may set on an issue: its custom fields ' \
                        'with their allowed values, which attributes are required or read-only, the ' \
                        'statuses the issue may move to, and the users it may be assigned to. Call ' \
                        'this before create_issue or update_issue. Pass issue for an existing issue, ' \
                        'or project (and optionally tracker) for one not yet created. When a required ' \
                        'value is not clear from the conversation, ask the user for it; never invent one.',
           permission: :view_issues,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Id of an existing issue.' },
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id, for an issue not yet created.' },
               'tracker' => { 'type' => 'string',
                              'description' => 'Tracker name. Defaults to the first tracker the user may create in.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = build_issue(arguments)

        {
          issue_id: issue.id,
          project_identifier: issue.project&.identifier,
          tracker: issue.tracker&.name,
          # These two mix core attribute names with custom field ids
          # (issue.rb:668-682); the ids are reported on each custom field.
          required_attributes: core_attributes(issue.required_attribute_names(user)),
          read_only_attributes: core_attributes(issue.read_only_attribute_names(user)),
          custom_fields: custom_fields_for(issue),
          allowed_statuses: issue.new_statuses_allowed_to(user).map do |status|
            { id: status.id, name: status.name, is_closed: status.is_closed? }
          end,
          allowed_trackers: issue.allowed_target_trackers(user).map { |t| { id: t.id, name: t.name } },
          assignable_users: issue.assignable_users.map { |u| { id: u.id, login: u.login, name: u.name } }
        }
      end

      def build_issue(arguments)
        if arguments['issue'].present?
          existing_issue(arguments['issue'])
        elsif arguments['project'].present?
          new_issue(arguments)
        else
          raise ToolError, 'Pass issue for an existing issue, or project for one not yet created'
        end
      end

      def existing_issue(id)
        issue = Issue.visible(user).find_by(id: id.to_i)
        raise ToolError, "No visible issue with id #{id.inspect}" if issue.nil?

        authorize!(:view_issues, issue.project)
        issue
      end

      def new_issue(arguments)
        project = fetch_project(arguments['project'])
        authorize!(:add_issues, project)

        issue = Issue.new(project: project, author: user)
        # available_custom_fields needs a project and a tracker (issue.rb:286),
        # so the issue is built the way core's new-issue form builds it.
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
        required = issue.required_attribute_names(user)
        issue.editable_custom_field_values(user).map do |value|
          field = value.custom_field
          {
            id: field.id,
            name: field.name,
            format: field.field_format,
            # is_required is the field definition; a workflow rule can require
            # it for this user on this tracker alone.
            required: field.is_required? || required.include?(field.id.to_s),
            multiple: field.multiple?,
            default_value: field.default_value,
            possible_values: possible_values_for(field, issue)
          }
        end
      end

      # possible_values_options gives plain strings for a list field and
      # [label, value] pairs for the formats stored as ids -- user, version,
      # enumeration -- and for bool, whose values are '1' and '0'.
      def possible_values_for(field, issue)
        field.possible_values_options(issue).map do |option|
          label, value = option.is_a?(Array) ? option : [option, option]
          { value: value.to_s, label: label.to_s }
        end
      end
    end
  end
end
