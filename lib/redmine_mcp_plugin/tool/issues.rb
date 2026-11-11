# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # What every tool that touches an issue shares: core's rules for a note and
    # an edit, the relations, and the saved state a write replies with.
    module Issues
      include CustomFields

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

      private

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
    end
  end
end
