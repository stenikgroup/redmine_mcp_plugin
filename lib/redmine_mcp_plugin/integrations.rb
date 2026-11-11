# frozen_string_literal: true

module RedmineMcpPlugin
  # The third-party plugins some tools reach into, and what they reach for.
  #
  # redmine_checklists, redmineup_tags and additional_tags publish no API for
  # this: the tools call their models, the methods they add to Issue, and the
  # hook listeners that write their journal details. A release of either can rename any of it, and a tool
  # would then fail in the middle of a write.
  #
  # So each plugin has a contract here: every name a tool calls, with the check
  # that it is there. A plugin is usable when it is installed and its contract
  # holds. One that is installed and does not hold is treated as absent: its
  # tool is not listed, its parameters are not in any schema, its parts are
  # left out of a reply, and the log says once what is missing. Nothing fails.
  module Integrations
    CONTRACTS = {
      redmine_checklists: {
        'Checklist.old_format?' => -> { defined?(::Checklist) && ::Checklist.respond_to?(:old_format?) },
        'Issue#checklists' => -> { ::Issue.method_defined?(:checklists) },
        'Issue#old_checklists=' => -> { ::Issue.method_defined?(:old_checklists=) },
        'RedmineChecklists.issue_done_ratio?' => lambda {
          defined?(::RedmineChecklists) && ::RedmineChecklists.respond_to?(:issue_done_ratio?)
        },
        'JournalChecklistHistory' => -> { defined?(::JournalChecklistHistory) ? true : false },
        'RedmineChecklists::Hooks::ControllerIssuesHook#controller_issues_edit_after_save' => lambda {
          listener?('RedmineChecklists::Hooks::ControllerIssuesHook', :controller_issues_edit_after_save)
        }
      },
      redmineup_tags: {
        'Issue.all_tags' => -> { ::Issue.respond_to?(:all_tags) },
        'Issue#tag_list' => -> { ::Issue.method_defined?(:tag_list) },
        'RedmineupTags::Hooks::ModelIssueHook#controller_issues_edit_before_save' => lambda {
          listener?('RedmineupTags::Hooks::ModelIssueHook', :controller_issues_edit_before_save)
        }
      },
      additional_tags: {
        'Issue.available_tags' => -> { ::Issue.respond_to?(:available_tags) },
        'Issue#tag_list' => -> { ::Issue.method_defined?(:tag_list) },
        'AdditionalTags.setting?' => -> { defined?(::AdditionalTags) && ::AdditionalTags.respond_to?(:setting?) ? true : false }
      }
    }.freeze

    # Two plugins put tags on issues, each its own way; Tool::Tags knows both.
    # With both installed the first usable one is the one the tools talk to.
    TAG_PLUGINS = %i[redmineup_tags additional_tags].freeze

    class << self
      # Installed, and everything the tools call is there. A plugin with no
      # contract is one no tool reaches into: installed is enough.
      def usable?(id)
        return false unless Redmine::Plugin.installed?(id)

        missing(id).empty?
      end

      def tags_plugin = TAG_PLUGINS.detect { |id| usable?(id) }

      # Of what each plugin provides, by plugin id, the part no usable plugin
      # provides: a parameter two plugins share stays while either is there.
      def absent(provided)
        usable, unusable = provided.partition { |id, _names| usable?(id) }
        unusable.flat_map(&:last) - usable.flat_map(&:last)
      end

      # The names of the contract that are not there. Checked once per process:
      # a plugin does not change under a running Redmine.
      def missing(id)
        verdicts[id.to_sym] ||= begin
          absent = CONTRACTS.fetch(id.to_sym, {}).reject { |_name, present| present.call }.keys
          warn_unusable(id, absent) if absent.any?
          absent
        end
      end

      # Checks every installed plugin that has a contract, so the log line is
      # written at boot and not at the first request.
      def report
        CONTRACTS.each_key { |id| usable?(id) }
      end

      # For the tests, which install and remove stand-ins within one process.
      def reset!
        @verdicts = nil
      end

      private

      def verdicts = (@verdicts ||= {})

      def listener?(name, method)
        listener = name.safe_constantize
        listener.respond_to?(:instance) && listener.instance.respond_to?(method) ? true : false
      end

      def warn_unusable(id, absent)
        version = Redmine::Plugin.find(id).version
        Rails.logger.warn("[redmine_mcp_plugin] #{id} #{version} is installed but not usable: it has no " \
                          "#{absent.join(', ')}. Its tool, parameters and fields are not served.")
      rescue Redmine::PluginNotFound
        Rails.logger.warn("[redmine_mcp_plugin] #{id} is not usable: it has no #{absent.join(', ')}")
      end
    end
  end
end
