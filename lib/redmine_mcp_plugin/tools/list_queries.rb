# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListQueries < Tool
      tool 'list_queries',
           title: 'List saved issue queries',
           description: 'List the saved issue queries visible to the authenticated user. Pass the id ' \
                        'of one to search_issues as query_id to run it, optionally narrowing it further.',
           permission: :view_issues,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                             'description' => 'Only queries global or on this project (identifier or numeric id).' },
               'name' => { 'type' => 'string', 'description' => 'Case-insensitive substring of the query name.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap. Defaults to 0.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1 }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        # Query.visible applies the public/private/role rules; never Query.find.
        scope = IssueQuery.visible(user)

        if (identifier = arguments['project'].presence)
          project = fetch_project(identifier)
          authorize!(:view_issues, project)
          scope = scope.global_or_on_project(project)
        end

        if (needle = arguments['name'].presence)
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(needle.to_s)}%"
          scope = scope.where('LOWER(queries.name) LIKE LOWER(:p)', p: pattern)
        end

        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        rows   = scope.sorted.offset(offset).limit(limit).map do |query|
          { id: query.id, name: query.name, project_identifier: query.project&.identifier,
            is_public: query.is_public?, is_global: query.project_id.nil? }
        end
        paged(total: scope.count, offset: offset, key: :queries, rows: rows)
      end
    end
  end
end
