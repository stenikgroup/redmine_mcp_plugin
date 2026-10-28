# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetIssue < Tool
      tool 'get_issue',
           title: 'Get issue',
           description: 'Fetch one issue with its description, attachments, watchers and plugin data ' \
                        'where permitted, and optionally its notes and history.',
           permission: :view_issues,
           scopes: %i[view_issue_watchers],
           plugin_scopes: { redmine_checklists: %i[view_checklists] },
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'include_journals' => { 'type' => 'boolean',
                                       'description' => 'Include notes and change history. Defaults to true.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      # The details core's issue history names, by show_detail's own list.
      NAMED_DETAILS = %w[project_id status_id tracker_id assigned_to_id priority_id category_id fixed_version_id].freeze
      # References are named without _id, as the parameters are; core shows the last three as ids.
      REFERENCE_DETAILS = (NAMED_DETAILS + %w[parent_id child_id author_id]).freeze

      private

      def perform(arguments)
        issue = fetch_issue(arguments['issue'])
        authorize!(:view_issues, issue.project)

        payload = {
          id: issue.id,
          subject: issue.subject,
          description: issue.description,
          project: issue.project&.name,
          project_identifier: issue.project&.identifier,
          tracker: issue.tracker&.name,
          status: issue.status&.name,
          priority: issue.priority&.name,
          author: issue.author&.name,
          assigned_to: issue.assigned_to&.name,
          category: issue.category&.name,
          fixed_version: issue.fixed_version&.name,
          parent_id: issue.parent_id,
          children: child_rows(issue),
          start_date: issue.start_date&.iso8601,
          due_date: issue.due_date&.iso8601,
          done_ratio: issue.done_ratio,
          estimated_hours: issue.estimated_hours,
          is_private: issue.is_private?,
          created_on: iso(issue.created_on),
          updated_on: iso(issue.updated_on),
          custom_fields: visible_custom_fields(issue),
          attachments: attachment_rows(issue),
          relations: relation_rows(issue)
        }

        # Keys, not empty lists, so a missing permission never reads as "nobody".
        payload[:watchers] = issue.watcher_users.map { |p| principal_row(p) } if user.allowed_to?(:view_issue_watchers, issue.project)
        if plugin?(:redmine_checklists) && user.allowed_to?(:view_checklists, issue.project)
          payload[:checklists] = issue.checklists.map { |item| checklist_row(item) }
        end
        payload[:tag_list] = issue.tag_list.to_a if plugin?(:redmineup_tags)

        include_journals = arguments.fetch('include_journals', true)
        payload[:journals] = journals_for(issue) if include_journals
        payload
      end

      # Issue#visible_custom_field_values applies per-field role visibility.
      # Reading custom_field_values directly would leak fields core hides.
      def visible_custom_fields(issue)
        issue.visible_custom_field_values.map { |value| custom_field_row(value) }
      end

      # Direct subtasks in the tree's order, only those the user may see, as on the issue page.
      def child_rows(issue)
        issue.children.select { |child| child.visible?(user) }.map { |child| { id: child.id, subject: child.subject } }
      end

      # By Attachment#visible?, as downloads and get_attachment check it: a file the user may not open is
      # not listed either, as its name, author and description can tell what its content would.
      def attachment_rows(issue)
        issue.attachments.select { |attachment| attachment.visible?(user) }.map { |attachment| attachment_row(attachment) }
      end

      # Journal#notes can be private (private_notes), and core gates that on
      # :view_private_notes. Journal.visible applies exactly that rule.
      def journals_for(issue)
        # Core's history lookup names a project by Project#visible?, which reads User.current.
        raise ToolError, 'You do not have permission to do that' unless User.current == user

        # Fresh per call: it caches names, and a project's name depends on who asks.
        history = Class.new { include IssuesHelper }.new
        # The plugin's own history leaves its changes out for anyone without view_checklists.
        checklists = !plugin?(:redmine_checklists) || user.allowed_to?(:view_checklists, issue.project)
        issue.journals.visible(user).includes(:user).order(:created_on).filter_map do |journal|
          details = journal.visible_details(user)
          details = details.reject { |detail| checklist_detail?(detail) } unless checklists
          rows    = details.filter_map { |detail| detail_row(detail, history) }
          # As the issue page: an entry with no notes and nothing the user may see is left out.
          next if rows.empty? && !journal.notes?

          {
            id: journal.id,
            user: journal.user&.name,
            notes: journal.notes.presence,
            private_notes: journal.private_notes?,
            created_on: iso(journal.created_on),
            details: rows
          }
        end
      end

      # As the issue history shows them: a record or custom field by its name, an id it cannot name as the id.
      def detail_row(detail, history)
        return checklist_change(detail) if checklist_diff?(detail)

        name      = detail.prop_key
        old_value = detail.old_value
        new_value = detail.value
        if detail.property == 'cf'
          # visible_details already drops a deleted field's details; the id is only a fallback.
          name = detail.custom_field&.name || name
        elsif detail.property == 'attr' && REFERENCE_DETAILS.include?(name)
          name = name.delete_suffix('_id')
          if NAMED_DETAILS.include?(detail.prop_key)
            old_value = history.find_name_by_reflection(name, old_value) || old_value
            new_value = history.find_name_by_reflection(name, new_value) || new_value
          end
        end
        { property: detail.property, name: name, old_value: old_value, new_value: new_value }
      end

      # What the plugin's history counts as its own: the issue's list, and its custom field format.
      def checklist_detail?(detail)
        (detail.property == 'attr' && detail.prop_key == 'checklist') || detail.custom_field&.field_format == 'checklist'
      end

      # Its first versions stored "[x] item" text, which the diff cannot read; that is shown as it is.
      def checklist_diff?(detail)
        detail.property == 'attr' && detail.prop_key == 'checklist' && plugin?(:redmine_checklists) &&
          !Checklist.old_format?(detail)
      end

      # The plugin journals the whole list on both sides; its own diff says what changed. A change it
      # cannot name (a reorder) is left out, as on the issue page.
      def checklist_change(detail)
        diff    = JournalChecklistHistory.new(detail.old_value, detail.value).diff
        changes = {
          added: diff[:added].map(&:subject), removed: diff[:removed].map(&:subject),
          done: diff[:done].map(&:subject), undone: diff[:undone].map(&:subject),
          renamed: diff[:renamed].map { |was, became| { from: was.subject, to: became.subject } }
        }.reject { |_key, items| items.empty? }
        { property: detail.property, name: detail.prop_key, **changes } if changes.any?
      end
    end
  end
end
