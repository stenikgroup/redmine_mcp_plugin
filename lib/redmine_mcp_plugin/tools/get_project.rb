# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetProject < Tool
      tool 'get_project',
           title: 'Get project',
           description: 'Fetch one project by identifier or numeric id: its settings, custom fields, ' \
                        'enabled modules, trackers, categories and versions.',
           permission: :view_project,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                             'description' => 'Project identifier or numeric id.' }
             },
             'required' => %w[project],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        # Core's API names the parent only to a caller who can see it.
        parent = project.parent if project.parent&.visible?(user)
        {
          id: project.id,
          identifier: project.identifier,
          name: project.name,
          description: project.description,
          homepage: project.homepage,
          status: project.status,
          is_public: project.is_public?,
          parent_id: parent&.id,
          parent: parent && { id: parent.id, identifier: parent.identifier, name: parent.name },
          inherit_members: project.inherit_members?,
          created_on: iso(project.created_on),
          updated_on: iso(project.updated_on),
          # Core's own rule, which honours the roles a field is restricted to.
          custom_fields: project.visible_custom_field_values(user).map { |value| labelled_custom_field_row(value) },
          enabled_modules: project.enabled_module_names.sort,
          trackers: project.trackers.map { |t| { id: t.id, name: t.name } },
          # Core's API lists them all; the issue page shows a role only those
          # it may see here, and so does this.
          issue_custom_fields: project.all_issue_custom_fields.select { |f| f.visible_by?(project, user) }
                                      .map { |f| { id: f.id, name: f.name } },
          default_version: named(project.default_version),
          default_assigned_to: named(project.default_assigned_to),
          default_issue_query: named(default_issue_query(project)),
          # Categories and versions are cheap and are what a model needs before
          # it can create or filter an issue sensibly.
          issue_categories: project.issue_categories.map { |c| { id: c.id, name: c.name } },
          versions: project.shared_versions.map { |v| { id: v.id, name: v.name, status: v.status } }
        }
      end

      def named(record)
        record && { id: record.id, name: record.name }
      end

      # A project's default query is a public one, which a role without
      # view_issues there still may not see.
      def default_issue_query(project)
        query = project.default_issue_query
        query if query&.visible?(user)
      end
    end
  end
end
