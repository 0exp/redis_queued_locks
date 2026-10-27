# frozen_string_literal: true

require_relative 'setup_simplecov'

# NOTE: (parallel specs) `rake rspec:parallel` (`spec/support/parallel_runner.rb`):
#   - each worker only stores its coverage result in its own directory (no shared resultset, no
#     report): the task collates the report of the whole run after all workers
#     (`SimpleCov.collate`);
#   - the example listing (`--dry-run`) collects no coverage;
if ENV.key?('RQL_SPEC_WORKER')
  SimpleCov.command_name("rspec:worker:#{ENV.fetch('RQL_SPEC_WORKER')}")
  SimpleCov.coverage_dir("coverage/parallel/worker-#{ENV.fetch('RQL_SPEC_WORKER')}")
  SimpleCov.at_exit { SimpleCov.result }
end
SimpleCov.start unless ENV.key?('RQL_SPEC_LISTING')

require 'rspec/retry'
require 'pry'
require 'redis_queued_locks'

# NOTE: (parallel specs) each worker of `rake rspec:parallel` works with its own Redis databases:
#   the offset is added to the database number of every Redis client (the specs, the library and
#   the swarm elements, the flusher Ractor too: all of them are configured with
#   `RedisClient.config`), so the `FLUSHDB` hooks, SCAN passes and swarm keys of the workers never
#   meet; `0` (the default): the databases of the specs as is;
#   - the offset is prepended to `RedisClient::Config::Common#initialize`: `Config#initialize`
#     calls it with the resolved database (the `db:` option or the database of the `url:`), so
#     a database of a URL gets the offset too (not the default one);
RQL_SPEC_DB_OFFSET = Integer(ENV.fetch('RQL_SPEC_DB_OFFSET', '0'))
unless RQL_SPEC_DB_OFFSET.zero?
  RedisClient::Config::Common.prepend(Module.new do
    def initialize(db: nil, **)
      super(db: Integer(db || 0) + RQL_SPEC_DB_OFFSET, **)
    end
  end)
end

# NOTE: (RBS) true under the RBS runtime type checks (`-rrbs/test/setup`, typecheck-runtime CI):
#   expectations that pass type-invalid values on purpose are skipped there (the hooks raise first).
RBS_RUNTIME_TEST = ENV.key?('RBS_TEST_TARGET')

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
