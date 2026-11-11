# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # The watchers of an issue: who may be added, and core's permissions for
    # adding and removing someone else.
    module Watchers
      WATCHER_KEYS = %w[add_watcher_users remove_watcher_users].freeze

      private

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

      def watcher_principals(issue, arguments, name, permission, problems, &block)
        ids = Array(arguments[name]).map { |v| user_id_from(v, name) }.uniq
        return [] if ids.empty?

        if ids.any? { |id| id != user.id } && !user.allowed_to?(permission, issue.project)
          problems << "#{name} (needs #{permission_labels(permission)})"
          return []
        end
        blocked(problems, name) { ids.map(&block) } || []
      end

      def apply_watcher_changes!(issue, adds, removes)
        adds.each    { |principal| issue.add_watcher(principal) unless issue.watched_by?(principal) }
        removes.each { |principal| issue.remove_watcher(principal) }
      end
    end
  end
end
