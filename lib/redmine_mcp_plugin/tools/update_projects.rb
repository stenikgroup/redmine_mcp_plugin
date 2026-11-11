# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Preview and write are one path through one transaction. Core's setters
    # for trackers, modules and issue custom fields write on assignment, before
    # any validation, so only a rollback can show what a write would do, undo
    # half a project, or keep several projects all-or-nothing.
    class UpdateProjects < Tool
      include ProjectFields

      MAX_PROJECTS = 50
      # Redmine keeps no history of project changes; this file is the only one.
      LOG = 'log/redmine_mcp_plugin_projects.log'
      # What a save, a move, a close and enabling a module write.
      TABLES = %w[projects custom_values enabled_modules projects_trackers custom_fields_projects members
                  member_roles issues journals journal_details wikis].freeze

      tool 'update_projects',
           title: 'Update projects',
           description: 'Change one or more projects: any field get_project_fields lists. Redmine keeps no ' \
                        'history of project changes: first call with preview: true, show the user the current ' \
                        'and the new value of every field per project, and write only after an explicit yes. ' \
                        'All projects are written or none. A refusal names each project and field; then do ' \
                        'not retry without them: tell the user and ask. "none" clears an optional reference. ' \
                        'Report old and new values from the reply.',
           permission: %i[edit_project close_project],
           scopes: %i[select_project_publicity select_project_modules add_subprojects add_project],
           write: true,
           destructive: true,
           rendered: %w[description],
           plain: %w[name],
           schema: {
             'type' => 'object',
             'properties' => {
               'projects' => { 'type' => 'array',
                               'description' => "Identifiers or ids of the projects that get the fields below. At most #{MAX_PROJECTS} per call." },
               'per_project' => { 'type' => 'object',
                                  'description' => 'Values that differ per project: {"<identifier or id>": {fields}}, over the shared fields.' },
               'preview' => { 'type' => 'boolean',
                              'description' => 'true: write nothing; return current -> new per project and every refusal.' },
               'name' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'homepage' => { 'type' => 'string' },
               'is_public' => { 'type' => 'boolean' },
               'parent' => { 'type' => %w[string integer], 'description' => 'Project identifier or id; "none" for top level.' },
               'inherit_members' => { 'type' => 'boolean' },
               'status' => { 'type' => 'string', 'enum' => %w[active closed],
                             'description' => 'closed closes the project and all its subprojects; active reopens them.' },
               'add_trackers' => { 'type' => 'array', 'description' => 'Tracker names.' },
               'remove_trackers' => { 'type' => 'array', 'description' => 'Tracker names.' },
               'add_issue_custom_fields' => { 'type' => 'array', 'description' => 'Issue custom field ids.' },
               'remove_issue_custom_fields' => { 'type' => 'array', 'description' => 'Issue custom field ids.' },
               'add_enabled_modules' => { 'type' => 'array', 'description' => 'Module names.' },
               'remove_enabled_modules' => { 'type' => 'array', 'description' => 'Module names.' },
               'default_version' => { 'type' => %w[string integer], 'description' => 'Name or id.' },
               'default_assigned_to' => { 'type' => %w[integer string], 'description' => 'User id, or "me".' },
               'default_issue_query' => { 'type' => %w[integer string], 'description' => 'Query id.' },
               'custom_field_values' => { 'type' => 'object',
                                          'description' => 'By field id; the value, never the label, exactly as ' \
                                                           'get_project_fields lists it; "" clears.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        # Core's validation and the journals of a move read User.current.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

        targets = targets_from(arguments)
        require_transactions!
        preview = arguments['preview'] == true
        results = write(targets, preview)

        reply = { preview: preview }
        reply[:would_write] = results.none? { |result| result[:refused] } if preview
        reply.merge(projects: results)
      end

      def write(targets, preview)
        results = nil
        @log = []
        Project.transaction(requires_new: true) do
          # Core's lock on the project tree, taken before anything is changed.
          # A rename or a move takes it anyway; taken after other rows were
          # written it deadlocks against a rename in the web UI, which then fails.
          targets.first.first.send(:lock_nested_set)
          results = targets.map { |project, fields| change(project, fields) }
          refused = results.select { |result| result[:refused] }
          raise ToolError, nothing_written(refused) if refused.any? && !preview
          raise ActiveRecord::Rollback if preview

          # Inside the transaction: a change that cannot be logged is not made.
          log!
        end
        results
      rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
        raise ToolError, 'Nothing was written: another change holds these projects. Try again'
      end

      # --- which projects, which fields ---------------------------------------

      def targets_from(arguments)
        shared = arguments.slice(*FIELDS.keys).compact
        own    = arguments['per_project'] || {}
        unless own.is_a?(Hash) && own.values.all?(Hash)
          raise InvalidArgument, 'per_project must be an object: {"<identifier or id>": {fields}}'
        end

        references = Array(arguments['projects']).map(&:to_s) | own.keys
        raise ToolError, 'Name at least one project, in projects or per_project' if references.empty?
        raise ToolError, "At most #{MAX_PROJECTS} projects per call, got #{references.size}" if references.size > MAX_PROJECTS

        seen = {}
        references.map do |reference|
          project = fetch_project(reference)
          raise ToolError, "Project #{project.identifier} is named twice: #{seen[project.id]} and #{reference}" if seen[project.id]

          seen[project.id] = reference
          fields = merged(shared, own_fields(own[reference], reference))
          raise ToolError, "No field to change for #{project.identifier}" if fields.empty?

          [project, fields]
        end
      end

      # SchemaValidator does not walk into an object, so an entry is checked
      # against the same properties as the shared fields.
      def own_fields(entry, reference)
        return {} if entry.nil?

        schema = { 'type' => 'object', 'additionalProperties' => false,
                   'properties' => self.class.effective_schema['properties'].slice(*FIELDS.keys) }
        SchemaValidator.validate!(schema, entry)
        SchemaValidator.coerce(schema, entry).compact
      rescue ToolError => e
        raise InvalidArgument, "per_project[#{reference.inspect}]: #{e.message}"
      end

      def merged(shared, own)
        fields = shared.merge(own)
        both   = [shared, own].filter_map { |set| set['custom_field_values'] }
        fields['custom_field_values'] = both.map { |values| values.to_h.transform_keys(&:to_s) }.reduce(:merge) if both.size == 2
        fields
      end

      # --- one project ----------------------------------------------------------

      def change(project, fields)
        before   = project_state(project.id, fields)
        problems = []
        status   = fields['status']
        blocked(problems, 'status') { (reason = field_block(project, 'status')) && raise(ToolError, reason) } if status

        # Reopened first and closed last, so each part still passes its own
        # check: core refuses to edit a closed project.
        toggle!(project) if status == 'active' && problems.empty? && !project.active?
        attributes = project_attributes(project, fields, problems)
        save(project, attributes, problems) if problems.empty? && attributes.any?
        toggle!(project) if status == 'closed' && problems.empty? && project.active?

        after = project_state(project.id, fields)
        problems.concat(unstored(after, fields)) if problems.empty?
        result = { id: project.id, identifier: project.identifier }
        return result.merge(name: before['name'], refused: problems) if problems.any?

        changes, unchanged = project_changes(before, after, fields)
        subprojects = moved_subprojects(before, after)
        note_changes(project, changes, subprojects)
        changes.each { |entry| entry.merge!(subprojects_too(subprojects)) if entry[:field] == 'status' && subprojects.any? }
        result.merge(name: after['name'], changes: changes, unchanged: unchanged, url: absolute_url(:project_url, project))
      end

      # Core's own close and reopen: every subproject goes along.
      def toggle!(project)
        project.active? ? project.close : project.reopen
        project.reload
      end

      def save(project, attributes, problems)
        project.safe_attributes = attributes
        return if project.save

        project.errors.each do |error|
          problems << "#{FIELDS.key(error.attribute.to_s) || 'custom_field_values'} (#{error.full_message})"
        end
      end

      # The net behind the guards: a value core or a plugin dropped without a
      # word is refused by name, not reported as unchanged.
      def unstored(after, fields)
        fields.filter_map do |name, value|
          kept = case name
                 when 'name', 'description', 'homepage' then same?(after[name], value)
                 when 'is_public', 'inherit_members'    then after[name] == value
                 when 'add_enabled_modules', 'add_trackers'       then (value.map(&:to_s) - after[name.delete_prefix('add_')]).empty?
                 when 'remove_enabled_modules', 'remove_trackers' then !after[name.delete_prefix('remove_')].intersect?(value.map(&:to_s))
                 when 'custom_field_values'
                   value.all? { |id, sent| same?(after['custom_fields'][id.to_i]&.fetch(:value), sent) }
                 else true
                 end
          "#{name} (Redmine did not store the value)" unless kept
        end
      end

      def same?(stored, sent)
        [stored, sent].map { |value| Array(value).map { |v| v.to_s.strip }.reject(&:empty?).sort }.uniq.size == 1
      end

      def moved_subprojects(before, after)
        return [] unless before['subprojects']

        ids = before['subprojects'].reject { |id, status| after['subprojects'][id] == status }.keys
        Project.where(id: ids).order(:lft).to_a
      end

      def subprojects_too(subprojects)
        visible = subprojects.select { |project| project.visible?(user) }
        { subprojects: visible.map(&:identifier), hidden_subprojects: subprojects.size - visible.size }
      end

      def nothing_written(refused)
        'Nothing was written. ' + refused.map { |result| "#{result[:identifier]}: cannot set #{result[:refused].join(', ')}." }.join(' ')
      end

      # --- the change log -------------------------------------------------------

      def note_changes(project, changes, subprojects)
        return if changes.empty?

        who    = "user=#{user.login} (##{user.id})"
        status = changes.detect { |entry| entry[:field] == 'status' }
        @log << "#{Time.now.utc.iso8601} #{who} project=#{project.identifier} (##{project.id}) " \
                "#{changes.map { |entry| log_entry(entry) }.join('; ')}\n"
        subprojects.each do |sub|
          @log << "#{Time.now.utc.iso8601} #{who} project=#{sub.identifier} (##{sub.id}) " \
                  "#{log_entry(status)} (with #{project.identifier})\n"
        end
      end

      # Values as JSON, so a long description stays on its line, in full.
      def log_entry(entry)
        field = entry[:id] ? "custom field #{entry[:id]} #{entry[:name].to_json}" : entry[:field]
        "#{field}: #{entry[:old].to_json} -> #{entry[:new].to_json}"
      end

      def log!
        return if @log.empty?

        File.open(Rails.root.join(LOG), 'a') do |file|
          file.flock(File::LOCK_EX)
          file.write(@log.join)
        end
      rescue SystemCallError => e
        raise ToolError, "Nothing was written: the change log #{LOG} cannot be written (#{e.class.name.demodulize})"
      end

      # --- the database -----------------------------------------------------------

      # All-or-nothing and the preview are a rolled-back transaction, which a
      # MyISAM table would not take part in: there even a preview would write.
      def require_transactions!
        connection = Project.connection
        return unless connection.adapter_name.match?(/mysql|trilogy/i)

        names = TABLES.map { |table| connection.quote("#{ActiveRecord::Base.table_name_prefix}#{table}#{ActiveRecord::Base.table_name_suffix}") }
        other = connection.select_values('SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() ' \
                                         "AND engine <> 'InnoDB' AND table_name IN (#{names.join(', ')})")
        return if other.empty?

        raise ToolError, "Nothing was written and nothing can be previewed: the tables #{other.join(', ')} are not InnoDB, " \
                         'so a change could not be undone. This is for the Redmine administrator to fix'
      end
    end
  end
end
