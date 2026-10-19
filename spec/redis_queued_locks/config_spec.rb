# frozen_string_literal: true

# NOTE: Redis-free spec: keeps the typed `Config#[]` overload table
#   (sig/redis_queued_locks/config.rbs) in sync with the `setting` registry of the config.
RSpec.describe RedisQueuedLocks::Config do
  specify 'every config key has exactly one typed `[]` overload in RBS and vice versa' do
    config_rbs = File.read(File.expand_path('../../sig/redis_queued_locks/config.rbs', __dir__))
    overload_table = config_rbs[/def \[\]:(.*?)^\s*def \[\]=/m, 1]
    rbs_keys = overload_table.scan(/\("([^"]+)"\)/).flatten
    setting_keys = described_class.config_setters.keys

    aggregate_failures 'overload table == setting registry' do
      expect(rbs_keys).to match_array(setting_keys)
      expect(rbs_keys.size).to eq(rbs_keys.uniq.size)
    end
  end
end
