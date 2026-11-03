# frozen_string_literal: true

module RedmineMcpPlugin
  # Base class for every exposed tool.
  #
  # The permission model here is belt and braces, and the second belt is not
  # redundant:
  #
  #   1. `permission` is checked through User#allowed_to?, which intersects the
  #      user's role permissions with the OAuth token's scopes.
  #   2. Each tool additionally reads through core's .visible scopes.
  #
  # Both are required. Core's SQL visibility scopes go through
  # Project.allowed_to_condition, which calls role.allowed_to?(permission) with
  # NO scope argument -- so .visible honours roles but is blind to OAuth scopes.
  # Relying on .visible alone would let a token scoped to view_wiki_pages read
  # issues. Relying on allowed_to? alone would return rows from projects the
  # user is not a member of. Neither check subsumes the other.
  class Tool
    class << self
      attr_reader :mcp_name, :mcp_title, :mcp_description, :mcp_schema,
                  :mcp_permission, :mcp_write, :mcp_destructive

      # `scopes` are permissions the tool checks beyond the one that gates it;
      # they are advertised so a token can carry them, and gate nothing.
      # `rendered` names the parameters Redmine passes through its text formatter,
      # `plain` the ones it prints as they are; both get the dash rule when listed.
      # `checks_blank` names required text the tool refuses blank itself, with its reason.
      # `plugin` ties the whole tool to an installed plugin, `plugin_properties`
      # and `plugin_scopes` tie single parameters and scopes to one.
      def tool(name, title:, description:, schema:, permission: nil, scopes: [], rendered: [], plain: [],
               checks_blank: [], write: false, destructive: false, plugin: nil, plugin_properties: {},
               plugin_scopes: {})
        @mcp_name          = name.to_s
        @mcp_title         = title
        @mcp_description   = description
        @mcp_schema        = schema
        @mcp_permission    = permission
        @mcp_scopes        = scopes
        @mcp_rendered      = rendered
        @mcp_plain         = plain
        @mcp_checks_blank  = checks_blank
        @mcp_write         = write
        @mcp_destructive   = destructive
        @mcp_plugin        = plugin
        @plugin_properties = plugin_properties
        @plugin_scopes     = plugin_scopes
      end

      def write?       = !!@mcp_write
      def destructive? = !!@mcp_destructive
      def mcp_rendered = Array(@mcp_rendered)
      def mcp_plain    = Array(@mcp_plain)
      def mcp_checks_blank = Array(@mcp_checks_blank)

      # Read per call, never at class load: this plugin boots before some of
      # the plugins it looks for.
      def plugin?(id) = Redmine::Plugin.installed?(id)

      def installed? = @mcp_plugin.nil? || plugin?(@mcp_plugin)

      def mcp_scopes
        Array(@mcp_scopes) + @plugin_scopes.to_h.select { |id, _scopes| plugin?(id) }.values.flatten
      end

      # Core grants some abilities through more than one permission, so any of
      # them admits the tool; the tool applies core's real rule per record.
      def mcp_permissions = Array(@mcp_permission)

      # Whether this tool should appear in tools/list for the current user.
      # tools/list is allowed to vary by the authorization presented on the
      # request -- the 2026-07-28 spec says so explicitly -- and hiding a tool
      # the caller could never successfully call is friendlier than letting a
      # model discover it and fail.
      def available_to?(user)
        return false unless installed?
        return false if write? && Settings.read_only?
        return true  if mcp_permissions.empty?

        mcp_permissions.any? { |permission| user.allowed_to?(permission, nil, global: true) }
      end

      def descriptor
        {
          name: mcp_name,
          title: mcp_title,
          description: mcp_description,
          inputSchema: schema_with_format,
          # Clients read these to decide whether a call needs confirming by the
          # user. Omitting them makes a read-only server look exactly like a
          # destructive one, so every lookup gets a prompt.
          annotations: {
            readOnlyHint: !write?,
            destructiveHint: destructive?,
            idempotentHint: !write?
          }
        }
      end

      # The schema minus the parameters of plugins that are not installed. The
      # served list and validation both use it, so an absent plugin leaves nothing.
      def effective_schema
        absent = @plugin_properties.to_h.reject { |id, _names| plugin?(id) }.values.flatten
        return mcp_schema if absent.empty?

        mcp_schema.merge('properties' => mcp_schema['properties'].except(*absent))
      end

      # The format is a setting, so the suffix is added when the list is served,
      # not when the class loads. Validation keeps using the bare schema.
      def schema_with_format
        schema = effective_schema
        return schema if mcp_rendered.empty? && mcp_plain.empty?

        properties = schema['properties'].to_h do |name, spec|
          suffix = Formatting.rendered_suffix if mcp_rendered.include?(name)
          suffix = Formatting.plain_suffix    if mcp_plain.include?(name)
          next [name, spec] unless suffix

          [name, spec.merge('description' => "#{spec['description']} #{suffix}".strip)]
        end
        schema.merge('properties' => properties)
      end
    end

    # `auth` carries what core does not expose. Redmine declares
    # `attr_writer :oauth_scope` on User with no matching reader, so the granted
    # scopes cannot be read back off the model once set -- the plugin has to
    # remember them itself.
    def initialize(user, auth = {})
      @user = user
      @auth = auth || {}
    end

    attr_reader :user, :auth

    def auth_mode   = @auth[:mode]
    def oauth?      = @auth[:mode] == :oauth2
    def oauth_scopes = @auth[:scopes]

    # Invoked by the dispatcher. Subclasses implement #perform.
    def call(arguments)
      klass = self.class
      raise PermissionError, 'This tool is disabled: the server is in read-only mode' if klass.write? && Settings.read_only?

      permissions = klass.mcp_permissions
      if permissions.any? && permissions.none? { |p| user.allowed_to?(p, nil, global: true) }
        raise PermissionError, 'You do not have permission to use this tool'
      end

      arguments ||= {}
      # The schemas are a contract with the caller, not a comment. Checked here
      # rather than in each tool so a tool cannot forget.
      schema = klass.effective_schema
      # Blank text the tool checks itself was sent, so the tool can say why it refuses it.
      sent = klass.mcp_checks_blank.select { |key| arguments[key].is_a?(String) }
      SchemaValidator.validate!(schema.merge('required' => Array(schema['required']) - sent), arguments)
      # And normalised, so a tool never has to decide what the string "false"
      # means. It means false.
      arguments = SchemaValidator.coerce(schema, arguments)

      perform(arguments)
    end

    private

    def perform(_arguments)
      raise NotImplementedError
    end

    def plugin?(id) = self.class.plugin?(id)

    # --- helpers available to every tool ----------------------------------

    # Confirms the user may do `permission` in `project`, honouring OAuth
    # scopes. Use this for anything scoped to one project; the .visible scopes
    # alone will not catch a scope-narrowed token.
    # ToolError, not PermissionError: this one is scoped to a single project, so
    # the caller can act on it by asking about a different project. Tool-level
    # refusals in #call stay protocol errors. The wording is unchanged and stays
    # uniform -- a message that varies by cause is an information leak.
    def authorize!(permission, project)
      raise ToolError, 'You do not have permission to do that' unless user.allowed_to?(permission, project)
    end

    # add_issue_notes is granted per tracker: authorize! covers the project and
    # the scope, notes_addable? the tracker, and init_journal skips core's own check.
    def authorize_note!(issue)
      authorize!(:add_issue_notes, issue.project)
      raise ToolError, 'You do not have permission to do that' unless issue.notes_addable?(user)
    end

    # Core allows edit_issues, or edit_own_issues on one's own issue, per
    # tracker. attributes_editable? misses OAuth scopes; allowed_to? misses trackers.
    def authorize_edit!(issue)
      scoped = user.allowed_to?(:edit_issues, issue.project) ||
               (issue.author_id == user.id && user.allowed_to?(:edit_own_issues, issue.project))
      raise ToolError, 'You do not have permission to do that' unless scoped && issue.attributes_editable?(user)
    end

    # SchemaValidator has already refused a non-integer or below-minimum limit,
    # so all that is left is the server-side cap. max_results is the
    # administrator's ceiling, not a suggestion the caller may raise.
    def limit_for(arguments)
      requested = arguments['limit'].presence&.to_i
      return Settings.max_results if requested.nil?

      # Clamped to 1, not just capped. SchemaValidator rejects a limit below
      # the declared minimum, but only for a tool that declares one. A new list
      # tool that omits it would otherwise pass a negative straight to
      # ActiveRecord, which raises. max_results stays the administrator's
      # ceiling.
      [[requested, 1].max, Settings.max_results].min
    end

    def offset_for(arguments)
      # Clamped for the same reason as limit_for.
      [arguments['offset'].presence&.to_i || 0, 0].max
    end

    # One envelope for every list tool, so a caller pages all of them the same
    # way. Without an offset the cap on limit made everything past the first
    # max_results rows unreachable: on the instance this was tested against,
    # 585 of 685 projects and all but 100 issues.
    def paged(total:, offset:, key:, rows:)
      {
        total_count: total,
        returned: rows.size,
        offset: offset,
        has_more: offset + rows.size < total,
        key => rows
      }
    end

    def fetch_project(identifier)
      raise ToolError, 'project is required' if identifier.blank?

      project = Project.visible(user).find_by(identifier: identifier.to_s) ||
                Project.visible(user).find_by(id: identifier.to_s.to_i)
      # Deliberately the same message whether the project does not exist or is
      # merely invisible: distinguishing them confirms the existence of projects
      # the caller cannot see.
      raise ToolError, "No visible project matching #{identifier.inspect}" if project.nil?

      project
    end

    # Visibility only, like fetch_project; the caller adds authorize! for its permission.
    def fetch_issue(id)
      issue = Issue.visible(user).find_by(id: id.to_i)
      raise ToolError, "No visible issue with id #{id.inspect}" if issue.nil?

      issue
    end

    def fetch_news(id)
      news = News.visible(user).find_by(id: id.to_i)
      raise ToolError, "No visible news with id #{id.inspect}" if news.nil?

      news
    end

    # allowed_to? is false for a disabled module, which would read as a
    # permissions problem; name the real cause instead.
    def require_module!(project, name)
      return if project.module_enabled?(name)

      raise ToolError, "The #{name} module is not enabled for project #{project.identifier}"
    end

    # Both wiki tools need these three checks, in this order.
    #
    # The module check comes first because allowed_to? returns false for a
    # disabled module, so a project whose wiki is merely switched off otherwise
    # reports "You do not have permission" -- which sent one reviewer looking
    # for a permissions bug that was not there. Naming the real cause leaks
    # nothing: get_project already returns enabled_modules to anyone who can
    # see the project.
    def fetch_wiki(project)
      require_module!(project, :wiki)
      authorize!(:view_wiki_pages, project)

      wiki = project.wiki
      raise ToolError, "Project #{project.identifier} has no wiki" if wiki.nil? || !wiki.visible?(user)

      wiki
    end

    # People are named by id or "me" everywhere. Query filters pass "me" on to
    # core, which also adds the user's groups; writes resolve it here.
    def user_ref!(value, name)
      return value if value == 'me' || SchemaValidator.integerish?(value)

      raise InvalidArgument, "#{name} must be a user id from list_users, or \"me\""
    end

    def user_id_from(value, name)
      user_ref!(value, name) == 'me' ? user.id : value.to_i
    end

    def iso(time)
      time&.iso8601
    end

    def iso_date(value, name)
      Date.iso8601(value.to_s).iso8601
    rescue ArgumentError
      raise InvalidArgument, "#{name} must be an ISO-8601 date, got #{value.inspect}"
    end

    # Built the way Redmine builds links in its notification emails, not from
    # the request. nil when unset: a missing setting must not fail a done write.
    def absolute_url(helper, *args, **options)
      return nil if Setting.host_name.blank?

      Rails.application.routes.url_helpers.public_send(helper, *args, **options, **Mailer.default_url_options)
    end

    # --- issue writes -------------------------------------------------------

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
    TAG_KEYS     = %w[tag_list add_tag_list remove_tag_list].freeze
    WATCHER_KEYS = %w[add_watcher_users remove_watcher_users].freeze

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

    # Charges a refusal to its parameter and carries on. A shape error is the
    # schema's kind and refuses at once.
    def blocked(problems, name)
      yield
    rescue InvalidArgument
      raise
    rescue ToolError => e
      problems << "#{name} (#{e.message})"
      nil
    end

    def refuse_blocked!(record, problems)
      return if problems.empty?

      raise ToolError, "Cannot set #{problems.join(', ')} on this #{record.class.model_name.human.downcase}"
    end

    # Core drops what the role, tracker or workflow forbids and saves the rest;
    # name it and stop instead.
    def refuse_unsettable!(record, attributes)
      unsafe = attributes.keys.reject { |key| record.safe_attribute?(key, user) }
      refuse_blocked!(record, unsafe.map { |key| PARAMETER_NAMES.fetch(key, key) })
    end

    def blocked_name(issue, key)
      name  = PARAMETER_NAMES.fetch(key, key)
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
      return "needs #{permission_labels(needs)}" if needs && needs.none? { |p| user.allowed_to?(p, issue.project) }
      return "disabled on tracker #{issue.tracker&.name}" if issue.disabled_core_fields.include?(key)
      return 'read-only by workflow' if issue.read_only_attribute_names(user).include?(key)

      nil
    end

    # The label the role form shows, in the caller's language. Core sets the
    # request locale before this plugin authenticates, so I18n.locale is not
    # the caller's; their own language is, with core's fallback to the default.
    def permission_labels(permissions)
      Array(permissions).map { |p| I18n.t("permission_#{p}", locale: caller_locale, default: p.to_s.tr('_', ' ').capitalize) }
                        .join(', or ')
    end

    def caller_locale
      language = user.language.presence || Setting.default_language
      I18n.locale_available?(language) ? language : I18n.default_locale
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

    DONE_RATIO_COMPUTED = { 'status'    => 'computed from the status on this Redmine',
                            'checklist' => 'computed from the checklist by redmine_checklists' }.freeze

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

    def checklist_done_ratio?(issue, adding: false)
      plugin?(:redmine_checklists) && RedmineChecklists.issue_done_ratio? &&
        (adding || issue.checklists.reject(&:is_section).any?)
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

    # --- custom fields ------------------------------------------------------

    # Choices named in a refusal, capped so a user field on a big instance stays readable.
    MAX_CHOICES = 25

    # The custom fields this user may set on `record`, each with its allowed
    # values, in one shape for issues and time entries. `required_ids` adds the
    # fields a workflow rule requires here beyond the definition flag.
    def custom_field_rows(record, required_ids = [])
      record.editable_custom_field_values(user).map do |value|
        field = value.custom_field
        {
          id: field.id,
          name: field.name,
          format: field.field_format,
          required: custom_field_required?(field, required_ids),
          multiple: field.multiple?,
          # True for a long text field with text formatting on: its value takes markup.
          rendered: field.full_text_formatting?,
          default_value: field.default_value,
          possible_values: possible_values_for(field, record)
        }
      end
    end

    def custom_field_required?(field, required_ids)
      field.is_required? || required_ids.include?(field.id.to_s)
    end

    # Core gives plain strings for a list field, and [label, value] pairs for
    # the formats stored as ids and for bool. Empty for a free-form format.
    def possible_values_for(field, record)
      field.possible_values_options(record).map do |option|
        label, value = option.is_a?(Array) ? option : [option, option]
        { value: value.to_s, label: label.to_s }
      end
    end

    # Same reason as the attributes: core keeps only the custom fields this user may edit here.
    def unknown_custom_fields(record, ids)
      editable = record.editable_custom_field_values(user).map { |value| value.custom_field_id.to_s }
      unknown  = Array(ids).map(&:to_s) - editable
      return nil if unknown.empty?

      names = CustomField.where(id: unknown).pluck(:id, :name).to_h
      unknown.map { |id| names[id.to_i] || "id #{id}" }.join(', ')
    end

    # The values to assign, by field id: refused by name when the field cannot
    # be set here, and checked against the field's allowed values before the
    # save, so a wrong one is refused with the choices instead of core's "is
    # not included in the list". A label is accepted when it names one value.
    def custom_field_values_for(record, raw)
      values = custom_field_values_from(raw)
      return nil if values.nil?

      list = unknown_custom_fields(record, values.keys)
      raise ToolError, "#{list} cannot be set here" if list

      values.to_h do |id, value|
        field   = record.custom_field_values.detect { |v| v.custom_field_id.to_s == id }.custom_field
        options = possible_values_for(field, record)
        next [id, value] if options.empty?

        # Core still accepts the value already stored, though no longer offered.
        kept     = Array(record.custom_field_value(field)).map(&:to_s)
        resolved = Array(value).map { |one| kept.include?(one) ? one : resolve_custom_value(field, options, one) }
        [id, value.is_a?(Array) ? resolved : resolved.first]
      end
    end

    def resolve_custom_value(field, options, value)
      value = value.to_s
      return value if value.blank?

      value = user.id.to_s if field.field_format == 'user' && value == 'me'
      value = { 'true' => '1', 'false' => '0' }.fetch(value.downcase, value) if field.field_format == 'bool'
      return value if options.any? { |option| option[:value] == value }

      matches = options.select { |option| option[:label].casecmp?(value) }.map { |option| option[:value] }.uniq
      return matches.first if matches.size == 1
      if matches.size > 1
        raise ToolError, "#{custom_field_label(field)}: #{value.inspect} names several values, pass one: #{matches.join(', ')}"
      end

      raise ToolError, "#{custom_field_label(field)} has no value #{value.inspect}; accepts #{choices_text(options)}"
    end

    # The required custom fields a save would refuse blank, named with their
    # choices before core's bare "cannot be blank". Runs once the attributes
    # are assigned and before the save, since core reads the workflow rules of
    # the status being set, not the stored one. Core checks a field a workflow
    # requires at every save; a field required by its own flag on a new record,
    # and on a stored one once a custom field changes, which a tracker move
    # counts as. An update that changes none of that is left to core, as core
    # leaves it alone too.
    def require_custom_fields!(record, required_ids = [])
      changed = record.new_record? || record.custom_field_values_changed?
      missing = record.editable_custom_field_values(user).select do |current|
        field = current.custom_field
        next false unless Array(current.value).all?(&:blank?)

        required_ids.include?(field.id.to_s) || (changed && field.is_required?)
      end
      return if missing.empty?

      raise ToolError, missing.map { |current| required_text(current.custom_field, record) }.join('; ')
    end

    # Charged to custom_field_values, as the refusals before the assignment are.
    def require_issue_custom_fields!(issue)
      problems = []
      blocked(problems, 'custom_field_values') { require_custom_fields!(issue, issue.required_attribute_names(user)) }
      refuse_blocked!(issue, problems)
    end

    def required_text(field, record)
      options = possible_values_for(field, record)
      text    = "#{custom_field_label(field)} is required"
      options.empty? ? text : "#{text}; accepts #{choices_text(options)}"
    end

    def custom_field_label(field)
      "custom field #{field.name} (id #{field.id})"
    end

    # A list field repeats its value as the label; the other formats show both.
    def choices_text(options)
      shown = options.first(MAX_CHOICES).map do |option|
        option[:value] == option[:label] ? option[:value].inspect : "#{option[:value]} (#{option[:label]})"
      end
      text = shown.join(', ')
      options.size > MAX_CHOICES ? "#{text}, and #{options.size - MAX_CHOICES} more" : text
    end

    # --- watchers -----------------------------------------------------------

    # The principals who may be added as watchers: the project's principals who
    # may watch, minus current watchers and anyone who cannot see the issue.
    # Core dropped Issue#addable_watcher_users as unused (r23758, #43429); this
    # is the list WatchersController#watcher_candidate_scope builds, on every
    # supported Redmine.
    def addable_watcher_users(issue)
      candidates = issue.project.principals.assignable_watchers.sorted.to_a - issue.watcher_users.to_a
      candidates.select { |principal| issue.valid_watcher?(principal) }
    end

    def watcher_ids(issue, values, name)
      Array(values).map do |value|
        id = user_id_from(value, name)
        next id if addable_watcher_users(issue).any? { |principal| principal.id == id }

        raise ToolError, "User #{id} cannot be added as a watcher of this issue"
      end
    end

    # Oneself follows core's Watch link, which needs no permission; anyone else
    # needs add_issue_watchers or delete_issue_watchers, as core's own actions do.
    def watcher_changes(issue, arguments, problems)
      adds = watcher_principals(issue, arguments, 'add_watcher_users', :add_issue_watchers, problems) do |id|
        next user if id == user.id

        addable_watcher_users(issue).detect { |p| p.id == id } ||
          raise(ToolError, "User #{id} cannot be added as a watcher of ##{issue.id}")
      end
      removes = watcher_principals(issue, arguments, 'remove_watcher_users', :delete_issue_watchers, problems) do |id|
        issue.watcher_users.detect { |p| p.id == id } || raise(ToolError, "User #{id} is not a watcher of ##{issue.id}")
      end
      [adds, removes]
    end

    def watcher_principals(issue, arguments, name, permission, problems)
      ids = Array(arguments[name]).map { |v| user_id_from(v, name) }.uniq
      return [] if ids.empty?

      if ids.any? { |id| id != user.id } && !user.allowed_to?(permission, issue.project)
        problems << "#{name} (needs #{permission_labels(permission)})"
        return []
      end
      blocked(problems, name) { ids.map { |id| yield(id) } } || []
    end

    def apply_watcher_changes!(issue, adds, removes)
      adds.each    { |principal| issue.add_watcher(principal) unless issue.watched_by?(principal) }
      removes.each { |principal| issue.remove_watcher(principal) }
    end

    def principal_row(principal)
      { id: principal.id, name: principal.name, type: principal.class.name }
    end

    # --- attachments --------------------------------------------------------

    def attachment_row(attachment)
      {
        id: attachment.id,
        filename: attachment.filename,
        filesize: attachment.filesize,
        content_type: attachment.content_type,
        author: attachment.author&.name,
        description: attachment.description,
        created_on: iso(attachment.created_on),
        url: absolute_url(:download_named_attachment_url, attachment, attachment.filename)
      }
    end

    # --- relations ----------------------------------------------------------

    # As the issue page lists them: only those whose other issue the user may see.
    def visible_relations(issue)
      issue.relations.select { |relation| relation.other_issue(issue)&.visible?(user) }
    end

    # Seen from this issue. Redmine stores follows as precedes, and keeps a delay on nothing else.
    def relation_rows(issue)
      visible_relations(issue).map do |relation|
        row = { relation_type: relation.relation_type_for(issue), issue: relation.other_issue(issue).id }
        row[:delay] = relation.delay if relation.relation_type == IssueRelation::TYPE_PRECEDES
        row
      end
    end

    # --- plugins: redmineup_tags and redmine_checklists -----------------------

    # The plugin applies tags silently only with edit_tags, and drops tags that
    # do not exist yet without create_tags; both are charged to the parameter.
    def tag_attributes(issue, arguments, problems)
      sent = TAG_KEYS.select { |key| !arguments[key].nil? }
      return {} if sent.empty?

      unless user.allowed_to?(:edit_tags, issue.project)
        sent.each { |key| problems << "#{key} (needs #{permission_labels(:edit_tags)})" }
        return {}
      end
      lists = sent.to_h { |key| [key, Array(arguments[key]).map(&:to_s).reject(&:blank?)] }
      added = (lists['tag_list'] || []) + (lists['add_tag_list'] || [])
      unless added.empty? || user.allowed_to?(:create_tags, issue.project)
        existing = Issue.all_tags.map(&:name)
        %w[tag_list add_tag_list].each do |key|
          unknown = (lists[key] || []) - existing
          problems << "#{key} (new tags need #{permission_labels(:create_tags)}: #{unknown.join(', ')})" if unknown.any?
        end
      end
      lists
    end

    # The plugin's listener writes the journal detail. Called on its own with the
    # two keys it reads: the issue, and the list it checks for presence.
    def journal_tags!(issue)
      RedmineupTags::Hooks::ModelIssueHook.instance.controller_issues_edit_before_save(
        issue: issue, params: { issue: { tag_list: issue.tag_list.to_a } }
      )
    end

    # The plugin's listener journals the change and recalculates the done ratio;
    # it reads the issue and the journal, nothing else.
    def journal_checklists!(issue)
      RedmineChecklists::Hooks::ControllerIssuesHook.instance.controller_issues_edit_after_save(
        issue: issue, journal: issue.current_journal
      )
    end

    def checklist_row(item)
      { id: item.id, subject: item.subject, is_done: item.is_done, is_section: item.is_section, position: item.position }
    end

    # --- saved state --------------------------------------------------------

    STATE_READERS = {
      'description'     => ->(issue) { issue.description },
      'category'        => ->(issue) { issue.category&.name },
      'fixed_version'   => ->(issue) { issue.fixed_version&.name },
      'start_date'      => ->(issue) { issue.start_date&.iso8601 },
      'due_date'        => ->(issue) { issue.due_date&.iso8601 },
      'done_ratio'      => ->(issue) { issue.done_ratio },
      'estimated_hours' => ->(issue) { issue.estimated_hours&.to_f },
      'is_private'      => ->(issue) { issue.is_private? },
      'watcher_users'   => ->(issue) { issue.watcher_users.map(&:name) },
      'tag_list'        => ->(issue) { issue.tag_list.to_a }
    }.freeze
    STATE_ALIASES = { 'add_watcher_users' => 'watcher_users', 'remove_watcher_users' => 'watcher_users',
                      'add_tag_list' => 'tag_list', 'remove_tag_list' => 'tag_list' }.freeze

    # Read back from the database after the save and the plugins' hooks, so a
    # reply never claims a value that is not stored.
    def stored(issue)
      Issue.find(issue.id)
    end

    # The issue as saved, read back off the record: the base set, plus every
    # field the caller sent, plus the custom fields they sent.
    def issue_state(issue, arguments)
      state = {
        id: issue.id,
        subject: issue.subject,
        project_identifier: issue.project&.identifier,
        tracker: issue.tracker&.name,
        status: issue.status&.name,
        assigned_to: issue.assigned_to&.name,
        priority: issue.priority&.name,
        parent: issue.parent_id
      }
      sent = arguments.keys.map { |key| STATE_ALIASES.fetch(key, key) }
      STATE_READERS.each { |name, read| state[name.to_sym] = read.call(issue) if sent.include?(name) }
      # Only the fields that were sent, and no key when none were: an empty
      # list reads as "this issue has no custom fields".
      ids = custom_field_ids(arguments)
      state[:custom_fields] = saved_custom_fields(issue, ids) if ids.any?
      state[:url] = absolute_url(:issue_url, issue)
      state
    end

    # --- news ---------------------------------------------------------------

    def news_attributes(arguments)
      %w[title summary description].each_with_object({}) do |field, attributes|
        attributes[field] = arguments[field].to_s unless arguments[field].nil?
      end
    end

    def news_state(news)
      {
        id: news.id,
        title: news.title,
        summary: news.summary,
        author: news.author&.name,
        created_on: iso(news.created_on),
        project_identifier: news.project&.identifier,
        comments_count: news.comments_count,
        url: absolute_url(:news_url, news)
      }
    end

    def saved_custom_fields(record, ids)
      Array(ids).filter_map do |id|
        value = record.custom_field_values.detect { |v| v.custom_field_id.to_s == id.to_s }
        next if value.nil?

        custom_field_row(value)
      end
    end

    # Core keeps an empty multiple field as [nil]; its API leaves blank values out, and so does this.
    def custom_field_row(value)
      shown = value.value.is_a?(Array) ? value.value.reject(&:blank?) : value.value
      { id: value.custom_field_id, name: value.custom_field.name, value: shown }
    end

    # SchemaValidator does not walk into an object, so the shape is checked here.
    def custom_field_values_from(raw)
      return nil if raw.blank?
      raise InvalidArgument, 'custom_field_values must be an object keyed by numeric custom field id' unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(id, value), out|
        raise InvalidArgument, "custom_field_values key #{id.inspect} is not a numeric custom field id" unless /\A\d+\z/.match?(id.to_s)
        raise InvalidArgument, "custom_field_values[#{id}] must be a string, a number, or an array of them" if value.is_a?(Hash)

        out[id.to_s] = value.is_a?(Array) ? value.map(&:to_s) : value.to_s
      end
    end

    def custom_field_ids(arguments)
      arguments['custom_field_values'].is_a?(Hash) ? arguments['custom_field_values'].keys : []
    end
  end
end
