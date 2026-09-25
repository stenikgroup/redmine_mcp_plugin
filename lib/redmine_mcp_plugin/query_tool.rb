# frozen_string_literal: true

module RedmineMcpPlugin
  # Filtering, sorting, grouping and describing against a core Query subclass.
  # A module, not more helpers on Tool: only some tools are query-backed.
  module QueryTool
    # Their values are the user directory or the project list; describe names
    # the paged tool that already answers those instead of inlining them.
    USER_FILTERS    = %w[assigned_to_id author_id watcher_id updated_by last_updated_by user_id].freeze
    PROJECT_FILTERS = %w[project_id subproject_id].freeze
    MAX_VALUES      = 50

    private

    # Core drops an unknown field silently, and a dropped filter widens the
    # result, which reads to the caller exactly like an answer.
    def set_filter!(query, field, operator, values = '')
      available = query.available_filters[field]
      unless available
        raise ToolError, "Unknown filter #{field.inspect}. Call with describe: true for the ones this Redmine accepts"
      end

      legal = Query.operators_by_filter_type[available[:type]] || []
      unless legal.include?(operator)
        raise ToolError, "Operator #{operator.inspect} is not valid for #{field.inspect}. Valid: #{legal.join(', ')}"
      end

      query.add_filter(field, operator, Array(values).map(&:to_s))
    end

    def apply_explicit_filters!(query, explicit)
      explicit.each do |field, spec|
        operator, values = operator_and_values(spec)
        set_filter!(query, field.to_s, operator, values)
      end
    end

    def operator_and_values(spec)
      return ['=', Array(spec)] unless spec.is_a?(Hash)

      [spec['operator'].presence&.to_s || '=', Array(spec['values'] || '')]
    end

    def apply_sort!(query, sort, default:, saved: false)
      if sort.blank?
        # A saved query keeps the order it stores.
        query.sort_criteria = default unless saved
        return
      end

      field, direction = sort.to_s.split(':', 2)
      direction = direction.presence || 'desc'
      legal = sortable_fields(query)

      raise ToolError, "Cannot sort by #{field.inspect}. Sortable: #{legal.join(', ')}" unless legal.include?(field)
      raise ToolError, "sort direction must be asc or desc, got #{direction.inspect}" unless %w[asc desc].include?(direction)

      query.sort_criteria = [[field, direction]]
    end

    def apply_group_by!(query, group_by)
      return if group_by.blank?

      legal = groupable_fields(query)
      raise ToolError, "Cannot group by #{group_by.inspect}. Groupable: #{legal.join(', ')}" unless legal.include?(group_by.to_s)

      query.group_by = group_by.to_s
    end

    def sortable_fields(query)
      query.sortable_columns.select { |_name, sortable| sortable.present? }.keys.sort
    end

    def groupable_fields(query)
      query.groupable_columns.map { |column| column.name.to_s }.sort
    end

    # --- grouped results ----------------------------------------------------

    # Core keys grouped results by the group's own object and labels them with
    # a view helper a tool cannot reach, so name them here.
    def group_rows(counts, totals = nil)
      Array(counts).map do |value, count|
        row = { group: group_label(value), count: count }
        row[:total_hours] = totals[value] if totals
        row
      end
    end

    def group_label(value)
      case value
      when nil then { id: nil, label: '(none)' }
      # Same rule as core: the id always, the subject only when visible.
      when Issue then { id: value.id, label: value.visible?(user) ? "##{value.id} #{value.subject}" : "##{value.id}" }
      when ActiveRecord::Base then { id: value.id, label: value.respond_to?(:name) ? value.name : value.to_s }
      else { id: nil, label: value.to_s }
      end
    end

    # --- describe -----------------------------------------------------------

    def describe(query)
      {
        filters: query.available_filters.map { |field, filter| describe_filter(field, filter) },
        sortable: sortable_fields(query),
        groupable: groupable_fields(query)
      }
    end

    def describe_filter(field, filter)
      entry = { field: field, name: filter[:name], type: filter[:type].to_s,
                operators: Query.operators_by_filter_type[filter[:type]] || [] }

      # Returning early also skips evaluating the values lambda, a query each.
      return entry.merge(values: nil, note: 'Ids come from list_users.')    if user_valued?(field, filter)
      return entry.merge(values: nil, note: 'Ids come from list_projects.') if PROJECT_FILTERS.include?(field)

      values = Array(filter[:values])
      return entry if values.empty?

      entry.merge(values: values.first(MAX_VALUES).map { |value| labelled(value) },
                  values_truncated: values.size > MAX_VALUES)
    end

    def user_valued?(field, filter)
      USER_FILTERS.include?(field) || filter[:field]&.field_format == 'user'
    end

    # A filter's values are plain strings, or [label, value] pairs.
    def labelled(value)
      label, stored = value.is_a?(Array) ? value : [value, value]
      { value: stored.to_s, label: label.to_s }
    end

    def iso_date(value, name)
      Date.iso8601(value.to_s).iso8601
    rescue ArgumentError
      raise ToolError, "#{name} must be an ISO-8601 date, got #{value.inspect}"
    end
  end
end
