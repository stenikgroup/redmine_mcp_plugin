# frozen_string_literal: true

# Line coverage of the plugin, from the report Redmine's test helper writes
# when the suite runs with COVERAGE=1. From the Redmine root:
#
#   COVERAGE=1 bin/rails redmine:plugins:test NAME=redmine_mcp_plugin
#   ruby plugins/redmine_mcp_plugin/test/coverage.rb 95
#
# Lists every file that is not fully covered, then the total. With a minimum,
# exits 1 when the total is below it.
#
# Redmine's own report covers the whole application, where the plugin is a few
# percent of the lines; this keeps to the plugin's app/ and lib/.

require 'json'

report  = File.expand_path(ARGV[1] || 'coverage/.resultset.json')
minimum = ARGV[0]&.to_f
abort "No coverage report at #{report}; run the suite with COVERAGE=1 first" unless File.exist?(report)

marker = 'plugins/redmine_mcp_plugin/'
merged = Hash.new { |files, path| files[path] = [] }

# One entry per test run; a line counts as covered when any run reached it.
JSON.parse(File.read(report)).each_value do |run|
  run['coverage'].each do |path, data|
    next unless path.include?(marker)

    relative = path.split(marker, 2).last
    next unless relative.start_with?('app/', 'lib/', 'init.rb')

    lines = data.is_a?(Hash) ? data['lines'] : data
    lines.each_with_index do |hits, index|
      next if hits.nil?

      merged[relative][index] = merged[relative][index].to_i + hits
    end
  end
end

abort "The report at #{report} has no file of the plugin" if merged.empty?

rows = merged.map do |path, lines|
  relevant = lines.compact
  { path: path, relevant: relevant.size, covered: relevant.count(&:positive?) }
end

rows.select { |row| row[:covered] < row[:relevant] }
    .sort_by { |row| row[:covered].fdiv(row[:relevant]) }
    .each do |row|
  puts format('%<percent>5.1f%%  %<missed>4d missed  %<path>s',
              percent: 100.0 * row[:covered] / row[:relevant], missed: row[:relevant] - row[:covered], path: row[:path])
end

relevant = rows.sum { |row| row[:relevant] }
covered  = rows.sum { |row| row[:covered] }
total    = 100.0 * covered / relevant
puts format('Total: %<covered>d of %<relevant>d lines, %<total>.1f%% (%<files>d files)',
            covered: covered, relevant: relevant, total: total, files: rows.size)

if minimum && total < minimum
  warn format('Coverage %<total>.1f%% is below the minimum of %<minimum>.1f%%', total: total, minimum: minimum)
  exit 1
end
