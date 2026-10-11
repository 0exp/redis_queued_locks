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

  # NOTE: (lock index) examples with the `lock_index_enabled` metadata run with this value as
  #   the default value of `config['lock_index_enabled']` (for all RQL clients created by
  #   the example: the integration spec runs with both lock lookup modes); explicitly configured
  #   values win; the library default is restored after the example;
  library_lock_index_enabled = RedisQueuedLocks::Config.new['lock_index_enabled']
  config.around do |example|
    lock_index_enabled = example.metadata[:lock_index_enabled]
    next example.run if lock_index_enabled == nil

    begin
      RedisQueuedLocks::Config.setting('lock_index_enabled', lock_index_enabled)
      example.run
    ensure
      RedisQueuedLocks::Config.setting('lock_index_enabled', library_lock_index_enabled)
    end
  end
end
