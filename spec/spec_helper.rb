# frozen_string_literal: true

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
