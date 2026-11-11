# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # The structure of a project: the project itself, its versions, its
    # categories and its members.
    module ProjectStructure
      include CustomFields

      # parameter => core attribute, for the values that need no resolver.
      PROJECT_ATTRIBUTES = { 'name' => 'name', 'identifier' => 'identifier', 'description' => 'description',
                             'homepage' => 'homepage', 'is_public' => 'is_public',
                             'inherit_members' => 'inherit_members' }.freeze

      # Core gates these three on a permission and drops them silently without it.
      PROJECT_GATED = { 'is_public' => :select_project_publicity, 'enabled_module_names' => :select_project_modules,
                        'inherit_members' => :manage_members }.freeze

      PROJECT_PARAMETERS = PROJECT_ATTRIBUTES.invert.merge('parent_id' => 'parent', 'enabled_module_names' => 'enabled_modules',
                                                           'tracker_ids' => 'trackers',
                                                           'custom_field_values' => 'custom_field_values').freeze

      private

      # The attributes to assign to a project. Every check runs and each refusal
      # is charged to its parameter, as for an issue.
      def project_attributes_from(project, arguments, problems)
        attributes = PROJECT_ATTRIBUTES.each_with_object({}) do |(name, attribute), out|
          out[attribute] = arguments[name] unless arguments[name].nil?
        end
        resolvers = { 'parent_id'            => ['parent', ->(value) { project_parent_id(project, value) }],
                      'enabled_module_names' => ['enabled_modules', ->(value) { project_module_names(value) }],
                      'tracker_ids'          => ['trackers', ->(value) { project_tracker_ids(value) }],
                      'custom_field_values'  => ['custom_field_values', ->(value) { custom_field_values_for(project, value) }] }
        resolvers.each do |attribute, (name, resolve)|
          next if arguments[name].nil? || arguments[name] == {}

          value = blocked(problems, name) { resolve.call(arguments[name]) }
          attributes[attribute] = value unless value.nil?
        end
        # A copy of the keys: the loop deletes from the hash it walks.
        attributes.keys.each do |attribute| # rubocop:disable Style/HashEachMethods
          next if project.safe_attribute?(attribute, user)

          problems << project_blocked_name(attribute)
          attributes.delete(attribute)
        end
        attributes
      end

      def project_blocked_name(attribute)
        name = PROJECT_PARAMETERS.fetch(attribute, attribute)
        gate = PROJECT_GATED[attribute]
        gate ? "#{name} (needs #{permission_labels(gate)})" : name
      end

      # Core's own rule: a subproject needs add_subprojects on the parent, a root
      # project add_project, and core answers either refusal "Parent is invalid".
      def project_parent_id(project, value)
        parent = value.to_s == 'none' ? nil : fetch_project(value)
        return parent&.id.to_s if !project.new_record? && parent&.id == project.parent_id

        unless project.allowed_parents(user).include?(parent)
          cause = parent ? "#{permission_labels(:add_subprojects)} on #{parent.identifier}" : permission_labels(:add_project)
          raise ToolError, "needs #{cause}"
        end
        raise ToolError, "#{parent.identifier} is closed" if parent && !parent.active?

        parent&.id.to_s
      end

      def project_module_names(values)
        known   = Redmine::AccessControl.available_project_modules.map(&:to_s)
        names   = Array(values).map(&:to_s)
        unknown = names - known
        raise ToolError, "no module #{unknown.join(', ')}; modules: #{known.sort.join(', ')}" if unknown.any?

        names
      end

      def project_tracker_ids(values)
        trackers = Tracker.sorted.to_a
        Array(values).map do |value|
          tracker = trackers.detect { |t| t.name == value.to_s || t.id.to_s == value.to_s }
          raise ToolError, "no tracker #{value.inspect}; trackers: #{trackers.map(&:name).join(', ')}" if tracker.nil?

          tracker.id
        end
      end

      def project_state(project)
        {
          id: project.id,
          identifier: project.identifier,
          name: project.name,
          description: project.description,
          homepage: project.homepage,
          status: project.status,
          is_public: project.is_public?,
          parent_id: project.parent_id,
          inherit_members: project.inherit_members?,
          created_on: iso(project.created_on),
          updated_on: iso(project.updated_on),
          enabled_modules: project.enabled_module_names.sort,
          trackers: project.trackers.map { |t| { id: t.id, name: t.name } },
          # Categories and versions are cheap and are what a model needs before
          # it can create or filter an issue sensibly.
          issue_categories: project.issue_categories.map { |c| { id: c.id, name: c.name } },
          versions: project.shared_versions.map { |v| { id: v.id, name: v.name, status: v.status } },
          # Core's own rule, which honours the roles a field is restricted to.
          custom_fields: shown_custom_fields(project.visible_custom_field_values(user))
        }
      end

      def saved_project_state(project)
        project_state(Project.find(project.id)).merge(url: absolute_url(:project_url, project))
      end

      # The same message whether it does not exist or its project may not be
      # seen. The caller adds authorize! for its permission.
      def fetch_version(id)
        version = Version.find_by(id: id.to_i)
        raise ToolError, "No visible version with id #{id.inspect}" if version.nil? || !version.project.visible?(user)

        version
      end

      # Core drops a sharing the caller may not set and saves the rest.
      def version_attributes_from(version, arguments, problems)
        attributes = %w[name description wiki_page_title status].each_with_object({}) do |name, out|
          out[name] = arguments[name].to_s unless arguments[name].nil?
        end
        attributes['default_project_version'] = arguments['default_project_version'] unless arguments['default_project_version'].nil?
        unless arguments['due_date'].nil?
          attributes['effective_date'] = arguments['due_date'] == 'none' ? '' : iso_date(arguments['due_date'], 'due_date')
        end
        unless arguments['sharing'].nil?
          value = blocked(problems, 'sharing') { version_sharing(version, arguments['sharing']) }
          attributes['sharing'] = value unless value.nil?
        end
        if arguments['custom_field_values'].present?
          value = blocked(problems, 'custom_field_values') { custom_field_values_for(version, arguments['custom_field_values']) }
          attributes['custom_field_values'] = value unless value.nil?
        end
        attributes
      end

      def version_sharing(version, value)
        allowed = version.allowed_sharings(user)
        return value if allowed.include?(value)

        raise ToolError, "#{value.inspect} is not allowed to you here; allowed: #{allowed.join(', ')}"
      end

      def version_state(version)
        version = Version.find(version.id)
        return written_unread(version, :version_url) unless readable_in?(version.project, :view_issues)

        {
          id: version.id,
          name: version.name,
          project_identifier: version.project.identifier,
          description: version.description,
          status: version.status,
          due_date: version.effective_date&.iso8601,
          sharing: version.sharing,
          wiki_page_title: version.wiki_page_title,
          default_project_version: version.default_project_version,
          custom_fields: shown_custom_fields(version.visible_custom_field_values(user)),
          created_on: iso(version.created_on),
          updated_on: iso(version.updated_on),
          url: absolute_url(:version_url, version)
        }
      end

      def fetch_issue_category(id)
        category = IssueCategory.find_by(id: id.to_i)
        raise ToolError, "No visible category with id #{id.inspect}" if category.nil? || !category.project.visible?(user)

        category
      end

      # The assignee an issue of this category gets. Core's API takes any id; only
      # one that names nobody is refused here, where core would store it.
      def category_attributes_from(category, arguments)
        attributes = {}
        attributes['name'] = arguments['name'].to_s unless arguments['name'].nil?
        unless arguments['assigned_to'].nil?
          attributes['assigned_to_id'] = arguments['assigned_to'] == 'none' ? '' : category_assignee_id(category, arguments['assigned_to'])
        end
        attributes
      end

      def category_assignee_id(_category, value)
        id = user_id_from(value, 'assigned_to')
        return id if Principal.where(type: %w[User Group]).exists?(id: id)

        raise ToolError, "No user or group with id #{id}"
      end

      def category_state(category)
        category = IssueCategory.find(category.id)
        return written_unread(category) unless readable_in?(category.project, :view_issues)

        { id: category.id, name: category.name, project_identifier: category.project.identifier,
          assigned_to: category.assigned_to && principal_row(category.assigned_to) }
      end

      def membership_row(member)
        roles = member.member_roles.select(&:role).map do |member_role|
          { id: member_role.role.id, name: member_role.role.name, inherited: member_role.inherited_from.present? }
        end
        { id: member.id, principal: principal_row(member.principal), roles: roles }
      end

      def role_row(role)
        { id: role.id, name: role.name }
      end
    end
  end
end
