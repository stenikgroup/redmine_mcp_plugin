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
    # #call under the tool's user, and the readers of how they authenticated.
    prepend ActingUser

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
      # the plugins it looks for. Usable, not merely installed: see Integrations.
      def plugin?(id) = Integrations.usable?(id)

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
        absent = Integrations.absent(@plugin_properties.to_h)
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

    # Invoked by the dispatcher, through ActingUser#call, which sets
    # User.current to this tool's user first. Subclasses implement #perform.
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
    # Issue.visible is SQL built on roles and ignores OAuth scopes; Issue#visible?
    # goes through allowed_to?(:view_issues), so a token without view_issues
    # cannot write to an issue and read it back in the reply.
    def fetch_issue(id)
      issue = Issue.visible(user).find_by(id: id.to_i)
      raise ToolError, "No visible issue with id #{id.inspect}" if issue.nil? || !issue.visible?(user)

      issue
    end

    # allowed_to? is false for a disabled module, which would read as a
    # permissions problem; name the real cause instead.
    def require_module!(project, name)
      return if project.module_enabled?(name)

      raise ToolError, "The #{name} module is not enabled for project #{project.identifier}"
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
      refuse_blocked!(record, unsafe.map { |key| parameter_name(key) })
    end

    # The parameter a caller sent for a core attribute. They are the same
    # unless a tool renames one, as IssueWrites does.
    def parameter_name(attribute) = attribute

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

    def principal_row(principal)
      { id: principal.id, name: principal.name, type: principal.class.name }
    end

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

    # allowed_to? is false for every write on a closed project, which would read
    # as a permissions problem; name the real cause, as require_module! does.
    # get_project already returns the status to anyone who can see the project.
    def authorize_open!(permission, project)
      raise ToolError, "Project #{project.identifier} is closed; reopen it first" if project.closed?

      authorize!(permission, project)
    end

    def save_or_refuse!(record, act)
      return if record.save

      raise ToolError, "Could not #{act}: #{record.errors.full_messages.join('; ')}"
    end

    # Core's update answers with no body, so a write needs no read permission;
    # the saved record is returned only to a caller who may read it, and
    # otherwise the write is acknowledged by id.
    def readable_in?(project, permission)
      project.visible?(user) && user.allowed_to?(permission, project)
    end

    # Project.visible is SQL built on roles and ignores OAuth scopes;
    # Project#visible? goes through allowed_to?(:view_project).
    def fetch_readable_project(identifier)
      project = fetch_project(identifier)
      raise ToolError, "No visible project matching #{identifier.inspect}" unless project.visible?(user)

      project
    end

    def written_unread(record, url_helper = nil)
      state = { id: record.id, project_identifier: record.project.identifier,
                note: "Saved. Reading it back needs #{permission_labels(:view_issues)}." }
      state[:url] = absolute_url(url_helper, record) if url_helper
      state
    end
  end
end
