# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # Time entries: the activity, the user time is logged for, and the state a
    # write replies with.
    module TimeEntries
      include CustomFields

      private

      # Activities are per project; one from the global list fails validation.
      def time_entry_activity(project, name)
        activity = project.activities.find_by(name: name.to_s)
        raise ToolError, "Project #{project.identifier} has no activity named #{name.inspect}" if activity.nil?

        activity
      end

      # Whose time it is. Core answers "User is invalid" for both causes: the
      # permission to log for someone else, and a user who may not log time here.
      def time_entry_user_id(entry, value)
        id = user_id_from(value, 'user')
        return id if id == entry.user_id || id == user.id

        unless user.allowed_to?(:log_time_for_other_users, entry.project)
          raise ToolError, "Logging time for another user needs #{permission_labels(:log_time_for_other_users)}"
        end
        return id if entry.assignable_users.any? { |candidate| candidate.id == id }

        raise ToolError, "User #{id} may not log time on #{entry.project.identifier}"
      end

      def time_entry_state(entry, ids)
        state = {
          id: entry.id,
          user: entry.user && { id: entry.user_id, name: entry.user.name },
          hours: entry.hours.to_f,
          activity: entry.activity&.name,
          spent_on: entry.spent_on&.iso8601,
          comments: entry.comments,
          issue_id: entry.issue_id,
          project_identifier: entry.project&.identifier,
          url: entry.issue ? absolute_url(:issue_url, entry.issue) : absolute_url(:project_time_entries_url, entry.project)
        }
        # No key when none were sent: an empty list reads as "no custom fields".
        state[:custom_fields] = saved_custom_fields(entry, ids) if ids.any?
        state
      end
    end
  end
end
