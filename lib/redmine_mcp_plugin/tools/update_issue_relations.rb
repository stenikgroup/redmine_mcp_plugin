# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssueRelations < Tool
      include Issues

      tool 'update_issue_relations',
           title: 'Update issue relations',
           description: 'Add or remove relations between issues, only when the user asks. End with the url.',
           permission: :manage_issue_relations,
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'add' => { 'type' => 'array', 'items' => { 'type' => 'object' },
                          'description' => '[{"issue": id, "relation_type": type, "delay": days}], seen from issue. ' \
                                           'Types: relates, duplicates, duplicated, blocks, blocked, precedes, follows, ' \
                                           'copied_to, copied_from. delay only with precedes, follows.' },
               'remove' => { 'type' => 'array', 'items' => { 'type' => %w[integer string] },
                             'description' => 'Ids of related issues; every relation with each is removed.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      ENTRY_KEYS = %w[issue relation_type delay].freeze
      DELAYED    = [IssueRelation::TYPE_PRECEDES, IssueRelation::TYPE_FOLLOWS].freeze

      private

      def perform(arguments)
        issue   = fetch_issue(arguments['issue'])
        adds    = Array(arguments['add'])
        removes = Array(arguments['remove']).map(&:to_s).uniq
        raise ToolError, 'Pass add or remove' if adds.empty? && removes.empty?

        adds.each { |entry| check_entry!(entry) }
        authorize!(:manage_issue_relations, issue.project)

        # Redmine's checks read the database, so each entry runs against what the ones
        # before it leave, and one refusal rolls them all back.
        causes = { 'remove' => [], 'add' => [] }
        Issue.transaction do
          removes.each { |id| remove_relations(issue, id, causes['remove']) }
          adds.each { |entry| add_relation(issue, entry, causes['add']) }
          refuse_blocked!(issue, causes.reject { |_name, list| list.empty? }.map { |name, list| "#{name} (#{list.join('; ')})" })
        end

        saved = stored(issue)
        { issue_id: saved.id, relations: relation_rows(saved), url: absolute_url(:issue_url, saved) }
      end

      # SchemaValidator does not look inside an array. Without relation_type Redmine makes
      # the relation "relates", so a misspelt key is refused rather than defaulted.
      def check_entry!(entry)
        return if entry.is_a?(Hash) && entry.key?('issue') && entry.key?('relation_type') && (entry.keys - ENTRY_KEYS).empty?

        raise InvalidArgument, 'Each add entry is {"issue": id, "relation_type": type}, plus "delay" for precedes or follows'
      end

      # One relation each way is allowed, so a pair may hold two; both go.
      def remove_relations(issue, id, causes)
        found = visible_relations(issue).select { |relation| relation.other_issue(issue).id.to_s == id }
        return causes << "#{id} is not related to ##{issue.id}" if found.empty?

        other = found.first.other_issue(issue)
        found.each do |relation|
          # One object per issue, so each issue gets one journal for the call.
          relation.issue_from, relation.issue_to = relation.issue_from_id == issue.id ? [issue, other] : [other, issue]
          relation.init_journals(user)
          relation.destroy
        end
      end

      # Redmine's relation form: the other issue is looked up among those the user may see.
      def add_relation(issue, entry, causes)
        relation = IssueRelation.new(issue_from: issue)
        relation.public_send(:safe_attributes=, { 'relation_type' => entry['relation_type'].to_s, 'delay' => entry['delay'],
                                                  'issue_to_id' => entry['issue'].to_s }, user)
        relation.init_journals(user)
        problems = []
        # Redmine would drop it and save the rest.
        problems << 'delay is only for precedes and follows' unless entry['delay'].nil? || DELAYED.include?(entry['relation_type'])
        problems.concat(save_errors(relation))
        causes << "#{entry['relation_type']} #{entry['issue']}: #{problems.join(', ')}" if problems.any?
      end

      # Redmine's messages, in the caller's language. A savepoint each, so a duplicate only
      # the unique index catches is reported as Redmine's form reports it, and the rest still run.
      def save_errors(relation)
        begin
          return [] if IssueRelation.transaction(requires_new: true) { relation.save }
        rescue ActiveRecord::RecordNotUnique
          relation.errors.add(:base, :taken)
        end
        I18n.with_locale(caller_locale) { relation.errors.full_messages }
      end
    end
  end
end
