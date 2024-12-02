# frozen_string_literal: true

require_relative 'setup_simplecov'

SimpleCov.start

require 'rspec/retry'
require 'pry'
require 'redis_queued_locks'

RSpec.configure do |config|
  # NOTE: (github-ci) (rspec-retry) temporary decision for non-refactored tests
  config.verbose_retry = true # (rspec-retry)
  config.display_try_failure_messages = true # (rspec-retry)
  config.default_retry_count = 5 # (rsec-retry)

  Kernel.srand config.seed
  config.order = :random
  config.filter_run_when_matching :focus
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  Thread.abort_on_exception = true
end
