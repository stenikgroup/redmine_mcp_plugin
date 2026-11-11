# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Present only with the redmine_checklists plugin installed.
    class UpdateIssueChecklists < Tool
      tool 'update_issue_checklists',
           title: 'Update checklist items',
           description: 'Add, rename, tick or untick checklist items on an issue, only when the user asks. ' \
                        'End with the url.',
           plugin: :redmine_checklists,
           permission: %i[done_checklists edit_checklists],
           rendered: %w[add],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'add' => { 'type' => 'array', 'items' => { 'type' => 'string' }, 'description' => 'Subjects of new items.' },
               'done' => { 'type' => 'array', 'items' => { 'type' => %w[integer string] }, 'description' => 'Checklist ids to tick.' },
               'undone' => { 'type' => 'array', 'items' => { 'type' => %w[integer string] }, 'description' => 'Checklist ids to untick.' },
               'rename' => { 'type' => 'array', 'items' => { 'type' => 'object' }, 'description' => '[{"checklist": id, "subject": text}]' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue   = fetch_issue(arguments['issue'])
        adds    = Array(arguments['add']).map(&:to_s).reject(&:blank?)
        renames = Array(arguments['rename'])
        done    = Array(arguments['done'])
        undone  = Array(arguments['undone'])
        raise ToolError, 'Pass add, done, undone or rename' if [adds, renames, done, undone].all?(&:empty?)

        # Either of the plugin's permissions admits the tool on this project;
        # adding and renaming then need edit_checklists, ticking either one.
        edit = user.allowed_to?(:edit_checklists, issue.project)
        raise ToolError, 'You do not have permission to do that' unless edit || user.allowed_to?(:done_checklists, issue.project)

        # Every check runs; one refusal then names each blocked parameter.
        causes = Hash.new { |hash, key| hash[key] = [] }
        causes['add']    << "needs #{permission_labels(:edit_checklists)}" if adds.any? && !edit
        causes['rename'] << "needs #{permission_labels(:edit_checklists)}" if renames.any? && !edit
        items  = issue.checklists.to_a
        change = {}
        if edit
          renames.each do |entry|
            entry = entry.is_a?(Hash) ? entry : {}
            item  = item_for(items, entry['checklist'])
            next causes['rename'] << "#{entry['checklist'].inspect} is not an item of ##{issue.id}" if item.nil?
            next causes['rename'] << "checklist #{item.id} needs a subject" if entry['subject'].to_s.strip.empty?

            change[item.id] = { 'id' => item.id, 'subject' => entry['subject'].to_s }
          end
        end
        { 'done' => [done, true], 'undone' => [undone, false] }.each do |name, (ids, value)|
          ids.each do |id|
            item = item_for(items, id)
            next causes[name] << "#{id.inspect} is not an item of ##{issue.id}" if item.nil?

            # The plugin's nested attributes reject an item hash without a
            # subject, so the current subject travels with a tick.
            (change[item.id] ||= { 'id' => item.id, 'subject' => item.subject })['is_done'] = value
          end
        end
        refuse_blocked!(issue, causes.map { |name, list| "#{name} (#{list.join('; ')})" })
        attributes = change.values + adds.map { |subject| { 'subject' => subject } }

        # The plugin's listener diffs this snapshot against the saved items.
        issue.old_checklists = issue.checklists.to_json
        issue.init_journal(user)
        issue.safe_attributes = { 'checklists_attributes' => attributes }
        Issue.transaction do
          raise ToolError, "Could not update checklist: #{issue.errors.full_messages.join('; ')}" unless issue.save

          journal_checklists!(issue)
          refuse_untaken!(issue, change, adds, items)
        end

        saved = stored(issue)
        { issue_id: saved.id,
          checklists: saved.checklists.map { |item| checklist_row(item) },
          url: absolute_url(:issue_url, saved) }
      end

      # What was asked, read back after the save and the plugin's hook. Raised
      # inside the transaction, so one item that did not take rolls everything back.
      def refuse_untaken!(issue, change, adds, before)
        after   = Checklist.where(issue_id: issue.id).to_a
        by_id   = after.index_by { |item| item.id }
        untaken = change.values.filter_map do |attrs|
          item = by_id[attrs['id']]
          next "#{attrs['id']} is gone" if item.nil?
          next "#{item.id} is still #{item.is_done ? 'done' : 'not done'}" if attrs.key?('is_done') && item.is_done != attrs['is_done']

          "#{item.id} is still named #{item.subject.inspect}" if item.subject != attrs['subject']
        end
        new_subjects = (after.map(&:id) - before.map(&:id)).map { |id| by_id[id].subject }
        adds.each do |subject|
          index = new_subjects.index(subject)
          index ? new_subjects.delete_at(index) : untaken << "#{subject.inspect} was not added"
        end
        return if untaken.empty?

        raise ToolError, "Checklist change not stored, rolled back: #{untaken.join('; ')}"
      end

      # An item of this issue; a section is a heading, not an item.
      def item_for(items, id)
        item = items.detect { |i| i.id.to_s == id.to_s }
        item unless item.nil? || item.is_section
      end
    end
  end
end
