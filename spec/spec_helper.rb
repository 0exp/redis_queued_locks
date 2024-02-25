# frozen_string_literal: true

require 'simplecov'

SimpleCov.formatter = SimpleCov::Formatter::HTMLFormatter
SimpleCov.minimum_coverage(100)
SimpleCov.enable_coverage(:branch)
SimpleCov.enable_coverage(:line)
SimpleCov.primary_coverage(:line)
SimpleCov.enable_coverage_for_eval
SimpleCov.add_filter('spec')
SimpleCov.start

require 'redis_queued_locks'
require 'pry'

RSpec.configure do |config|
  Kernel.srand config.seed
  config.order = :random
  config.filter_run_when_matching :focus
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  Thread.abort_on_exception = true
end
