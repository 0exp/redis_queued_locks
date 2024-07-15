# frozen_string_literal: true

# NOTE:
#   - these specs will be totally reworked;
#   - this code is not ideal and final,
#     it is written only for behavior testing and funcionality checking;
RSpec.describe RedisQueuedLocks do
  let(:redis) { RedisClient.config(db: 0).new_pool(timeout: 5, size: 50) }

  before do
    redis.call('FLUSHDB')
    # drop immediatly cuz flsuhdb can be async
    redis.call('DEL', RedisQueuedLocks::Resource::SWARM_KEY)
    RedisQueuedLocks.enable_debugger!
  end

  after do
    # drop immediatly cuz flsuhdb can be async
    redis.call('DEL', RedisQueuedLocks::Resource::SWARM_KEY)
    redis.call('FLUSHDB')
  end

  describe 'swarm' do
    specify '#current_host_id, #possible_host_ids' do
      client = RedisQueuedLocks::Client.new(redis)

      uniq_identity = client.uniq_identity
      current_thread_list = ::Thread.list
      current_process_id = ::Process.pid
      current_thread_id = ::Thread.current.object_id
      current_ractor_id = ::Ractor.current.object_id

      # verify current host
      expect(client.current_host_id).to eq(
        "rql:hst:#{current_process_id}/#{current_thread_id}/#{current_ractor_id}/#{uniq_identity}"
      )

      # collect possible hosts
      expected_hosts = current_thread_list.map do |thread|
        "rql:hst:#{current_process_id}/#{thread.object_id}/#{current_ractor_id}/#{uniq_identity}"
      end
      expect(client.possible_host_ids).to contain_exactly(*expected_hosts)

      # add new possible hosts and make sure that these hosts are showing via possible_host_ids
      new_thread1 = Thread.new { loop { sleep(0.5) } }
      new_thread2 = Thread.new { loop { sleep(0.5) } }
      # rubocop:disable Layout/LineLength
      new_thread1_host_id =
        "rql:hst:#{current_process_id}/#{new_thread1.object_id}/#{current_ractor_id}/#{uniq_identity}"
      new_thread2_host_id =
        "rql:hst:#{current_process_id}/#{new_thread2.object_id}/#{current_ractor_id}/#{uniq_identity}"
      # rubocop:enable Layout/LineLength

      expected_hosts << new_thread1_host_id
      expected_hosts << new_thread2_host_id
      expect(client.possible_host_ids).to contain_exactly(*expected_hosts)

      # drop new created hosts and make sure that these hosts are not showing via possible_host_ids
      new_thread1.tap(&:kill).tap(&:join)
      new_thread2.tap(&:kill).tap(&:join)
      new_current_thread_list = Thread.list
      expected_hosts = new_current_thread_list.map do |thread|
        "rql:hst:#{current_process_id}/#{thread.object_id}/#{current_ractor_id}/#{uniq_identity}"
      end
      last_possible_host_ids = client.possible_host_ids
      expect(last_possible_host_ids).to contain_exactly(*expected_hosts)
      expect(last_possible_host_ids).not_to include(new_thread1_host_id)
      expect(last_possible_host_ids).not_to include(new_thread2_host_id)
    end

    specify 'supervisor keeps the swarm elements up and running' do
      client = RedisQueuedLocks::Client.new(redis) do |conf|
        conf.swarm.auto_swarm = true
        conf.swarm.supervisor.liveness_probing_period = 4
        conf.swarm.probe_hosts.probe_period = 2
      end

      # kill swarm elements. supervisor should up them soon.
      client.swarm.flush_zombies_element.try_kill!
      sleep(0.5) # give a timespot to termiane all async elements
      client.swarm.probe_hosts_element.try_kill!
      sleep(0.5) # give a timespot to termiane all async elements

      # check that killed elements are truely dead
      expect(client.swarm_status).to match({
        auto_swarm: true,
        supervisor: match({
          running: true,
          state: eq('sleep').or(eq('run')),
          observable: 'initialized'
        }),
        probe_hosts: match({
          enabled: true,
          thread: match({ running: false, state: 'dead' }),
          main_loop: match({ running: false, state: 'non_initialized' })
        }),
        flush_zombies: match({
          enabled: true,
          ractor: match({ running: false, state: 'terminated' }),
          main_loop: match({ running: false, state: 'non_initialized' })
        })
      })

      # sleep supervisor probing time
      #   + some time for up the killed elements
      #   + time to probe hosts period
      #   + time to probe hosts activity ;)
      sleep(4 + 1 + 2 + 1)

      # # check that elements are running
      expect(client.swarm_status).to match({
        auto_swarm: true,
        supervisor: match({
          running: true,
          state: eq('sleep').or(eq('run')),
          observable: 'initialized'
        }),
        probe_hosts: match({
          enabled: true,
          thread: match({ running: true, state: eq('sleep').or(eq('run')) }),
          main_loop: match({ running: true, state: eq('sleep').or(eq('run')) })
        }),
        flush_zombies: match({
          enabled: true,
          ractor: match({ running: true, state: 'running' }),
          main_loop: match({ running: true, state: eq('sleep').or(eq('run')) })
        })
      })
    end

    specify 'swarm_status / swarm_info' do
      aggregate_failures 'non-auto-swarmed => swarm is not initialized' do
        client = RedisQueuedLocks::Client.new(redis) do |conf|
          conf.swarm.auto_swarm = false
          conf.swarm.probe_hosts.enabled_for_swarm = false
          conf.swarm.flush_zombies.enabled_for_swarm = false
        end

        expect(client.swarm_info).to match({})
        expect(client.swarm_status).to match({
          auto_swarm: false,
          supervisor: match({
            running: false,
            state: 'non_initialized',
            observable: 'non_initialized'
          }),
          probe_hosts: match({
            enabled: false,
            thread: match({
              running: false,
              state: 'non_initialized'
            }),
            main_loop: match({
              running: false,
              state: 'non_initialized'
            })
          }),
          flush_zombies: match({
            enabled: false,
            ractor: match({
              running: false,
              state: 'non_initialized'
            }),
            main_loop: match({
              running: false,
              state: 'non_initialized'
            })
          })
        })
      end

      aggregate_failures 'default state: no autoswarm with enabled elements' do
        client = RedisQueuedLocks::Client.new(redis)
        expect(client.swarm_info).to match({})
        expect(client.swarm_status).to match({
          auto_swarm: false,
          supervisor: match({
            running: false,
            state: 'non_initialized',
            observable: 'non_initialized'
          }),
          probe_hosts: match({
            enabled: true,
            thread: match({
              running: false,
              state: 'non_initialized'
            }),
            main_loop: match({
              running: false,
              state: 'non_initialized'
            })
          }),
          flush_zombies: match({
            enabled: true,
            ractor: match({
              running: false,
              state: 'non_initialized'
            }),
            main_loop: match({
              running: false,
              state: 'non_initialized'
            })
          })
        })
      end

      aggregate_failures 'swarmed => swarm info => probes and zombie status' do
        client = RedisQueuedLocks::Client.new(redis) do |config|
          config.swarm.auto_swarm = true
          config.swarm.probe_hosts.probe_period = 3
          config.swarm.probe_hosts.enabled_for_swarm = true
          config.swarm.flush_zombies.enabled_for_swarm = true
        end

        expect(client.swarm_status).to match({
          auto_swarm: true,
          supervisor: match({
            running: true,
            state: eq('sleep').or(eq('run')),
            observable: 'initialized'
          }),
          probe_hosts: match({
            enabled: true,
            thread: match({ running: true, state: eq('sleep').or(eq('run')) }),
            main_loop: match({ running: true, state: eq('sleep').or(eq('run')) })
          }),
          flush_zombies: match({
            enabled: true,
            ractor: match({ running: true, state: 'running' }),
            main_loop: match({ running: true, state: eq('sleep').or(eq('run')) })
          })
        })

        sleep(4) # NOTE: wait for host probing

        swarm_info = client.possible_host_ids.each_with_object({}) do |host_id, memo|
          memo[host_id] = match({
            zombie: false,
            last_probe_time: be_a(Time),
            last_probe_score: be_a(Numeric)
          })
        end
        expect(client.swarm_info).to match(hash_including(swarm_info))

        # try to kill the swarm and get the corresponding swarm state
        result = client.deswarmize!
        expect(result).to eq({ ok: true, result: :terminating })
        sleep(1) # give a time to terminate async objects

        expect(client.swarm_status).to match({
          auto_swarm: true,
          supervisor: match({
            running: false,
            state: 'non_initialized',
            observable: 'non_initialized'
          }),
          probe_hosts: match({
            enabled: true,
            thread: match({ running: false, state: 'dead' }),
            main_loop: match({ running: false, state: 'non_initialized' })
          }),
          flush_zombies: match({
            enabled: true,
            ractor: match({ running: false, state: 'terminated' }),
            main_loop: match({ running: false, state: 'non_initialized' })
          })
        })
      end
    end

    specify 'manual host probing (with statuses)' do
      client = RedisQueuedLocks::Client.new(redis) do |conf|
        conf.swarm.auto_swarm = false
        conf.swarm.flush_zombies.zombie_ttl = 4_000
      end

      # No probes at start
      expect(client.swarm_info).to eq({})

      client.probe_hosts

      # probes after start
      expect(client.swarm_info).to match(hash_including({
        client.current_host_id => match({
          zombie: false,
          last_probe_time: be_a(Time),
          last_probe_score: be_a(Numeric)
        })
      }))

      sleep(4)

      # old probes => zombie probes
      expect(client.swarm_info).to match(hash_including({
        client.current_host_id => match({
          zombie: true,
          last_probe_time: be_a(Time),
          last_probe_score: be_a(Numeric)
        })
      }))

      old_probes = client.swarm_info
      client.probe_hosts # probe again

      # fresh probe => non-zombie probe :)
      expect(client.swarm_info).to match(hash_including({
        client.current_host_id => match({
          zombie: false,
          last_probe_time: be_a(Time),
          last_probe_score: be_a(Numeric)
        })
      }))

      new_probes = client.swarm_info

      # new fresh probes is greater than old (new last probe time, new last probe score)
      expect(new_probes[client.current_host_id][:last_probe_time]).to(satisfy do |val|
        val > old_probes[client.current_host_id][:last_probe_time]
      end)
      expect(new_probes[client.current_host_id][:last_probe_score]).to(satisfy do |val|
        val > old_probes[client.current_host_id][:last_probe_score]
      end)
    end

    specify 'manual zombie flushing (with statuses)' do
      client = RedisQueuedLocks::Client.new(redis) do |conf|
        conf.swarm.auto_swarm = false
        # NOTE: we will manually probe hosts and flush zombies
        conf.swarm.probe_hosts.enabled_for_swarm = false
        conf.swarm.flush_zombies.enabled_for_swarm = false
        conf.swarm.flush_zombies.zombie_ttl = 4_000
      end

      # create a zombie lock
      client.lock('super-mega-long-lock', ttl: 500_000)
      # probe hosts => made some info about the swarm
      client.probe_hosts
      expect(client.swarm_info).to match(hash_including({
        client.current_host_id => match({
          zombie: false,
          last_probe_time: be_a(Time),
          last_probe_score: be_a(Numeric)
        })
      }))
      # sleep the zombie ttl a stop host probing
      sleep(4)

      # now we have one guaranteed zombie
      expect(client.swarm_info).to match(hash_including({
        client.current_host_id => match({
          zombie: true,
          last_probe_time: be_a(Time),
          last_probe_score: be_a(Numeric)
        })
      }))

      zombie_host = client.current_host_id
      zombie_acquier = client.current_acquier_id
      zombie_lock = 'rql:lock:super-mega-long-lock'

      expect(client.locked?('super-mega-long-lock')).to eq(true)
      expect(client.zombie_locks).to include(zombie_lock)
      expect(client.zombie_acquiers).to include(zombie_acquier)
      expect(client.zombie_hosts).to include(zombie_host)

      # try to flush them all
      aggregate_failures 'flush zombies' do
        result = client.flush_zombies
        expect(result).to match({
          ok: true,
          deleted_zombie_hosts: include(zombie_host),
          deleted_zombie_acquiers: include(zombie_acquier),
          deleted_zombie_locks: include(zombie_lock)
        })
        expect(client.locked?('super-mega-long-lock')).to eq(false)
        expect(client.zombie_locks).to eq(Set.new)
        expect(client.zombie_acquiers).not_to include(zombie_acquier)
        expect(client.zombie_hosts).not_to include(zombie_host)
      end
    end

    specify '(auto-swarming!): zombie locks (with hosts and acquiers)' do
      main_client = RedisQueuedLocks::Client.new(redis) do |conf|
        conf.swarm.auto_swarm = true
        conf.swarm.probe_hosts.enabled_for_swarm = true
        conf.swarm.flush_zombies.enabled_for_swarm = false
        conf.swarm.flush_zombies.zombie_ttl = 6_000
        conf.swarm.flush_zombies.zombie_flush_period = 5
      end

      aggregate_failures 'no zombies at start' do
        expect(main_client.zombie_locks).to eq(Set.new) # empty set
        expect(main_client.zombie_hosts).to eq(Set.new) # empty set
        expect(main_client.zombie_acquiers).to eq(Set.new) # empty set

        expect(main_client.zombies_info).to match({
          zombie_locks: Set.new,
          zombie_hosts: Set.new,
          zombie_acquirers: Set.new
        })
        expect(main_client.zombies).to match({
          zombie_locks: Set.new,
          zombie_hosts: Set.new,
          zombie_acquirers: Set.new
        })
      end

      outer_acquirer1 = nil
      outer_host1 = nil
      outer_acquirer2 = nil
      outer_host2 = nil

      outer_thread1 = Thread.new do
        client = RedisQueuedLocks::Client.new(redis) do |conf|
          conf.swarm.auto_swarm = true
          conf.swarm.probe_hosts.enabled_for_swarm = true
          conf.swarm.flush_zombies.enabled_for_swarm = false
        end

        outer_acquirer1 = client.current_acquier_id
        outer_host1 = client.current_host_id

        client.swarmize!
        client.lock('long_lock', ttl: 500_000)
      end

      outer_thread2 = Thread.new do
        client = RedisQueuedLocks::Client.new(redis) do |conf|
          conf.swarm.auto_swarm = true
          conf.swarm.probe_hosts.enabled_for_swarm = true
          conf.swarm.flush_zombies.enabled_for_swarm = false
        end

        outer_acquirer2 = client.current_acquier_id
        outer_host2 = client.current_host_id

        client.swarmize!
        client.lock('another_long_lock', ttl: 500_000)
      end
      until main_client.locked?('long_lock'); end
      outer_thread1.kill
      # long_lock now is a zombie lock cuz the holding thread is dead and
      # does not work/host the lock anymore

      until main_client.locked?('another_long_lock'); end
      outer_thread2.kill
      # lanother_ong_lock now is a zombie lock cuz the holding thread is dead and
      # does not work/host the lock anymore

      # NOTE: zombie TTL is not reached yet
      aggregate_failures 'no zombies before the zombie ttl' do
        expect(main_client.locked?('long_lock')).to eq(true)
        expect(main_client.locked?('another_long_lock')).to eq(true)
        expect(main_client.zombie_locks).to eq(Set.new) # empty set
        expect(main_client.zombie_hosts).to eq(Set.new) # empty set
        expect(main_client.zombie_acquiers).to eq(Set.new) # empty set

        expect(main_client.zombies_info).to match({
          zombie_locks: Set.new,
          zombie_hosts: Set.new,
          zombie_acquirers: Set.new
        })
        expect(main_client.zombies).to match({
          zombie_locks: Set.new,
          zombie_hosts: Set.new,
          zombie_acquirers: Set.new
        })
      end

      sleep(6) # wait for zombie ttl
      # NOTE: zombie ttl is reached!

      aggregate_failures 'dead lock hosting threads => zombie ttl is reached => zombies!' do
        # ZOMBIE LOCKS
        expect(main_client.locked?('long_lock')).to eq(true)
        expect(main_client.locked?('another_long_lock')).to eq(true)

        # ZOMBIE LOCKS
        expect(main_client.zombie_locks).to eq(
          Set.new(%w[rql:lock:long_lock rql:lock:another_long_lock])
        )

        # ZOMBIE LOCK HOSTS AND ACQUIRERS
        expect(main_client.zombie_hosts).to include(outer_host1, outer_host2)
        expect(main_client.zombie_acquiers).to include(outer_acquirer1, outer_acquirer2)

        expect(main_client.zombies_info).to match({
          zombie_locks: Set.new(%w[rql:lock:long_lock rql:lock:another_long_lock]),
          zombie_hosts: include(outer_host1, outer_host2),
          zombie_acquirers: include(outer_acquirer1, outer_acquirer2)
        })
        expect(main_client.zombies).to match({
          zombie_locks: Set.new(%w[rql:lock:long_lock rql:lock:another_long_lock]),
          zombie_hosts: include(outer_host1, outer_host2),
          zombie_acquirers: include(outer_acquirer1, outer_acquirer2)
        })
      end

      # KILL ZOMBIES by the SWARM: enable zombie flusher
      main_client.configure do |config|
        config.swarm.flush_zombies.enabled_for_swarm = true # enable zombie flusher
      end
      sleep(2 + 5) # wait for supervisor probe period (up zombie flusher) + zombie flush period
      sleep(1) # wait for zombie killing

      aggregate_failures 'zombies should be fully flushed' do
        expect(main_client.locked?('long_lock')).to eq(false) # lock is unlocked
        expect(main_client.locked?('another_long_lock')).to eq(false) # lock is unlocked
        expect(main_client.zombie_locks).to eq(Set.new) # no zombie locks
        expect(main_client.zombie_hosts).to eq(Set.new) # no zombie hosts
        expect(main_client.zombie_acquiers).to eq(Set.new) # no zombie acquiers
      end
    end
  end

  specify ':random access strategy' do
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.default_access_strategy = :random
    end

    client.lock('random.access.strategy', ttl: 2_000, meta: { 'trd' => 0 })

    Thread.new do
      client.lock('random.access.strategy', retry_delay: 7_000, ttl: 4_000, meta: { 'trd' => 1 })
    end

    Thread.new do
      client.lock('random.access.strategy', retry_delay: 3_000, ttl: 3_000, meta: { 'trd' => 2 })
    end

    # NOTE:
    #   lock queue: trd0->trd1->trd2
    #   expected access (cuz it is random): trd-0 => trd-2 => trd-1 (trd2 should be next, not trd1)

    expect(client.lock_info('random.access.strategy')['trd']).to eq('0')
    sleep(4)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('2')
    sleep(4)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('1')
  end

  specify ':random access strategy (manually defined)' do
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.default_access_strategy = :queued
    end

    client.lock(
      'random.access.strategy',
      ttl: 2_000,
      meta: { 'trd' => 0 },
      access_strategy: :random
    )

    Thread.new do
      client.lock(
        'random.access.strategy',
        retry_delay: 7_000,
        ttl: 4_000,
        meta: { 'trd' => 1 },
        access_strategy: :random
      )
    end

    Thread.new do
      client.lock(
        'random.access.strategy',
        retry_delay: 3_000,
        ttl: 3_000,
        meta: { 'trd' => 2 },
        access_strategy: :random
      )
    end

    # NOTE:
    #   lock queue: trd0->trd1->trd2
    #   expected access (cuz it is random): trd-0 => trd-2 => trd-1 (trd2 should be next, not trd1)

    expect(client.lock_info('random.access.strategy')['trd']).to eq('0')
    sleep(4)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('2')
    sleep(4)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('1')
  end

  specify ':queued access strategy' do
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.default_access_strategy = :queued
    end

    client.lock(
      'random.access.strategy',
      ttl: 2_000,
      meta: { 'trd' => 0 }
    )

    Thread.new do
      client.lock(
        'random.access.strategy',
        retry_delay: 7_000,
        ttl: 2_000,
        meta: { 'trd' => 1 }
      )
    end

    Thread.new do
      client.lock(
        'random.access.strategy',
        retry_count: 5,
        retry_delay: 3_000,
        ttl: 3_000,
        meta: { 'trd' => 2 }
      )
    end

    # NOTE:
    #   lock queue: trd0->trd1->trd2
    #   expected access (cuz it is queued): trd-0 => trd-1 => trd-2

    expect(client.lock_info('random.access.strategy')['trd']).to eq('0')
    sleep(8)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('1')
    sleep(3)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('2')
  end

  specify ':queued access strategy (manually defined)' do
    client = RedisQueuedLocks::Client.new(redis)

    client.lock(
      'random.access.strategy',
      ttl: 2_000,
      meta: { 'trd' => 0 },
      access_strategy: :queued
    )

    Thread.new do
      client.lock(
        'random.access.strategy',
        retry_delay: 7_000,
        ttl: 2_000,
        meta: { 'trd' => 1 },
        access_strategy: :queued
      )
    end

    Thread.new do
      client.lock(
        'random.access.strategy',
        retry_count: 5,
        retry_delay: 3_000,
        ttl: 3_000,
        meta: { 'trd' => 2 },
        access_strategy: :queued
      )
    end

    # NOTE:
    #   lock queue: trd0->trd1->trd2
    #   expected access (cuz it is queued): trd-0 => trd-1 => trd-2

    expect(client.lock_info('random.access.strategy')['trd']).to eq('0')
    sleep(8)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('1')
    sleep(3)
    expect(client.lock_info('random.access.strategy')['trd']).to eq('2')
  end

  specify 'instrumentation sampling' do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end

    # NOTE: enabled sampling
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.instr_sampling_enabled = true
      conf.instr_sampling_percent = 10
    end

    100.times do
      sampled_notifications = Array.new(100) do
        sampled_notifier = test_notifier.new
        client.lock('instr_sampling_check', instrumenter: sampled_notifier) {}
        sampled_notifier.notifications
      end

      instrumented_cases = sampled_notifications.select(&:any?)
      expect(instrumented_cases.size < 40).to eq(true)
      expect(instrumented_cases.size > 1).to eq(true)
    end

    # NOTE: disabled sampling
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.instr_sampling_enabled = false
    end

    sampled_notifications = Array.new(100) do
      sampled_notifier = test_notifier.new
      client.lock('instr_sampling_check', instrumenter: sampled_notifier) {}
      sampled_notifier.notifications
    end

    instrumented_cases = sampled_notifications.select(&:any?)
    expect(instrumented_cases.size).to eq(100)

    # NOTE: sampling ignorance
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.instr_sampling_enabled = true
    end

    sampled_notifications = Array.new(100) do
      sampled_notifier = test_notifier.new
      client.lock(
        'instr_sampling_check',
        instrumenter: sampled_notifier,
        instr_sample_this: true
      ) {}
      sampled_notifier.notifications
    end

    instrumented_cases = sampled_notifications.select(&:any?)
    expect(instrumented_cases.size).to eq(100)
  end

  specify 'log sampling' do
    test_logger_klass = Class.new do
      attr_reader :logs

      def initialize
        @logs = []
      end

      def debug(progname = nil, &block)
        logs << "#{progname} : #{yield if block_given?}"
      end
    end

    # NOTE: enabled sampling
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.log_lock_try = true
      conf.log_sampling_enabled = true
      conf.log_sampling_percent = 10
    end

    100.times do
      sampled_logs = Array.new(100) do
        sampled_logger = test_logger_klass.new
        client.lock('log_sampling_check', logger: sampled_logger) {}
        sampled_logger.logs
      end

      logged_cases = sampled_logs.select(&:any?)
      expect(logged_cases.size < 40).to eq(true)
      expect(logged_cases.size > 1).to eq(true)
    end

    # NOTE: disabled sampling
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.log_lock_try = true
      conf.log_sampling_enabled = false
      conf.log_sampling_percent = 15
    end

    sampled_logs = Array.new(100) do
      sampled_logger = test_logger_klass.new
      client.lock('log_sampling_check', logger: sampled_logger) {}
      sampled_logger.logs
    end

    logged_cases = sampled_logs.select(&:any?)
    expect(logged_cases.size).to eq(100)

    # NOTE: ignored sampling
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.log_lock_try = true
      conf.log_sampling_enabled = true
      conf.log_sampling_percent = 15
    end

    sampled_logs = Array.new(100) do
      sampled_logger = test_logger_klass.new
      client.lock('log_sampling_check', logger: sampled_logger, log_sample_this: true) {}
      sampled_logger.logs
    end

    logged_cases = sampled_logs.select(&:any?)
    expect(logged_cases.size).to eq(100)
  end

  specify 'reentrant locks - :extendable_work_trhough' do
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config.default_conflict_strategy = :extendable_work_through
      config.log_lock_try = true
      config.logger = Logger.new(STDOUT)
    end
    # Current Lock TTL: 5000
    result1 = client.lock('pek', ttl: 5000)
    lock_state1 = client.lock_info('pek')
    # Current Lock TTL: 10_000
    result2 = client.lock('pek', ttl: 5000) # NOTE: <reentrant lock> extension!
    lock_state2 = client.lock_info('pek')

    expect(result1).to match({
      ok: true,
      result: match({
        lock_key: eq('rql:lock:pek'),
        acq_id: be_a(String),
        hst_id: be_a(String),
        ts: be_a(Float),
        ttl: eq(5000),
        process: eq(:lock_obtaining)
      })
    })
    expect(lock_state1.keys).to contain_exactly(
      'acq_id', 'hst_id', 'ts', 'ini_ttl', 'lock_key', 'rem_ttl'
    )
    expect(lock_state1).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(5000),
      'lock_key' => eq('rql:lock:pek'),
      'rem_ttl' => be_a(Integer)
    })

    expect(result2).to match({
      ok: true,
      result: match({
        lock_key: eq('rql:lock:pek'),
        acq_id: be_a(String),
        hst_id: be_a(String),
        ts: be_a(Float),
        ttl: eq(5000),
        process: eq(:extendable_conflict_work_through)
      })
    })
    expect(lock_state2.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'lock_key',
      'rem_ttl',
      'spc_ext_ttl',
      'spc_cnt',
      'l_spc_ext_ts',
      'l_spc_ext_ini_ttl'
    )
    expect(lock_state2).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ini_ttl' => eq(5000),
      'ts' => be_a(Float),
      'spc_ext_ttl' => eq(5000), # NOTE: the sum of added TTL of the all reenters
      'spc_cnt' => eq(1), # NOTE: reenter count
      'l_spc_ext_ts' => be_a(Float), # NOTE: the last extension time
      'l_spc_ext_ini_ttl' => eq(5000), # NOTE: the ttl attribute of the last extension time
      'lock_key' => eq('rql:lock:pek'),
      'rem_ttl' => be_a(Integer)
    })
    # NOTE: new remaing ttl should be greater than initial)
    expect(lock_state2['rem_ttl'] > 9000).to eq(true)

    # Current Lock TTL: 14_500
    result3 = client.lock('pek', ttl: 4500) # NOTE: reenter (extend) again!
    lock_state3 = client.lock_info('pek')
    expect(result3).to match({
      ok: true,
      result: match({
        lock_key: eq('rql:lock:pek'),
        acq_id: be_a(String),
        hst_id: be_a(String),
        ts: be_a(Float),
        ttl: eq(4500),
        process: eq(:extendable_conflict_work_through)
      })
    })
    expect(lock_state3.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'lock_key',
      'rem_ttl',
      'spc_ext_ttl',
      'spc_cnt',
      'l_spc_ext_ts',
      'l_spc_ext_ini_ttl'
    )
    expect(lock_state3).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ini_ttl' => eq(5000),
      'ts' => be_a(Float),
      'spc_ext_ttl' => eq(9500), # NOTE: the sum of added TTL of the all reenters
      'spc_cnt' => eq(2), # NOTE: reenter count (two times at this moment)
      'l_spc_ext_ts' => be_a(Float), # NOTE: the last extension time
      'l_spc_ext_ini_ttl' => eq(4500), # NOTE: the ttl attribute of the last extension time
      'lock_key' => eq('rql:lock:pek'),
      'rem_ttl' => be_a(Integer)
    })
    # NOTE: new remaing ttl should be greater than initial)
    expect(lock_state3['rem_ttl'] > 13_000).to eq(true)

    # Current Lock TTL: 19_000
    client.lock('pek', ttl: 5500) { sleep(0.5) }
    # But npw: ~ 14_500 (is> 14_000 and<)
    # NOTE: the reentrant lock should not be released after the block execution
    expect(client.locked?('pek')).to eq(true)
    lock_state4 = client.lock_info('pek')
    expect(lock_state4).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ini_ttl' => eq(5000),
      'ts' => be_a(Float),
      'spc_ext_ttl' => eq(15_000), # NOTE: the sum of added TTL of the all reenters
      'spc_cnt' => eq(3), # NOTE: reenter count (two times at this moment)
      'l_spc_ext_ts' => be_a(Float), # NOTE: the last extension time
      'l_spc_ext_ini_ttl' => eq(5500), # NOTE: the ttl attribute of the last extension time
      'lock_key' => eq('rql:lock:pek'),
      'rem_ttl' => be_a(Integer)
    })
    expect(client.lock_info('pek')['rem_ttl'] > 14_000).to eq(true)

    # CHECK: SPC count should change with another conflict strategy too
    result5 = client.lock('pek', ttl: 5500, conflict_strategy: :work_through)
    expect(result5[:ok]).to eq(true)
    expect(result5[:result][:process]).to eq(:conflict_work_through)
    expect(result5[:result]).to match({
      lock_key: eq('rql:lock:pek'),
      acq_id: be_a(String),
      hst_id: be_a(String),
      ts: be_a(Float),
      ttl: eq(5_500),
      process: :conflict_work_through
    })
    lock_state5 = client.lock_info('pek')
    expect(lock_state5.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'spc_ext_ttl',
      'spc_cnt',
      'l_spc_ext_ts',
      'l_spc_ext_ini_ttl',
      'l_spc_ts',
      'lock_key',
      'rem_ttl'
    )
    expect(lock_state5).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(5000),
      'spc_ext_ttl' => eq(15_000),
      'spc_cnt' => eq(4),
      'l_spc_ext_ts' => be_a(Float),
      'l_spc_ext_ini_ttl' => eq(5500),
      'l_spc_ts' => be_a(Float),
      'lock_key' => eq('rql:lock:pek'),
      'rem_ttl' => be_a(Integer)
    })

    # TODO: pokrit novie logi
  end

  specify 'reentrant locks - :work_through' do
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config.default_conflict_strategy = :work_through
      config.log_lock_try = true
      config.logger = Logger.new(STDOUT)
    end

    # Current Lock TTL: 5000
    result1 = client.lock('trukek', ttl: 10_000)
    lock_state1 = client.lock_info('trukek')
    # Current Lock TTL: >9000, <10_000
    # NOTE: <reentrant lock> without extension!!!
    #   - ttl is ignored here cuz we try to obtain reentrant lock
    result2 = client.lock('trukek', ttl: 5000) # NOTE: SPC COUNT - 1
    lock_state2 = client.lock_info('trukek')
    # Current Lock TTL: >9000, <1000 (no extensions - just simple reentrant work-through)
    result3 = client.lock('trukek', ttl: 9000) # NOTE: SPC COUNT - 2
    lock_state3 = client.lock_info('trukek')

    # OK + :lock_obtaining process, NO SPC COUNT
    expect(result1[:ok]).to eq(true)
    expect(result1[:result]).to match({
      lock_key: eq('rql:lock:trukek'),
      acq_id: be_a(String),
      hst_id: be_a(String),
      ts: be_a(Float),
      ttl: eq(10_000),
      process: eq(:lock_obtaining)
    })
    expect(lock_state1.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'lock_key',
      'rem_ttl'
    )
    expect(lock_state1).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer)
    })

    # OK + :conflict_work_through :process, SPC COUNT: 1
    expect(result2[:ok]).to eq(true)
    expect(result2[:result][:process]).to eq(:conflict_work_through)
    expect(result2[:result]).to match({
      lock_key: eq('rql:lock:trukek'),
      acq_id: be_a(String),
      hst_id: be_a(String),
      ts: be_a(Float),
      ttl: eq(5_000),
      process: eq(:conflict_work_through)
    })
    expect(lock_state2.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'spc_cnt',
      'l_spc_ts',
      'lock_key',
      'rem_ttl'
    )
    expect(lock_state2).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'spc_cnt' => eq(1),
      'l_spc_ts' => be_a(Float),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer)
    })

    # OK + :conflict_work_through :process, SPC COUNT: 2
    expect(result3[:ok]).to eq(true)
    expect(result3[:result][:process]).to eq(:conflict_work_through)
    expect(result3[:result]).to match({
      lock_key: eq('rql:lock:trukek'),
      acq_id: be_a(String),
      hst_id: be_a(String),
      ts: be_a(Float),
      ttl: eq(9_000),
      process: eq(:conflict_work_through)
    })
    expect(lock_state3.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'spc_cnt',
      'l_spc_ts',
      'lock_key',
      'rem_ttl'
    )
    expect(lock_state3).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'spc_cnt' => eq(2),
      'l_spc_ts' => be_a(Float),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer)
    })

    # CHECK: SPC count should change with another conflict strategy too (with their own info)
    result4 = client.lock('trukek', ttl: 5500, conflict_strategy: :extendable_work_through)
    expect(result4[:ok]).to eq(true)
    expect(result4[:result][:process]).to eq(:extendable_conflict_work_through)
    expect(result4[:result]).to match({
      lock_key: eq('rql:lock:trukek'),
      acq_id: be_a(String),
      hst_id: be_a(String),
      ts: be_a(Float),
      ttl: eq(5500),
      process: eq(:extendable_conflict_work_through)
    })
    lock_state4 = client.lock_info('trukek')
    expect(lock_state4.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'spc_cnt',
      'l_spc_ts',
      'spc_ext_ttl',
      'l_spc_ext_ts',
      'l_spc_ext_ini_ttl',
      'lock_key',
      'rem_ttl'
    )
    expect(lock_state4).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'spc_cnt' => eq(3),
      'l_spc_ts' => be_a(Float),
      'spc_ext_ttl' => eq(5_500),
      'l_spc_ext_ts' => be_a(Float),
      'l_spc_ext_ini_ttl' => eq(5_500),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer)
    })

    # TODO: pokrit novie logi
  end

  specify 'reentrant locks - :dead_locking' do
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config.default_conflict_strategy = :dead_locking
      config.log_lock_try = true
      config.logger = Logger.new(STDOUT)
    end

    result1 = client.lock('bekkek', ttl: 10_000)
    lock_state1 = client.lock_info('bekkek')
    expect(result1[:ok]).to eq(true)
    expect(result1[:result][:process]).to eq(:lock_obtaining)
    expect(result1[:result]).to match({
      lock_key: eq('rql:lock:bekkek'),
      acq_id: be_a(String),
      hst_id: be_a(String),
      ts: be_a(Float),
      ttl: eq(10_000),
      process: eq(:lock_obtaining)
    })
    expect(lock_state1.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'lock_key',
      'rem_ttl'
    )
    expect(lock_state1).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'lock_key' => eq('rql:lock:bekkek'),
      'rem_ttl' => be_a(Integer)
    })

    result2 = client.lock('bekkek', ttl: 5_000)
    lock_state2 = client.lock_info('bekkek')
    expect(result2[:ok]).to eq(false)
    expect(result2[:result]).to eq(:conflict_dead_lock)
    expect(lock_state1.keys).to contain_exactly(
      'acq_id',
      'hst_id',
      'ts',
      'ini_ttl',
      'lock_key',
      'rem_ttl'
    )
    # CHECK: lock state does not change (except the `rem_ttl` key of course)
    expect(lock_state2).to match({
      'acq_id' => (lock_state1['acq_id']),
      'hst_id' => (lock_state1['hst_id']),
      'ts' => eq(lock_state1['ts']),
      'ini_ttl' => eq(lock_state1['ini_ttl']),
      'lock_key' => eq('rql:lock:bekkek'),
      'rem_ttl' => be_a(Integer)
    })

    # TODO: pokrit novie logi
  end

  specify 'clear_dead_queues' do
    client = RedisQueuedLocks::Client.new(redis)
    client.lock('kek.dead.lock1', ttl: 30_000)
    client.lock('kek.dead.lock2', ttl: 30_000)

    # seed requests - make them dead
    lockers1 = Array.new(10) do
      # seed dead short-living requests
      Thread.new do
        client.lock('kek.dead.lock1', ttl: 50_000, queue_ttl: 60, timeout: nil, retry_count: nil)
      end
    end
    lockers2 = Array.new(6) do
      # seed dead short-living requests
      Thread.new do
        client.lock('kek.dead.lock2', ttl: 50_000, queue_ttl: 60, timeout: nil, retry_count: nil)
      end
    end
    sleep(4)
    # seed super long-living request
    locker3 = Thread.new do
      client.lock('kek.dead.lock1', ttl: 50_000, queue_ttl: 60, timeout: nil, retry_count: nil)
    end
    # seed super long-living request
    locker4 = Thread.new do
      client.lock('kek.dead.lock2', ttl: 50_000, queue_ttl: 60, timeout: nil, retry_count: nil)
    end
    sleep(1)
    # kill acquiers => requests will live in redis now (zombie requests! bu!)
    lockers1.each(&:kill)
    lockers2.each(&:kill)
    locker3.kill
    locker4.kill

    expect(client.queues).to contain_exactly(
      'rql:lock_queue:kek.dead.lock1',
      'rql:lock_queue:kek.dead.lock2'
    )
    expect(client.queues_info.size).to eq(2)

    queue_info1 = client.queue_info('kek.dead.lock1')
    expect(queue_info1['queue'].size).to eq(11)
    queue_info2 = client.queue_info('kek.dead.lock2')
    expect(queue_info2['queue'].size).to eq(7)

    expect(client.queue_info('kek.dead.lock1')).to match({
      'lock_queue' => 'rql:lock_queue:kek.dead.lock1',
      'queue' => contain_exactly(
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) }
      )
    })

    expect(client.queue_info('kek.dead.lock2')).to match({
      'lock_queue' => 'rql:lock_queue:kek.dead.lock2',
      'queue' => contain_exactly(
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) },
        { 'acq_id' => be_a(String), 'score' => be_a(Numeric) }
      )
    })

    # drop short living requests
    result = client.clear_dead_requests(dead_ttl: 3_500)
    expect(result).to match({
      ok: true,
      result: match({
        processed_queues: contain_exactly(
          'rql:lock_queue:kek.dead.lock1',
          'rql:lock_queue:kek.dead.lock2'
        )
      })
    })

    # long-living requests remain
    expect(client.queues).to contain_exactly(
      'rql:lock_queue:kek.dead.lock1',
      'rql:lock_queue:kek.dead.lock2'
    )
    expect(client.queues_info.size).to eq(2)

    queue_info1 = client.queue_info('kek.dead.lock1')
    expect(queue_info1['queue'].size).to eq(1) # long-living requests
    queue_info2 = client.queue_info('kek.dead.lock2')
    expect(queue_info2['queue'].size).to eq(1) # long-living requests

    # drop long-living requests
    result = client.clear_dead_requests(dead_ttl: 1_000)
    expect(result).to match({
      ok: true,
      result: match({
        processed_queues: contain_exactly(
          'rql:lock_queue:kek.dead.lock1',
          'rql:lock_queue:kek.dead.lock2'
        )
      })
    })
    expect(client.queues).to be_empty
    redis.call('FLUSHDB')
  end

  specify 'logger' do
    test_logger = Class.new do
      attr_reader :logs

      def initialize
        @logs = []
      end

      def debug(progname = nil, &block)
        logs << "#{progname} : #{yield if block_given?}"
      end
    end.new

    queue_ttl = rand(10..15)
    acs_strat = :queued

    # NOTE: with log_lock_try test
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.logger = test_logger
      conf.log_lock_try = true
      conf.default_queue_ttl = queue_ttl
      conf.default_access_strategy = acs_strat
    end

    client.lock('pek.kek.cheburek') { 1 + 1 }

    expect(test_logger.logs.size).to eq(10)
    aggregate_failures 'logs content (with log_lock_try)' do
      # NOTE: lock_obtaining
      expect(test_logger.logs[0]).to include('[redis_queued_locks.start_lock_obtaining]')
      expect(test_logger.logs[0]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[0]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[0]).to include('acq_id =>')
      expect(test_logger.logs[0]).to include('hst_id =>')
      expect(test_logger.logs[0]).to include("acs_strat => '#{acs_strat}")

      # NOTE: start <try lock> cycle
      expect(test_logger.logs[1]).to include('[redis_queued_locks.start_try_to_lock_cycle]')
      expect(test_logger.logs[1]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[1]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[1]).to include('acq_id =>')
      expect(test_logger.logs[1]).to include('hst_id =>')
      expect(test_logger.logs[1]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock - start
      expect(test_logger.logs[2]).to include('[redis_queued_locks.try_lock.start]')
      expect(test_logger.logs[2]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[2]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[2]).to include('acq_id =>')
      expect(test_logger.logs[2]).to include('hst_id =>')
      expect(test_logger.logs[2]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock - rconn fetched
      expect(test_logger.logs[3]).to include('[redis_queued_locks.try_lock.rconn_fetched]')
      expect(test_logger.logs[3]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[3]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[3]).to include('acq_id =>')
      expect(test_logger.logs[3]).to include('hst_id =>')
      expect(test_logger.logs[3]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock - acq added to queue
      expect(test_logger.logs[4]).to include('[redis_queued_locks.try_lock.acq_added_to_queue]')
      expect(test_logger.logs[4]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[4]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[4]).to include('acq_id =>')
      expect(test_logger.logs[4]).to include('hst_id =>')
      expect(test_logger.logs[4]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock - remove expired acqs
      expect(test_logger.logs[5]).to include('[redis_queued_locks.try_lock.remove_expired_acqs]')
      expect(test_logger.logs[5]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[5]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[5]).to include('acq_id =>')
      expect(test_logger.logs[5]).to include('hst_id =>')
      expect(test_logger.logs[5]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock - get first from queue
      expect(test_logger.logs[6]).to include('[redis_queued_locks.try_lock.get_first_from_queue]')
      expect(test_logger.logs[6]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[6]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[6]).to include('acq_id =>')
      expect(test_logger.logs[6]).to include('hst_id =>')
      expect(test_logger.logs[6]).to include('first_acq_id_in_queue =>')
      expect(test_logger.logs[6]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock - fre to acquire
      # rubocop:disable Layout/LineLength
      expect(test_logger.logs[7]).to include('[redis_queued_locks.try_lock.obtain__free_to_acquire]')
      expect(test_logger.logs[7]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[7]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[7]).to include('acq_id =>')
      expect(test_logger.logs[7]).to include('hst_id =>')
      expect(test_logger.logs[7]).to include("acs_strat => '#{acs_strat}")
      # rubocop:enable Layout/LineLength

      # NOTE: lock_obtained
      expect(test_logger.logs[8]).to include('[redis_queued_locks.lock_obtained]')
      expect(test_logger.logs[8]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[8]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[8]).to include('acq_id =>')
      expect(test_logger.logs[8]).to include('hst_id =>')
      expect(test_logger.logs[8]).to include('acq_time =>')
      expect(test_logger.logs[8]).to include("acs_strat => '#{acs_strat}")

      # NOTE: expire_lock
      expect(test_logger.logs[9]).to include('[redis_queued_locks.expire_lock]')
      expect(test_logger.logs[9]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[9]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[9]).to include('acq_id =>')
      expect(test_logger.logs[9]).to include('hst_id =>')
      expect(test_logger.logs[9]).to include("acs_strat => '#{acs_strat}")
    end

    # NOTE: rollback to the clean initial state in order to test another case
    test_logger.logs.clear
    acs_strat = :random

    # NOTE: without log_lock_try test
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.logger = test_logger
      conf.log_lock_try = false
      conf.default_queue_ttl = queue_ttl
      conf.default_access_strategy = acs_strat
    end

    client.lock('pek.kek.cheburek') { 1 + 1 }

    expect(test_logger.logs.size).to eq(4)
    aggregate_failures 'logs content (with log_lock_try)' do
      # NOTE: lock_obtaining
      expect(test_logger.logs[0]).to include('[redis_queued_locks.start_lock_obtaining]')
      expect(test_logger.logs[0]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[0]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[0]).to include('acq_id =>')
      expect(test_logger.logs[0]).to include('hst_id =>')
      expect(test_logger.logs[0]).to include("acs_strat => '#{acs_strat}")

      # NOTE: try to lock cycle start
      expect(test_logger.logs[1]).to include('[redis_queued_locks.start_try_to_lock_cycle]')
      expect(test_logger.logs[1]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[1]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[1]).to include('acq_id =>')
      expect(test_logger.logs[1]).to include('hst_id =>')
      expect(test_logger.logs[1]).to include("acs_strat => '#{acs_strat}")

      # NOTE: lock_obtained
      expect(test_logger.logs[2]).to include('[redis_queued_locks.lock_obtained]')
      expect(test_logger.logs[2]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[2]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[2]).to include('acq_id =>')
      expect(test_logger.logs[2]).to include('hst_id =>')
      expect(test_logger.logs[2]).to include('acq_time =>')
      expect(test_logger.logs[2]).to include("acs_strat => '#{acs_strat}")

      # NOTE: expire_lock
      expect(test_logger.logs[3]).to include('[redis_queued_locks.expire_lock]')
      expect(test_logger.logs[3]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
      expect(test_logger.logs[3]).to include("queue_ttl => #{queue_ttl}")
      expect(test_logger.logs[3]).to include('acq_id =>')
      expect(test_logger.logs[3]).to include('hst_id =>')
      expect(test_logger.logs[3]).to include("acs_strat => '#{acs_strat}")
    end
  end

  specify 'extend_lock_ttl' do
    client = RedisQueuedLocks::Client.new(redis)
    client.lock('super_mega_kek_lock', ttl: 15_000)
    lock_info = client.lock_info('super_mega_kek_lock')
    expect(lock_info['rem_ttl'] <= 15_000 && lock_info['rem_ttl'] > 0).to eq(true)

    # NOTE: extend ttl of existing lock
    result = client.extend_lock_ttl('super_mega_kek_lock', 100_000)
    expect(result[:ok]).to eq(true)
    expect(result[:result]).to eq(:ttl_extended)
    lock_info = client.lock_info('super_mega_kek_lock')
    expect(lock_info['rem_ttl'] > 100_000).to eq(true)

    # NOTE: extend ttl of non existing lock
    result = client.extend_lock_ttl('no_super_no_mega_no_lock', 100_000)
    expect(result[:ok]).to eq(false)
    expect(result[:result]).to eq(:async_expire_or_no_lock)

    # NOTE: extend expired lock (it is not reasonable, but just for visualisation for developers)
    client.unlock('super_mega_kek_lock')
    result = client.extend_lock_ttl('super_mega_kek_lock', 100_000)
    expect(result[:ok]).to eq(false)
    expect(result[:result]).to eq(:async_expire_or_no_lock)
  end

  specify '#unlock' do
    client = RedisQueuedLocks::Client.new(redis)
    client.lock('unlock_check_lock_pock', ttl: 10_000)
    lockers = Array.new(2) do
      Thread.new do
        client.lock('unlock_check_lock_pock', ttl: 10_000, retry_count: nil, retry_delay: 10)
      end
    end
    sleep(1)

    aggregate_failures 'unlock existing lock' do
      unlock_result = client.unlock('unlock_check_lock_pock')

      expect(unlock_result).to match({
        ok: true,
        result: match({
          rel_time: be_a(Numeric),
          rel_key: 'rql:lock:unlock_check_lock_pock',
          rel_queue: 'rql:lock_queue:unlock_check_lock_pock',
          lock_res: :released,
          queue_res: :released
        })
      })
    end

    aggregate_failures 'unlock non-existing lock' do
      unlock_result = client.unlock('kek_pek_lock_uberok')

      expect(unlock_result).to match({
        ok: true,
        result: match({
          rel_time: be_a(Numeric),
          rel_key: 'rql:lock:kek_pek_lock_uberok',
          rel_queue: 'rql:lock_queue:kek_pek_lock_uberok',
          lock_res: :nothing_to_release,
          queue_res: :nothing_to_release
        })
      })
    end

    lockers.each(&:join)
    redis.call('FLUSHDB')
  end

  specify ':meta' do
    # NOTE: with log_lock_try test
    client = RedisQueuedLocks::Client.new(redis)
    client.lock('kek.pek.lock.pock', ttl: 5_000, meta: { 'chuk' => '321', 'buk' => 123 })
    lock_info = client.lock_info('kek.pek.lock.pock')

    expect(lock_info).to match({
      'acq_id' => be_a(String), # reserved
      'hst_id' => be_a(String), # reserved
      'ts' => be_a(Numeric), # reserved
      'ini_ttl' => be_a(Integer), # reserved
      'lock_key' => be_a(String), # reserved
      'rem_ttl' => be_a(Numeric), # reserved
      'chuk' => '321', # <custom meta> (expectation)
      'buk' => '123' # <custom meta> (expectation)
    })

    aggregate_failures 'reserved keys' do
      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'acq_id' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'hst_id' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'ts' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'ini_ttl' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'lock_key' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'rem_ttl' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'spc_ext_ttl' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'spc_cnt' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'l_spc_ext_ini_ttl' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'l_spc_ext_ts' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'l_spc_ts' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)
    end
  end

  specify ':instrument' do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new

    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.instrumenter = test_notifier
    end

    expect(test_notifier.notifications).to be_empty
    client.lock('kek-pek-cheburgen', instrument: { test: :ok })
    expect(test_notifier.notifications.size).to eq(1)
    expect(test_notifier.notifications[0][:payload][:instrument]).to eq({ test: :ok })
    client.lock('bum-bum-pek-mek')
    expect(test_notifier.notifications.size).to eq(2)
    expect(test_notifier.notifications[1][:payload][:instrument]).to eq(nil)
  end

  specify 'detailed lock acquirement timeout error' do
    redis = RedisClient.config.new_pool(timeout: 5, size: 50)
    client = RedisQueuedLocks::Client.new(redis) do |config|
      # NOTE: false by default
      # config.detailed_acq_timeout_error = false
    end

    client.lock('some-long-lock', ttl: 30_000)

    expect do
      client.lock('some-long-lock', timeout: 2, retry_count: nil, raise_errors: true)
    end.to raise_error(RedisQueuedLocks::LockAcquiermentTimeoutError)

    common_timeout_error = begin
      client.lock('some-long-lock', timeout: 2, retry_count: nil, raise_errors: true)
    rescue RedisQueuedLocks::LockAcquiermentTimeoutError => error
      error
    end

    aggregate_failures 'common error message content' do
      expect(common_timeout_error.message).to include('<2 seconds> timeout.')
      expect(common_timeout_error.message).to include('the lock "rql:lock:some-long-lock"')
      expect(common_timeout_error.message).not_to include('<Lock Data>')
      expect(common_timeout_error.message).not_to include('<Queue Data>')
    end

    detailed_timeout_error = begin
      client.lock(
        'some-long-lock',
        timeout: 2,
        retry_count: nil,
        raise_errors: true,
        detailed_acq_timeout_error: true
      )
    rescue RedisQueuedLocks::LockAcquiermentTimeoutError => error
      error
    end

    aggregate_failures 'detailed error message content' do
      expect(detailed_timeout_error.message).to include('<2 seconds> timeout.')
      expect(detailed_timeout_error.message).to include('the lock "rql:lock:some-long-lock"')
      expect(detailed_timeout_error.message).to include('<Lock Data>')
      expect(detailed_timeout_error.message).not_to include('<Lock Data> => <no_data>')
      expect(detailed_timeout_error.message).to include('<Queue Data> => <no_data>')
    end

    Thread.new { client.lock('some-long-lock', ttl: 30_000, retry_count: nil) }

    detailed_timeout_error = begin
      client.lock(
        'some-long-lock',
        timeout: 2,
        retry_count: nil,
        raise_errors: true,
        detailed_acq_timeout_error: true
      )
    rescue RedisQueuedLocks::LockAcquiermentTimeoutError => error
      error
    end

    aggregate_failures 'more detailed error message content' do
      expect(detailed_timeout_error.message).to include('<2 seconds> timeout.')
      expect(detailed_timeout_error.message).to include('the lock "rql:lock:some-long-lock"')
      expect(detailed_timeout_error.message).to include('<Lock Data>')
      expect(detailed_timeout_error.message).not_to include('<Lock Data> => <no_data>')
      expect(detailed_timeout_error.message).to include('<Queue Data>')
      expect(detailed_timeout_error.message).not_to include('<Queue Data> => <no_data>')
    end
  end

  specify 'timed lock' do
    redis = RedisClient.config.new_pool(timeout: 5, size: 50)
    client = RedisQueuedLocks::Client.new(redis)

    expect do
      client.lock('some-timed-lock', timed: true, ttl: 2_000) { sleep(3) }
    end.to raise_error(RedisQueuedLocks::TimedLockTimeoutError)

    timed_lock_error = begin
      client.lock('some-timed-lock', timed: true, ttl: 1_000) { sleep(2) }
    rescue RedisQueuedLocks::TimedLockTimeoutError => error
      error
    end

    aggregate_failures 'error message content (with empty meta)' do
      expect(timed_lock_error.message).to include('lock: "rql:lock:some-timed-lock",')
      expect(timed_lock_error.message).to include('ttl: 1000,')
      expect(timed_lock_error.message).to include('meta: <no-meta>,')
      expect(timed_lock_error.message).to include("acq_id: \"#{client.current_acquier_id}\"")
      expect(timed_lock_error.message).to include("hst_id: \"#{client.current_host_id}\"")
    end

    timed_lock_error_with_meta = begin
      client.lock('some-timed-lock', timed: true, ttl: 1_000, meta: { kek: 'pek' }) { sleep(2) }
    rescue RedisQueuedLocks::TimedLockTimeoutError => error
      error
    end

    aggregate_failures 'error message content (with filled meta)' do
      expect(timed_lock_error_with_meta.message).to include(
        'lock: "rql:lock:some-timed-lock",'
      )
      expect(timed_lock_error_with_meta.message).to include(
        'ttl: 1000,'
      )
      expect(timed_lock_error_with_meta.message).to include(
        "meta: #{{ kek: 'pek' }.inspect}"
      )
      expect(timed_lock_error_with_meta.message).to include(
        "acq_id: \"#{client.current_acquier_id}\""
      )
      expect(timed_lock_error_with_meta.message).to include(
        "hst_id: \"#{client.current_host_id}\""
      )
    end

    expect(client.locked?('some-timed-lock')).to eq(false)

    expect do
      client.lock('some-timed-lock', timed: true, ttl: 6_000) { sleep(5.8) }
    end.not_to raise_error

    expect(client.locked?('some-timed-lock')).to eq(false)
  end

  specify 'lock queues' do
    client = RedisQueuedLocks::Client.new(redis)

    client.lock('some-kek-super-pek', ttl: 5_000)
    res = client.lock('some-kek-super-pek', fail_fast: true) {}
    expect(res).to match({ ok: false, result: :fail_fast_no_try })

    expect do
      client.lock!('some-kek-super-pek', fail_fast: true)
    end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)

    expect do
      client.lock!('some-kek-super-pek', retry_count: 1)
    end.to raise_error(RedisQueuedLocks::LockAcquiermentRetryLimitError)

    expect do
      client.lock!('some-kek-super-pek', retry_count: 1, timeout: 1)
    end.to raise_error(RedisQueuedLocks::LockAcquiermentRetryLimitError)
  end

  specify 'lock_info, queue_info' do
    client = RedisQueuedLocks::Client.new(redis)
    lock_name = "kekpek-#{rand(100_000)}"

    expect(client.queue_info(lock_name)).to eq(nil)
    expect(client.lock_info(lock_name)).to eq(nil)
    expect(client.locked?(lock_name)).to eq(false)
    expect(client.queued?(lock_name)).to eq(false)

    expect(client.locked?(lock_name)).to eq(false)
    client.lock(lock_name, ttl: 10_000)
    lock_info = client.lock_info(lock_name)

    expect(lock_info).to match({
      'lock_key' => "rql:lock:#{lock_name}",
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => 10_000,
      'rem_ttl' => be_a(Integer)
    })

    expect(client.locked?(lock_name)).to eq(true)
    expect(client.queued?(lock_name)).to eq(false)

    # NOTE: two new requests
    thread_a = Thread.new { client.lock(lock_name, ttl: 10_000, timeout: nil, retry_count: nil) }
    thread_b = Thread.new { client.lock(lock_name, ttl: 10_000, timeout: nil, retry_count: nil) }
    sleep(1)

    expect(client.queued?(lock_name)).to eq(true)
    expect(client.queue_info(lock_name)).to match({
      'lock_queue' => "rql:lock_queue:#{lock_name}",
      'queue' => match_array([
        match({ 'acq_id' => be_a(String), 'score' => be_a(Numeric) }),
        match({ 'acq_id' => be_a(String), 'score' => be_a(Numeric) })
      ])
    })

    thread_a.join
    thread_b.join
  end

  specify 'all in + notifications' do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new

    client = RedisQueuedLocks::Client.new(redis) do |config|
      config.retry_count = 3
      config.instrumenter = test_notifier
    end

    redis_for_info = RedisClient.config(db: 1).new_pool(timeout: 5, size: 50)
    redis_for_info.call('FLUSHDB')

    client_for_info = RedisQueuedLocks::Client.new(redis) do |config|
      config.retry_count = 3
      config.instrumenter = test_notifier
    end

    inf_threads1 = Array.new(4) do |kek|
      Thread.new do
        client_for_info.lock(
          'locklock-pekpek-123',
          ttl: 30_000,
          timeout: nil,
          retry_count: nil,
          meta: { 'kek' => 'pek', 'a' => 123 }
        ) { sleep(5) }
      end
    end
    inf_threads2 = Array.new(4) do |kek|
      Thread.new do
        client_for_info.lock(
          'locklock-pekpek-567',
          ttl: 30_000,
          timeout: nil,
          retry_count: nil,
          meta: { 'pek' => 'mek', 'b' => 55.66 }
        ) { sleep(5) }
      end
    end

    sleep(1)

    # NOTE: 2 locks is obtained, 6 - in queues
    locks_info_a = client_for_info.locks_info
    locks_info_b = client_for_info.locks(with_info: true)

    queue_info_a = client_for_info.queues_info
    queue_info_b = client_for_info.queues(with_info: true)

    redis_for_info.call('FLUSHDB')

    # TODO: more time for work => better spec
    expect(locks_info_a).to be_a(Set)
    expect(locks_info_b).to be_a(Set)
    expect(locks_info_a.size).to eq(2)
    expect(locks_info_a.map { |val| val[:lock] }).to contain_exactly(
      'rql:lock:locklock-pekpek-123',
      'rql:lock:locklock-pekpek-567'
    )
    expect(locks_info_a.map { |val| val[:status] }).to contain_exactly(
      :alive,
      :alive
    )
    expect(locks_info_a.map { |val| val[:info].keys }).to contain_exactly(
      contain_exactly(*%w[acq_id hst_id ts ini_ttl rem_ttl kek a]),
      contain_exactly(*%w[acq_id hst_id ts ini_ttl rem_ttl pek b])
    )
    expect(locks_info_b.size).to eq(2)
    expect(locks_info_b.map { |val| val[:lock] }).to contain_exactly(
      'rql:lock:locklock-pekpek-123',
      'rql:lock:locklock-pekpek-567'
    )
    expect(locks_info_b.map { |val| val[:status] }).to contain_exactly(
      :alive,
      :alive
    )
    expect(locks_info_b.map { |val| val[:info].keys }).to contain_exactly(
      contain_exactly(*%w[acq_id hst_id ts ini_ttl rem_ttl kek a]),
      contain_exactly(*%w[acq_id hst_id ts ini_ttl rem_ttl pek b])
    )

    # TODO: more time for work => better spec
    expect(queue_info_a).to be_a(Set)
    expect(queue_info_b).to be_a(Set)
    expect(queue_info_a).to eq(queue_info_b)

    expect(queue_info_a.size).to eq(2)
    expect(queue_info_a.map { |val| val[:queue] }).to contain_exactly(
      'rql:lock_queue:locklock-pekpek-123',
      'rql:lock_queue:locklock-pekpek-567'
    )
    expect(queue_info_a.map { |val| val[:requests].map(&:keys) }).to contain_exactly(
      contain_exactly(
        contain_exactly(*%w[acq_id score]),
        contain_exactly(*%w[acq_id score]),
        contain_exactly(*%w[acq_id score])
      ),
      contain_exactly(
        contain_exactly(*%w[acq_id score]),
        contain_exactly(*%w[acq_id score]),
        contain_exactly(*%w[acq_id score])
      )
    )

    a_threads = Array.new(5) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", retry_count: nil, timeout: nil)
      end
    end

    b_threads = Array.new(5) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", retry_count: nil, timeout: nil) { 'some_logic' }
      end
    end.each(&:join)

    c_threads = Array.new(120) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", ttl: 10_000, retry_count: nil, timeout: nil)
      end
    end

    lock_list = client.locks
    expect(lock_list).not_to be_empty
    expect(lock_list.all? { |lock| lock.match?(/\Arql:lock:.*?\z/) }).to eq(true)
    queue_list = client.queues
    expect(queue_list).not_to be_empty
    expect(queue_list.all? { |lock| lock.match?(/\Arql:lock_queue:.*?\z/) }).to eq(true)
    key_list = client.keys
    expect(key_list).not_to be_empty
    expect(key_list.all? do |key|
      key.match?(/\Arql:(lock|lock_queue):.*?\z/)
    end).to eq(true)

    client.unlock('locklock1')
    sleep(3)
    cleared_locks = client.clear_locks
    expect(cleared_locks).to match({
      ok: true,
      result: {
        rel_key_cnt: satisfy { |cnt| cnt > 0 },
        rel_time: be_a(Numeric)
      }
    })

    puts test_notifier.notifications
    expect(test_notifier.notifications).not_to be_empty

    a_threads.each(&:join)
    b_threads.each(&:join)
    c_threads.each(&:join)

    inf_threads1.each(&:join)
    inf_threads2.each(&:join)

    redis.call('FLUSHDB')
  end
end
