# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # Tags on an issue, through whichever tags plugin Integrations finds usable:
    # redmineup_tags or additional_tags. They differ in their permissions, in
    # what they read off safe_attributes= and in how the change is journaled;
    # the parameters and the refusals are the same for both.
    module Tags
      TAG_KEYS = %w[tag_list add_tag_list remove_tag_list].freeze

      # The permission to set tags, the one to coin a new tag, and the one to
      # read them, which redmineup_tags does not have.
      TAG_PERMISSIONS = {
        redmineup_tags: { edit: :edit_tags, create: :create_tags, view: nil },
        additional_tags: { edit: :edit_issue_tags, create: :create_issue_tags, view: :view_issue_tags }
      }.freeze

      private

      def tags_plugin = Integrations.tags_plugin

      # additional_tags has a switch for issue tags, off by default; with it off
      # the plugin ignores every tag it is handed.
      def tags_switched_off?
        tags_plugin == :additional_tags && !AdditionalTags.setting?(:active_issue_tags)
      end

      def tags_readable?(project)
        return false if tags_plugin.nil? || tags_switched_off?

        view = TAG_PERMISSIONS.fetch(tags_plugin)[:view]
        view.nil? || user.allowed_to?(view, project)
      end

      # Both plugins apply tags silently only under their edit permission, and
      # drop a tag that does not exist yet without their create permission;
      # both are charged to the parameter instead.
      def tag_attributes(issue, arguments, problems)
        sent = TAG_KEYS.reject { |key| arguments[key].nil? }
        return {} if sent.empty? || tags_plugin.nil?

        cause = tags_refusal(issue.project)
        if cause
          sent.each { |key| problems << "#{key} (#{cause})" }
          return {}
        end
        lists = sent.index_with { |key| Array(arguments[key]).map(&:to_s).reject(&:blank?) }
        refuse_new_tags(issue.project, lists, problems)
        tags_plugin == :additional_tags ? { 'tag_list' => resulting_tags(issue, lists) } : lists
      end

      def tags_refusal(project)
        return 'issue tags are switched off in the additional_tags settings' if tags_switched_off?

        edit = TAG_PERMISSIONS.fetch(tags_plugin)[:edit]
        "needs #{permission_labels(edit)}" unless user.allowed_to?(edit, project)
      end

      def refuse_new_tags(project, lists, problems)
        create = TAG_PERMISSIONS.fetch(tags_plugin)[:create]
        return if user.allowed_to?(create, project)

        existing = known_tags
        %w[tag_list add_tag_list].each do |key|
          unknown = (lists[key] || []) - existing
          problems << "#{key} (new tags need #{permission_labels(create)}: #{unknown.join(', ')})" if unknown.any?
        end
      end

      # redmineup_tags takes the three keys as they are. additional_tags reads
      # tag_list alone, so what add and remove leave is worked out here.
      def resulting_tags(issue, lists)
        base = lists.key?('tag_list') ? lists['tag_list'] : issue.tag_list.to_a
        (base + lists.fetch('add_tag_list', [])).uniq - lists.fetch('remove_tag_list', [])
      end

      # The tags that exist, as the plugin lists them: additional_tags keeps to
      # the projects where the user may view tags.
      def known_tags
        tags = tags_plugin == :additional_tags ? Issue.available_tags(user: user) : Issue.all_tags
        tags.map(&:name)
      end

      # redmineup_tags journals through a listener, called on its own with the two
      # keys it reads: the issue, and the list it checks for presence.
      # additional_tags journals the attribute itself.
      def journal_tags!(issue)
        return unless tags_plugin == :redmineup_tags

        RedmineupTags::Hooks::ModelIssueHook.instance.controller_issues_edit_before_save(
          issue: issue, params: { issue: { tag_list: issue.tag_list.to_a } }
        )
      end

      # What the caller may do with tags in this project, and the tags there are.
      def tags_summary(project, limit)
        permissions = TAG_PERMISSIONS.fetch(tags_plugin)
        names       = known_tags
        { edit: user.allowed_to?(permissions[:edit], project), create: user.allowed_to?(permissions[:create], project),
          available: names.first(limit), truncated: names.size > limit }
      end
    end
  end
end
