# frozen_string_literal: true

# NOTE:
#   - these specs will be TOTALLY reworked (this is a reason of using rspec-retry);
#   - this code is not ideal and final,
#     it is written only for behavior testing and funcionality checking;
RSpec.shared_context 'redis_queued_locks redis' do
  let(:redis) do
    RedisClient.config(db: 0).new_pool(
      # NOTE:
      #   - long connect_/read_/write_ timeouts is used for problems inside the github runners
      #     in RBS tests where all our code is "totally slow"
      #     (and each spec can fail on 1.0-seconds-timeout with Socket's timeout error);
      #   - long <timeout:> is used for some test-cases;
      timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
    )
  end

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
end

# NOTE: the behavior of the library: it runs with both lock lookup modes (the keyspace SCAN and
#   the lock index: `config['lock_index_enabled']` is switched by the `lock_index_enabled` metadata
#   of the including context, see `spec_helper`);
RSpec.shared_examples 'redis_queued_locks' do
  # NOTE: Lock Series PoC
  describe 'Lock Series PoC' do
    specify '#lock_series' do
      test_logger_klass = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          puts "LOG: (#{yield if block_given?})"
          logs << "#{progname} : #{yield if block_given?}"
        end
      end

      test_notifier = Class.new do
        attr_reader :notifications

        def initialize
          @notifications = []
        end

        def notify(event, payload = {})
          puts "INSTRUMENT: (#{event}) => #{payload}"
          notifications << { event:, payload: }
        end
      end

      client = RedisQueuedLocks::Client.new(redis)

      a_lock_status_inside_lock = nil
      b_lock_status_inside_lock = nil

      # successful obtaining
      client.lock_series(
        'a', 'b',
        log_sample_this: true,
        instr_sample_this: true,
        logger: test_logger_klass.new,
        instrumenter: test_notifier.new,
        detailed_acq_timeout_error: true,
        log_lock_try: true
      ) do
        a_lock_status_inside_lock = client.locked?('a')
        b_lock_status_inside_lock = client.locked?('b')
        puts 'kek'
      end
      # inside, when locks are acquired
      expect(a_lock_status_inside_lock).to eq(true)
      expect(b_lock_status_inside_lock).to eq(true)
      # outside after locks hold
      expect(client.locked?('a')).to eq(false)
      expect(client.locked?('b')).to eq(false)

      # failed obtaining
      client.lock('a', ttl: 10_000_000)
      failed_result = client.lock_series(
        'a', 'b',
        log_sample_this: true,
        instr_sample_this: true,
        logger: test_logger_klass.new,
        instrumenter: test_notifier.new
      ) { puts 'kek' }
      expect(client.locked?('a')).to eq(true)
      expect(client.locked?('b')).to eq(false)

      expect(failed_result).to match({
        ok: false,
        result: {
          error: :failed_to_acquire_lock_series,
          detailed_errors: { 'a' => { ok: false, result: :retry_limit_reached } },
          lock_series: %w[a b],
          acquired_locks: [],
          missing_locks: %w[a b],
          failed_on_lock: 'a'
        }
      })

      # detailed result
      # (with block => locks_release_strategy: :immediate_release_after_yield inside)
      some_block_result = rand(0..100)
      detailed_result = client.lock_series(
        'x', 'y', 'z',
        detailed_result: true,
        log_sample_this: true,
        instr_sample_this: true,
        logger: test_logger_klass.new,
        instrumenter: test_notifier.new
      ) do
        some_block_result
      end
      expect(detailed_result).to match({
        yield_result: some_block_result,
        locks_released_at: be_a(Numeric),
        locks_acq_time: be_a(Numeric),
        locks_hold_time: be_a(Numeric),
        locks_release_strategy: :immediate_release_after_yield,
        lock_series: %w[x y z],
        rql_lock_series: ['rql:lock:x', 'rql:lock:y', 'rql:lock:z']
      })

      # detailed result
      # (without block => locks_release_strategy: :redis_key_ttl inside)
      some_block_result = rand(0..100)
      detailed_result = client.lock_series(
        's', 't', 'u',
        detailed_result: true,
        log_sample_this: true,
        instr_sample_this: true,
        logger: test_logger_klass.new,
        instrumenter: test_notifier.new
      )
      # rubocop:disable Layout/LineLength
      expect(detailed_result).to match({
        yield_result: nil, # block_given? ==> false (no block result)
        locks_released_at: nil, # nil cuz locks are not relesed by RQL, no block given - locks are living inside redis with their TTL
        locks_acq_time: be_a(Numeric),
        locks_hold_time: nil, # nil cuz locks are not relesed by RQL, no block given - locks are living inside redis with their TTL
        locks_release_strategy: :redis_key_ttl,
        lock_series: %w[s t u],
        rql_lock_series: ['rql:lock:s', 'rql:lock:t', 'rql:lock:u']
      })
      # rubocop:enable Layout/LineLength

      # error-oriented locking works well
      client.lock('b', ttl: 10_000_000)
      expect do
        client.lock_series(
          'x', 'y', 'b',
          ttl: 10_000,
          detailed_result: true,
          raise_errors: true,
          log_sample_this: true,
          instr_sample_this: true,
          logger: test_logger_klass.new,
          instrumenter: test_notifier.new
        )
      end.to raise_error(
        # X and Y should be released! B - NOT!
        RedisQueuedLocks::LockAcquirementRetryLimitError,
        'Failed to acquire the lock "rql:lock:b" for the given retry_count limit (3 times).'
      )
      expect(client.locked?('x')).to eq(false)
      expect(client.locked?('y')).to eq(false)
      expect(client.locked?('b')).to eq(true)

      # error-oriented locking works well
      client.lock('c', ttl: 10_000_000)
      expect do
        client.lock_series!(
          'x', 'y', 'c',
          detailed_result: true,
          log_sample_this: true,
          instr_sample_this: true,
          logger: test_logger_klass.new,
          instrumenter: test_notifier.new
        )
      end.to raise_error(
        # X and Y should be released! C - NOT!
        RedisQueuedLocks::LockAcquirementRetryLimitError,
        'Failed to acquire the lock "rql:lock:c" for the given retry_count limit (3 times).'
      )
      expect(client.locked?('x')).to eq(false)
      expect(client.locked?('y')).to eq(false)
      expect(client.locked?('c')).to eq(true)

      # failed acquirement should works well with detailed errors
      client.lock('d', ttl: 10_000_000)
      detailed_result = client.lock_series(
        'x', 'y', 'd',
        ttl: 10_000,
        detailed_result: true,
        raise_errors: false,
        log_sample_this: true,
        instr_sample_this: true,
        logger: test_logger_klass.new,
        instrumenter: test_notifier.new
      )
      # X and Y should be released! D - NOT!
      expect(detailed_result).to match({
        ok: false,
        result:
        {
          error: :failed_to_acquire_lock_series,
          detailed_errors: { 'd' => { ok: false, result: :retry_limit_reached } },
          lock_series: %w[x y d],
          acquired_locks: %w[x y],
          missing_locks: ['d'],
          failed_on_lock: 'd'
        }
      })
      expect(client.locked?('x')).to eq(false)
      expect(client.locked?('y')).to eq(false)
      expect(client.locked?('d')).to eq(true)

      # locks are successfully released when the passed block is failed with an exception
      is_aa_locked_isnide = nil
      is_bb_locked_isnide = nil
      is_cc_locked_isnide = nil

      client.lock_series('aa', 'bb', 'cc', ttl: 50_000) do
        is_aa_locked_isnide = client.locked?('aa')
        is_bb_locked_isnide = client.locked?('bb')
        is_cc_locked_isnide = client.locked?('cc')
        raise('Some Error') # <- fails
      end rescue nil

      expect(is_aa_locked_isnide).to eq(true)
      expect(is_bb_locked_isnide).to eq(true)
      expect(is_cc_locked_isnide).to eq(true)

      expect(client.locked?('aa')).to eq(false)
      expect(client.locked?('bb')).to eq(false)
      expect(client.locked?('cc')).to eq(false)
    end

    specify '#lock_series releases only the locks obtained by the series itself' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = 3
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      aggregate_failures 'reentrant write locks of the outer logic are kept' do
        client.lock('ls.outer', ttl: 10_000) do
          client.lock_series('ls.outer', 'ls.inner', conflict_strategy: :work_through) { :ok }
          expect(client.lock_info('ls.outer')['acq_id']).to eq(client.current_acquirer_id)
          expect(client.locked?('ls.inner')).to eq(false)
        end
        expect(client.locked?('ls.outer')).to eq(false)
      end

      aggregate_failures 'write locks of other acquirers are kept (owner check)' do
        other_holder = nil
        client.lock_series('ls.owned', 'ls.other', ttl: 10_000) do
          # NOTE: simulate the lock expiration and the lock obtaining by another acquirer
          client.unlock('ls.owned')
          other_holder = Thread.new { client.lock('ls.owned', ttl: 10_000) }
          other_holder.join
        end
        expect(client.lock_info('ls.owned')['acq_id']).to eq(other_holder.value[:result][:acq_id])
        expect(client.locked?('ls.other')).to eq(false)
        client.unlock('ls.owned')
      end

      aggregate_failures 'locks of the failed series are released without exceptions too' do
        holder = Thread.new { client.lock('ls.busy', ttl: 10_000) }
        holder.join
        %i[write read].each do |mode|
          result = client.lock_series(
            'ls.first', 'ls.busy', read_write_mode: mode, fail_fast: true, ttl: 10_000
          ) { :never }
          expect(result).to match({
            ok: false,
            result: hash_including(acquired_locks: ['ls.first'], failed_on_lock: 'ls.busy')
          })
          expect(client.locked?('ls.first')).to eq(false)
        end
        client.unlock('ls.busy')
      end
    end

    # NOTE: the series events (logs: start, obtained, expire; instrumentation: obtained, hold and
    #   release): the failures are swallowed (the series locks are released after the block,
    #   the block result is kept)
    %w[logger instrumenter].each do |port|
      specify "#lock_series: a failing #{port} does not break the series" do
        failing_ports = {
          'logger' => Class.new do
            def debug(progname = nil, &block)
              raise 'logger failure'
            end
          end.new,
          'instrumenter' => Class.new do
            def notify(event, payload = {})
              raise 'instrumenter failure'
            end
          end.new
        }
        client = RedisQueuedLocks::Client.new(redis) do |config|
          config[port] = failing_ports[port]
        end
        modes = %i[write read]

        modes.each do |mode|
          result = client.lock_series(
            'ls.observed.a', 'ls.observed.b', read_write_mode: mode, ttl: 10_000
          ) { :done }
          expect(result).to eq(:done)
          expect(client.locked?('ls.observed.a')).to eq(false)
          expect(client.locked?('ls.observed.b')).to eq(false)
        end

        # NOTE: without the block the series locks are obtained (and live till their ttl)
        expect do
          client.lock_series('ls.observed.a', 'ls.observed.b', ttl: 10_000)
        end.not_to raise_error
        expect(client.locked?('ls.observed.a')).to eq(true)
        expect(client.locked?('ls.observed.b')).to eq(true)
        client.unlock('ls.observed.a')
        client.unlock('ls.observed.b')
      end
    end
  end
  # rubocop:enable all

  describe 'swarm' do
    specify '#current_host_id, #possible_host_ids' do
      client = RedisQueuedLocks::Client.new(redis)

      uniq_identity = client.uniq_identity
      current_thread_list = Thread.list
      current_process_id = Process.pid
      current_thread_id = Thread.current.object_id
      current_ractor_id = Ractor.current.object_id

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
      # rubocop:disable Layout/LineLength
      new_thread1 = Thread.new { loop { sleep(0.5) } }
      new_thread2 = Thread.new { loop { sleep(0.5) } }
      new_thread1_host_id =
        "rql:hst:#{current_process_id}/#{new_thread1.object_id}/#{current_ractor_id}/#{uniq_identity}"
      new_thread2_host_id =
        "rql:hst:#{current_process_id}/#{new_thread2.object_id}/#{current_ractor_id}/#{uniq_identity}"
      expected_hosts << new_thread1_host_id
      expected_hosts << new_thread2_host_id
      expect(client.possible_host_ids).to contain_exactly(*expected_hosts)
      # rubocop:enable Layout/LineLength

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
        conf['swarm.auto_swarm'] = true
        conf['swarm.supervisor.liveness_probing_period'] = 6
        conf['swarm.probe_hosts.probe_period'] = 2
      end

      # kill swarm elements. supervisor should up them soon.
      client.swarm.flush_zombies_element.try_kill!
      sleep(1) # give a timespot to termiane all async elements
      client.swarm.probe_hosts_element.try_kill!
      sleep(1) # give a timespot to termiane all async elements

      # check that killed elements are truely dead
      aggregate_failures 'swarm elements are dead' do
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
      end

      # sleep supervisor probing time
      #   + some time for up the killed elements
      #   + time to probe hosts period
      #   + time to probe hosts activity ;)
      sleep(6 + 1 + 2 + 1)

      # check that elements are running
      aggregate_failures 'swarm is fully ressurected' do
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
            ractor: match({ running: true, state: eq('running').or(eq('blocking')) }),
            main_loop: match({ running: true, state: eq('sleep').or(eq('run')) })
          })
        })
      end
    end

    specify 'swarm redis config: frozen config hashes are not mutated' do
      aggregate_failures 'RedisClientBuilder' do
        config = { 'db' => 0, 'timeout' => 5 }.freeze
        pool_config = { 'size' => 1, 'timeout' => 5 }.freeze
        [true, false].each do |pooled|
          swarm_redis = RedisQueuedLocks::Swarm::RedisClientBuilder.build(
            pooled:, config:, pool_config:
          )
          expect(swarm_redis.call('PING')).to eq('PONG')
          swarm_redis.close
        end
        expect(config).to eq({ 'db' => 0, 'timeout' => 5 })
        expect(pool_config).to eq({ 'size' => 1, 'timeout' => 5 })
      end

      aggregate_failures 'swarm elements with frozen redis configs' do
        client = RedisQueuedLocks::Client.new(redis) do |config|
          config['swarm.probe_hosts.probe_period'] = 1
          config['swarm.supervisor.liveness_probing_period'] = 1
          config['swarm.probe_hosts.redis_config.config'] = { 'db' => 0 }.freeze
          config['swarm.probe_hosts.redis_config.pool_config'] = {}.freeze
          config['swarm.flush_zombies.redis_config.config'] = { 'db' => 0 }.freeze
          config['swarm.flush_zombies.redis_config.pool_config'] = {}.freeze
        end
        client.swarmize!
        sleep(2) # NOTE: give a timespot to the main loops (probes, zombie flushing)

        expect(redis.call('HGETALL', RedisQueuedLocks::Resource::SWARM_KEY)).to include(
          client.current_host_id
        )
        expect(client.swarm_status).to match(hash_including(
          probe_hosts: hash_including(main_loop: hash_including(running: true)),
          flush_zombies: hash_including(main_loop: hash_including(running: true))
        ))
        client.deswarmize!
      end
    end

    specify 'swarm_status / swarm_info' do
      aggregate_failures 'non-auto-swarmed => swarm is not initialized' do
        client = RedisQueuedLocks::Client.new(redis) do |conf|
          conf['swarm.auto_swarm'] = false
          conf['swarm.probe_hosts.enabled_for_swarm'] = false
          conf['swarm.flush_zombies.enabled_for_swarm'] = false
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
          config['swarm.auto_swarm'] = true
          config['swarm.probe_hosts.probe_period'] = 3
          config['swarm.probe_hosts.enabled_for_swarm'] = true
          config['swarm.flush_zombies.enabled_for_swarm'] = true
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
            ractor: match({ running: true, state: eq('running').or(eq('blocking')) }),
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
        sleep(2) # give a time to terminate async objects

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
        conf['swarm.auto_swarm'] = false
        conf['swarm.flush_zombies.zombie_ttl'] = 4_000
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
        conf['swarm.auto_swarm'] = false
        # NOTE: we will manually probe hosts and flush zombies
        conf['swarm.probe_hosts.enabled_for_swarm'] = false
        conf['swarm.flush_zombies.enabled_for_swarm'] = false
        conf['swarm.flush_zombies.zombie_ttl'] = 4_000
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
      zombie_acquirer = client.current_acquirer_id
      zombie_lock = 'rql:lock:super-mega-long-lock'

      expect(client.locked?('super-mega-long-lock')).to eq(true)
      expect(client.zombie_locks).to include(zombie_lock)
      expect(client.zombie_acquirers).to include(zombie_acquirer)
      expect(client.zombie_hosts).to include(zombie_host)

      # try to flush them all
      aggregate_failures 'flush zombies' do
        result = client.flush_zombies
        expect(result).to match({
          ok: true,
          deleted_zombie_hosts: include(zombie_host),
          deleted_zombie_acquirers: include(zombie_acquirer),
          deleted_zombie_locks: include(zombie_lock)
        })
        expect(client.locked?('super-mega-long-lock')).to eq(false)
        expect(client.zombie_locks).to eq(Set.new)
        expect(client.zombie_acquirers).not_to include(zombie_acquirer)
        expect(client.zombie_hosts).not_to include(zombie_host)
      end
    end

    specify 'isolated swarm elements: independent ractors with their own ports' do
      client = RedisQueuedLocks::Client.new(redis)
      element1 = RedisQueuedLocks::Swarm::FlushZombies.new(client)
      element2 = RedisQueuedLocks::Swarm::FlushZombies.new(client)
      running_status = match({
        enabled: true,
        ractor: match({ running: true, state: eq('running').or(eq('blocking')) }),
        main_loop: match({ running: true, state: eq('sleep').or(eq('run')) })
      })

      element1.try_swarm!
      element2.try_swarm!

      aggregate_failures 'each element works in its own ractor via its own ports' do
        expect(element1.swarm_element).not_to eq(element2.swarm_element)
        expect(element1.swarm_element_results_port).not_to eq(element2.swarm_element_results_port)
        expect(element1.swarm_element_commands_port).not_to eq(element2.swarm_element_commands_port)
        expect(element1.status).to running_status
        expect(element2.status).to running_status
      end

      first_ractor = element1.swarm_element
      element1.send(:swarm_loop__stop)

      aggregate_failures 'stopped main loop does not affect another element' do
        expect(element1.status).to match({
          enabled: true,
          ractor: match({ running: true, state: eq('running').or(eq('blocking')) }),
          main_loop: match({ running: false, state: 'non_initialized' })
        })
        expect(element2.status).to running_status
      end

      aggregate_failures 'stopped main loop is restarted inside the same ractor' do
        element1.reswarm_if_dead!
        expect(element1.swarm_element).to eq(first_ractor)
        expect(element1.status).to running_status
      end

      element1.try_kill!

      aggregate_failures 'killed element ractor is finished, another element still works' do
        expect(element1.status).to match({
          enabled: true,
          ractor: match({ running: false, state: 'terminated' }),
          main_loop: match({ running: false, state: 'non_initialized' })
        })
        expect(element2.status).to running_status
      end

      aggregate_failures 'killed element is re-created in a new ractor' do
        element1.reswarm_if_dead!
        expect(element1.swarm_element).not_to eq(first_ractor)
        expect(element1.status).to running_status
      end
    ensure
      # NOTE: kill element ractors even when an expectation fails
      #   (they must not leak into other examples);
      element1&.try_kill!
      element2&.try_kill!
    end

    specify '#zombies_info: default zombie_ttl and lock_scan_size from config' do
      client = RedisQueuedLocks::Client.new(redis) do |conf|
        conf['swarm.flush_zombies.zombie_ttl'] = 7_000
        conf['swarm.flush_zombies.zombie_lock_scan_size'] = 123
      end
      allow(client.swarm).to receive(:zombies_info).and_call_original

      client.zombies_info

      expect(client.swarm).to have_received(:zombies_info).with(
        zombie_ttl: 7_000, lock_scan_size: 123
      )
    end

    specify '(auto-swarming!): zombie locks (with hosts and acquirers)' do
      main_client = RedisQueuedLocks::Client.new(redis) do |conf|
        conf['swarm.auto_swarm'] = true
        conf['swarm.probe_hosts.enabled_for_swarm'] = true
        conf['swarm.flush_zombies.enabled_for_swarm'] = false
        conf['swarm.flush_zombies.zombie_ttl'] = 6_000
        conf['swarm.flush_zombies.zombie_flush_period'] = 5
      end

      aggregate_failures 'no zombies at start' do
        expect(main_client.zombie_locks).to eq(Set.new) # empty set
        expect(main_client.zombie_hosts).to eq(Set.new) # empty set
        expect(main_client.zombie_acquirers).to eq(Set.new) # empty set

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
          conf['swarm.auto_swarm'] = true
          conf['swarm.probe_hosts.enabled_for_swarm'] = true
          conf['swarm.flush_zombies.enabled_for_swarm'] = false
        end

        outer_acquirer1 = client.current_acquirer_id
        outer_host1 = client.current_host_id

        client.swarmize!
        client.lock('long_lock', ttl: 500_000)
      end

      outer_thread2 = Thread.new do
        client = RedisQueuedLocks::Client.new(redis) do |conf|
          conf['swarm.auto_swarm'] = true
          conf['swarm.probe_hosts.enabled_for_swarm'] = true
          conf['swarm.flush_zombies.enabled_for_swarm'] = false
        end

        outer_acquirer2 = client.current_acquirer_id
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
        expect(main_client.zombie_acquirers).to eq(Set.new) # empty set

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
        expect(main_client.zombie_acquirers).to include(outer_acquirer1, outer_acquirer2)

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
        config['swarm.flush_zombies.enabled_for_swarm'] = true # enable zombie flusher
      end
      sleep(2 + 5) # wait for supervisor probe period (up zombie flusher) + zombie flush period
      sleep(1) # wait for zombie killing

      aggregate_failures 'zombies should be fully flushed' do
        expect(main_client.locked?('long_lock')).to eq(false) # lock is unlocked
        expect(main_client.locked?('another_long_lock')).to eq(false) # lock is unlocked
        expect(main_client.zombie_locks).to eq(Set.new) # no zombie locks
        expect(main_client.zombie_hosts).to eq(Set.new) # no zombie hosts
        expect(main_client.zombie_acquirers).to eq(Set.new) # no zombie acquirers
      end
    end
  end

  specify 'host identifier of the acquirer' do
    client = RedisQueuedLocks::Client.new(redis)

    aggregate_failures 'host of the current acquirer' do
      expect(
        RedisQueuedLocks::Resource.host_identifier_from_acquirer(client.current_acquirer_id)
      ).to eq(client.current_host_id)
    end

    aggregate_failures 'identity with slashes and multibyte symbols' do
      ['ид/ен/ти/ти', 'b30ec5e4bea10512', 'ключ'].each do |identity|
        acquirer_id = RedisQueuedLocks::Resource.acquirer_identifier(1, 22, 333, 4444, identity)
        expect(RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)).to eq(
          RedisQueuedLocks::Resource.host_identifier(1, 22, 4444, identity)
        )
      end
    end
  end

  specify 'lock key of the lock request queue (the debug method of Resource)' do
    resource = RedisQueuedLocks::Resource

    aggregate_failures 'write and read lock request queues' do
      ['my-lock', 'my_queue:a', 'rql:lock_queue:x', 'ключ'].each do |lock_name|
        expect(resource.lock_key_from_queue(resource.prepare_lock_queue(lock_name))).to eq(
          resource.prepare_lock_key(lock_name)
        )
        expect(resource.lock_key_from_queue(resource.prepare_read_lock_queue(lock_name))).to eq(
          resource.prepare_lock_key(lock_name)
        )
      end
    end

    aggregate_failures 'other keys' do
      expect(resource.lock_key_from_queue(resource.prepare_lock_key('my-lock'))).to eq(nil)
      expect(resource.lock_key_from_queue(resource.prepare_lock_readers('my-lock'))).to eq(nil)
      expect(resource.lock_key_from_queue('rql:lockX')).to eq(nil)
    end
  end

  specify ':random access strategy' do
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf['default_access_strategy'] = :random
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
      conf['default_access_strategy'] = :queued
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
      conf['default_access_strategy'] = :queued
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
      conf['instr_sampling_enabled'] = true
      conf['instr_sampling_percent'] = 10
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
      conf['instr_sampling_enabled'] = false
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
      conf['instr_sampling_enabled'] = true
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
      conf['log_lock_try'] = true
      conf['log_sampling_enabled'] = true
      conf['log_sampling_percent'] = 10
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
      conf['log_lock_try'] = true
      conf['log_sampling_enabled'] = false
      conf['log_sampling_percent'] = 15
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
      conf['log_lock_try'] = true
      conf['log_sampling_enabled'] = true
      conf['log_sampling_percent'] = 15
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
      config['default_conflict_strategy'] = :extendable_work_through
      config['log_lock_try'] = true
      config['logger'] = Logger.new(STDOUT)
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
      'acq_id', 'hst_id', 'ts', 'ini_ttl', 'lock_key', 'rem_ttl', 'rw_mode'
    )
    expect(lock_state1).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(5000),
      'lock_key' => eq('rql:lock:pek'),
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rw_mode',
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
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rw_mode',
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
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rem_ttl',
      'rw_mode'
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
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
    })

    # TODO: pokrit novie logi
  end

  specify 'reentrant locks - :work_through' do
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config['default_conflict_strategy'] = :work_through
      config['log_lock_try'] = true
      config['logger'] = Logger.new(STDOUT)
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
      'rem_ttl',
      'rw_mode'
    )
    expect(lock_state1).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rem_ttl',
      'rw_mode'
    )
    expect(lock_state2).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'spc_cnt' => eq(1),
      'l_spc_ts' => be_a(Float),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rem_ttl',
      'rw_mode'
    )
    expect(lock_state3).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'spc_cnt' => eq(2),
      'l_spc_ts' => be_a(Float),
      'lock_key' => eq('rql:lock:trukek'),
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rem_ttl',
      'rw_mode'
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
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
    })

    # TODO: pokrit novie logi
  end

  specify 'reentrant locks - :dead_locking' do
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config['default_conflict_strategy'] = :dead_locking
      config['log_lock_try'] = true
      config['logger'] = Logger.new(STDOUT)
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
      'rem_ttl',
      'rw_mode'
    )
    expect(lock_state1).to match({
      'acq_id' => be_a(String),
      'hst_id' => be_a(String),
      'ts' => be_a(Float),
      'ini_ttl' => eq(10_000),
      'lock_key' => eq('rql:lock:bekkek'),
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
      'rem_ttl',
      'rw_mode'
    )
    # CHECK: lock state does not change (except the `rem_ttl` key of course)
    expect(lock_state2).to match({
      'acq_id' => eq(lock_state1['acq_id']),
      'hst_id' => eq(lock_state1['hst_id']),
      'ts' => eq(lock_state1['ts']),
      'ini_ttl' => eq(lock_state1['ini_ttl']),
      'lock_key' => eq('rql:lock:bekkek'),
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
    # kill acquirers => requests will live in redis now (zombie requests! bu!)
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
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 }
      )
    })

    expect(client.queue_info('kek.dead.lock2')).to match({
      'lock_queue' => 'rql:lock_queue:kek.dead.lock2',
      'queue' => contain_exactly(
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 },
        { 'acq_id' => be_a(String), 'score' => be_a(Float), 'rw_mode' => 'write', 'priority' => 0 }
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

  # rubocop:disable Layout/LineLength
  specify 'logger interface (+ private API checks)' do
    aggregate_failures "valid logger's #debug interface" do
      # <method signature with 2 parameters>
      # f1 => [[:opt, :progname], [:block, :block]]
      # f2 => [[:req, :progname], [:block, :block]]
      # f3 => [[:rest], [:block, :block]]
      f1_logger = Class.new { def debug(progname = nil, &block); end; }.new
      f2_logger = Class.new { def debug(progname, &block); end; }.new
      f3_logger = Class.new { def debug(*, &block); end; }.new

      expect(RedisQueuedLocks::Logging.valid_interface?(f1_logger)).to eq(true) # NOTE: private API
      expect(RedisQueuedLocks::Logging.valid_interface?(f2_logger)).to eq(true) # NOTE: private API
      expect(RedisQueuedLocks::Logging.valid_interface?(f3_logger)).to eq(true) # NOTE: private API

      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f1_logger } }.not_to raise_error
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f2_logger } }.not_to raise_error
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f3_logger } }.not_to raise_error

      # <method signature with 1 parameters>
      # f4 => [[:opt, :progname]]
      # f5 => [[:req, :progname]]
      # f6 => [[:rest]]
      f4_logger = Class.new { def debug(progname = nil); end }.new
      f5_logger = Class.new { def debug(progname); end }.new
      f6_logger = Class.new { def debug(*); end }.new

      expect(RedisQueuedLocks::Logging.valid_interface?(f4_logger)).to eq(true) # NOTE: private API
      expect(RedisQueuedLocks::Logging.valid_interface?(f5_logger)).to eq(true) # NOTE: private API
      expect(RedisQueuedLocks::Logging.valid_interface?(f6_logger)).to eq(true) # NOTE: private API

      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f4_logger } }.not_to raise_error
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f5_logger } }.not_to raise_error
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f6_logger } }.not_to raise_error

      # <method signature with 3 parameters>
      # f7 => [[:rest, :*], [:keyrest, :**], [:block, :&]]
      f7_logger = Class.new { def debug(...); end }.new
      f8_logger = Class.new { def debug(*, **, &); end }.new # rubocop:disable all
      expect(RedisQueuedLocks::Logging.valid_interface?(f7_logger)).to eq(true) # NOTE: private API
      expect(RedisQueuedLocks::Logging.valid_interface?(f8_logger)).to eq(true) # NOTE: private API

      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f7_logger } }.not_to raise_error
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = f8_logger } }.not_to raise_error
    end

    aggregate_failures "invalid logger's #debug interface" do
      logger = Class.new { def debug; end }.new
      expect(RedisQueuedLocks::Logging.valid_interface?(logger)).to eq(false) # NOTE: private API
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = logger } }.to raise_error(RedisQueuedLocks::ConfigValidationError)

      logger = Class.new { def debug(a, b, c, &f); end }.new
      expect(RedisQueuedLocks::Logging.valid_interface?(logger)).to eq(false) # NOTE: private API
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = logger } }.to raise_error(RedisQueuedLocks::ConfigValidationError)

      logger = Object.new
      expect(RedisQueuedLocks::Logging.valid_interface?(logger)).to eq(false) # NOTE: private API
      expect { RedisQueuedLocks::Client.new(redis) { |c| c['logger'] = logger } }.to raise_error(RedisQueuedLocks::ConfigValidationError)
    end
  end
  # rubocop:enable Layout/LineLength

  specify 'logging' do
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
      conf['logger'] = test_logger
      conf['log_lock_try'] = true
      conf['default_queue_ttl'] = queue_ttl
      conf['default_access_strategy'] = acs_strat
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
      conf['logger'] = test_logger
      conf['log_lock_try'] = false
      conf['default_queue_ttl'] = queue_ttl
      conf['default_access_strategy'] = acs_strat
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
    expect(result[:result]).to eq({ extended_locks_count: 1 })
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

  specify 'lock ttl and ttl extension validation' do
    client = RedisQueuedLocks::Client.new(redis)

    aggregate_failures 'non-positive lock ttl (both modes)' do
      # NOTE: a write lock with a non-positive ttl was "obtained" with the lock key deleted by
      #   `PEXPIRE` in the obtaining transaction (no mutual exclusion)
      invalid_ttls = [0, -1_000]
      %i[write read].each do |mode|
        invalid_ttls.each do |ttl|
          expect do
            client.lock('ttl.args', ttl:, read_write_mode: mode)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
          expect do
            client.lock!('ttl.args', ttl:, read_write_mode: mode)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
          expect do
            client.lock('ttl.args', ttl:, read_write_mode: mode) { 1 + 1 }
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
          # NOTE: each lock ttl of the series includes the retry delay (a positive lock ttl)
          expect do
            client.lock_series('ttl.args.a', 'ttl.args.b', ttl:, read_write_mode: mode)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
        end
      end
      expect(client.locked?('ttl.args')).to eq(false)
      expect(client.locked?('ttl.args.a')).to eq(false)
      expect(client.keys).to be_empty
    end

    aggregate_failures 'non-positive default lock ttl' do
      expect do
        client.configure { |config| config['default_lock_ttl'] = 0 }
      end.to raise_error(RedisQueuedLocks::ConfigValidationError)
      expect do
        RedisQueuedLocks::Client.new(redis) { |config| config['default_lock_ttl'] = -1 }
      end.to raise_error(RedisQueuedLocks::ConfigValidationError)
      expect(client.config['default_lock_ttl']).to eq(5_000)
    end

    aggregate_failures 'non-positive ttl extension (both modes)' do
      client.lock('ttl.ext.write', ttl: 10_000)
      client.lock('ttl.ext.read', ttl: 10_000, read_write_mode: :read)

      [0, -20_000].each do |milliseconds|
        expect do
          client.extend_lock_ttl('ttl.ext.write', milliseconds)
        end.to raise_error(RedisQueuedLocks::ArgumentError, /milliseconds/)
        expect do
          client.extend_lock_ttl('ttl.ext.read', milliseconds, read_write_mode: :read)
        end.to raise_error(RedisQueuedLocks::ArgumentError, /milliseconds/)
        expect do
          client.extend_lock_ttl(
            'ttl.ext.read', milliseconds, read_write_mode: :read, all_read_locks: true
          )
        end.to raise_error(RedisQueuedLocks::ArgumentError, /milliseconds/)
      end

      # NOTE: the locks are neither deleted nor shortened
      expect(client.lock_info('ttl.ext.write')['rem_ttl']).to be > 9_000
      expect(client.lock_info('ttl.ext.read')['rem_ttl']).to be > 9_000
    end

    client.unlock('ttl.ext.write')
    client.unlock('ttl.ext.read')
    expect(client.keys).to be_empty
  end

  specify 'per-call numeric arguments: the same ranges as their config keys' do
    client = RedisQueuedLocks::Client.new(redis)
    non_positive = [0, -1]
    negative = [-1]

    aggregate_failures 'lock acquirement (#lock, #lock!, #lock_series)' do
      {
        queue_ttl: non_positive,
        timeout: negative,
        retry_count: negative,
        retry_delay: negative,
        retry_jitter: negative,
        lock_index_grace_period: negative
      }.each do |option, values|
        values.each do |value|
          options = { option => value }
          expect do
            client.lock('args.lock', **options)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /`:#{option}`/)
          expect do
            client.lock!('args.lock', **options)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /`:#{option}`/)
          expect do
            client.lock_series('args.series.a', 'args.series.b', **options)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /`:#{option}`/)
        end
      end
      expect(client.keys).to be_empty
    end

    aggregate_failures 'scan/batch sizes and ttls of the lock-iterating operations' do
      non_positive.each do |value|
        {
          scan_size: [
            -> { client.locks(scan_size: value) },
            -> { client.locks_info(scan_size: value) },
            -> { client.queues(scan_size: value) },
            -> { client.queues_info(scan_size: value) },
            -> { client.keys(scan_size: value) },
            -> { client.clear_dead_requests(scan_size: value) },
            -> { client.reindex_locks(scan_size: value) }
          ],
          batch_size: [-> { client.clear_locks(batch_size: value) }],
          lock_scan_size: [
            -> { client.clear_current_locks(lock_scan_size: value) },
            lambda do
              client.clear_locks_of(
                host_id: client.current_host_id, acquirer_id: client.current_acquirer_id,
                lock_scan_size: value
              )
            end
          ],
          queue_scan_size: [-> { client.clear_current_locks(queue_scan_size: value) }],
          dead_ttl: [-> { client.clear_dead_requests(dead_ttl: value) }],
          queue_ttl: [-> { client.reindex_locks(queue_ttl: value) }]
        }.each do |option, operations|
          operations.each do |operation|
            expect(&operation).to raise_error(RedisQueuedLocks::ArgumentError, /`:#{option}`/)
          end
        end
      end
      expect do
        client.reindex_locks(lock_index_grace_period: -1)
      end.to raise_error(RedisQueuedLocks::ArgumentError, /`:lock_index_grace_period`/)
    end

    aggregate_failures 'swarm actions (RedisQueuedLocks::SwarmArgumentError)' do
      non_positive.each do |value|
        {
          zombie_ttl: [
            -> { client.swarm_info(zombie_ttl: value) },
            -> { client.flush_zombies(zombie_ttl: value) },
            -> { client.zombie_locks(zombie_ttl: value) },
            -> { client.zombie_acquirers(zombie_ttl: value) },
            -> { client.zombie_hosts(zombie_ttl: value) },
            -> { client.zombies_info(zombie_ttl: value) }
          ],
          lock_scan_size: [
            -> { client.flush_zombies(lock_scan_size: value) },
            -> { client.zombie_locks(lock_scan_size: value) },
            -> { client.zombie_acquirers(lock_scan_size: value) },
            -> { client.zombies_info(lock_scan_size: value) }
          ],
          queue_scan_size: [-> { client.flush_zombies(queue_scan_size: value) }]
        }.each do |option, operations|
          operations.each do |operation|
            expect(&operation).to raise_error(RedisQueuedLocks::SwarmArgumentError, /`:#{option}`/)
          end
        end
      end
    end
  end

  specify 'config validation: positive ttls, periods and batch sizes' do
    positive_keys = %w[
      default_lock_ttl default_queue_ttl dead_request_ttl
      lock_release_batch_size clear_locks_of__lock_scan_size clear_locks_of__queue_scan_size
      key_extraction_batch_size
      swarm.supervisor.liveness_probing_period swarm.probe_hosts.probe_period
      swarm.flush_zombies.zombie_ttl swarm.flush_zombies.zombie_flush_period
      swarm.flush_zombies.zombie_lock_scan_size swarm.flush_zombies.zombie_queue_scan_size
    ]
    invalid_values = [0, -1]

    aggregate_failures 'non-positive values are rejected, positive values are accepted' do
      positive_keys.each do |key|
        invalid_values.each do |value|
          expect do
            RedisQueuedLocks::Client.new(redis) { |config| config[key] = value }
          end.to raise_error(RedisQueuedLocks::ConfigValidationError, /#{Regexp.escape(key)}/)
        end
        client = RedisQueuedLocks::Client.new(redis) { |config| config[key] = 1 }
        expect(client.config[key]).to eq(1)
      end
    end
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
      'rw_mode' => 'write', # reserved
      'chuk' => '321', # <custom meta> (expectation)
      'buk' => '123' # <custom meta> (expectation)
    })

    aggregate_failures 'reserved keys' do
      expect do
        client.lock('bum.bum.bam.bam', ttl: 5_000, meta: { 'acq_id' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError)
      expect(client.locked?('bum.bum.bam.bam')).to eq(false)

      # NOTE: (RW) lock mode key of lock info
      %i[write read].each do |mode|
        expect do
          client.lock(
            'bum.bum.bam.bam', ttl: 5_000, read_write_mode: mode, meta: { 'rw_mode' => 'kek' }
          )
        end.to raise_error(RedisQueuedLocks::ArgumentError, /rw_mode/)
        expect(client.locked?('bum.bum.bam.bam')).to eq(false)
      end
      expect do
        client.lock_series('bum.a', 'bum.b', ttl: 5_000, meta: { 'rw_mode' => 'kek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError, /rw_mode/)
      expect(client.locked?('bum.a')).to eq(false)

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

    aggregate_failures 'reserved keys (Symbol keys are written to the lock data as Strings)' do
      reserved_keys = %i[
        acq_id hst_id ts ini_ttl lock_key rem_ttl
        spc_ext_ttl spc_cnt l_spc_ext_ini_ttl l_spc_ext_ts l_spc_ts rw_mode
      ]
      modes = %i[write read]

      reserved_keys.each do |reserved_key|
        modes.each do |mode|
          expect do
            client.lock(
              'bum.bum.bam.bam', ttl: 5_000, read_write_mode: mode, meta: { reserved_key => 'kek' }
            )
          end.to raise_error(RedisQueuedLocks::ArgumentError, /reserved lock data keys/)
          expect(client.locked?('bum.bum.bam.bam')).to eq(false)

          expect do
            client.lock_series(
              'bum.a', 'bum.b', ttl: 5_000, read_write_mode: mode, meta: { reserved_key => 'kek' }
            )
          end.to raise_error(RedisQueuedLocks::ArgumentError, /reserved lock data keys/)
          expect(client.locked?('bum.a')).to eq(false)
          expect(client.locked?('bum.b')).to eq(false)
        end
      end

      # NOTE: non-reserved Symbol keys are custom meta
      client.lock('sym.meta', ttl: 5_000, meta: { chuk: '321', buk: 123 })
      expect(client.lock_info('sym.meta')).to include('chuk' => '321', 'buk' => '123')
      client.unlock('sym.meta')
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
      conf['instrumenter'] = test_notifier
    end

    expect(test_notifier.notifications).to be_empty
    client.lock('kek-pek-cheburgen', instrument: { test: :ok })
    expect(test_notifier.notifications.size).to eq(1)
    expect(test_notifier.notifications[0][:payload][:instrument]).to eq({ test: :ok })
    client.lock('bum-bum-pek-mek')
    expect(test_notifier.notifications.size).to eq(2)
    expect(test_notifier.notifications[1][:payload][:instrument]).to eq(nil)
  end

  specify 'log and instrumentation samplers: <sampling_percent>% of invocations' do
    samplers = [RedisQueuedLocks::Logging::Sampler, RedisQueuedLocks::Instrument::Sampler]

    aggregate_failures 'the boundaries (one of 100 equally probable values)' do
      samplers.each do |sampler|
        allow(SecureRandom).to receive(:rand).with(100).and_return(0)
        expect(sampler.sampling_happened?(0)).to eq(false)
        expect(sampler.sampling_happened?(1)).to eq(true)
        allow(SecureRandom).to receive(:rand).with(100).and_return(15)
        expect(sampler.sampling_happened?(15)).to eq(false)
        expect(sampler.sampling_happened?(16)).to eq(true)
        allow(SecureRandom).to receive(:rand).with(100).and_return(99)
        expect(sampler.sampling_happened?(99)).to eq(false)
        expect(sampler.sampling_happened?(100)).to eq(true)
      end
    end

    aggregate_failures '0% => never, 100% => always' do
      allow(SecureRandom).to receive(:rand).and_call_original
      samplers.each do |sampler|
        expect(Array.new(10_000) { sampler.sampling_happened?(0) }).to all(eq(false))
        expect(Array.new(10_000) { sampler.sampling_happened?(100) }).to all(eq(true))
      end
    end
  end

  specify 'operations that change keys: one log and one instrumentation event per operation' do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new
    test_logger = Class.new do
      attr_reader :logs

      def initialize
        @logs = []
      end

      def debug(progname = nil, &block)
        logs << (block ? yield : progname)
      end
    end.new

    client = RedisQueuedLocks::Client.new(redis) do |config|
      config['instrumenter'] = test_notifier
      config['logger'] = test_logger
    end
    reported = lambda do |event|
      [
        test_notifier.notifications.select { |notification| notification[:event] == event },
        test_logger.logs.grep(/\A\[#{Regexp.escape(event)}\] /)
      ]
    end

    client.lock('obs.write', ttl: 10_000)
    client.lock('obs.read', ttl: 10_000, read_write_mode: :read)

    aggregate_failures 'extend_lock_ttl' do
      client.extend_lock_ttl('obs.write', 1_000, instrument: { op: :extend })
      client.extend_lock_ttl('obs.missing', 1_000)
      events, logs = reported.call('redis_queued_locks.extend_lock_ttl')
      expect(events.map { |event| event[:payload] }).to contain_exactly(
        match({
          lock_key: 'rql:lock:obs.write', rw_mode: :write, all_read_locks: false, ext_ttl: 1_000,
          extended_locks_count: 1, ext_time: be_a(Numeric), at: be_a(Float),
          instrument: { op: :extend }
        }),
        match({
          lock_key: 'rql:lock:obs.missing', rw_mode: :write, all_read_locks: false, ext_ttl: 1_000,
          extended_locks_count: 0, ext_time: be_a(Numeric), at: be_a(Float), instrument: nil
        })
      )
      expect(logs.size).to eq(2)
      expect(logs.first).to include(
        "lock_key => 'rql:lock:obs.write' rw_mode => 'write' all_read_locks => false " \
        "ext_ttl => 1000 extended_locks_count => 1 ext_time => "
      )
    end

    aggregate_failures 'unlock and unlock_read' do
      client.unlock_read('obs.read', instrument: { op: :unlock_read })
      client.unlock('obs.write', instrument: { op: :unlock })
      events, logs = reported.call('redis_queued_locks.explicit_lock_release')
      expect(events.map { |event| event[:payload] }).to contain_exactly(match({
        lock_key: 'rql:lock:obs.write', lock_key_queue: 'rql:lock_queue:obs.write',
        rel_time: be_a(Numeric), at: be_a(Float), instrument: { op: :unlock }
      }))
      expect(logs.size).to eq(1)
      events, logs = reported.call('redis_queued_locks.explicit_read_lock_release')
      expect(events.map { |event| event[:payload][:instrument] }).to eq([{ op: :unlock_read }])
      expect(logs.size).to eq(1)
    end

    aggregate_failures 'clear_locks, clear_current_locks, clear_dead_requests, reindex_locks' do
      client.lock('obs.a', ttl: 10_000)
      client.clear_locks(instrument: { op: :clear_locks })
      client.lock('obs.b', ttl: 10_000)
      client.clear_current_locks(instrument: { op: :clear_current_locks })
      client.clear_dead_requests(dead_ttl: 1, instrument: { op: :clear_dead_requests })
      client.reindex_locks(instrument: { op: :reindex_locks })

      {
        'redis_queued_locks.explicit_all_locks_release' => {
          at: be_a(Float), rel_time: be_a(Numeric), rel_key_cnt: be_a(Integer),
          instrument: { op: :clear_locks }
        },
        'redis_queued_locks.release_locks_of' => {
          at: be_a(Float), hst_id: client.current_host_id, acq_id: client.current_acquirer_id,
          rel_time: be_a(Numeric), rel_key_cnt: 1, tch_queue_cnt: be_a(Integer),
          instrument: { op: :clear_current_locks }
        },
        'redis_queued_locks.clear_dead_requests' => {
          dead_ttl: 1, prc_queue_cnt: be_a(Integer), rel_time: be_a(Numeric), at: be_a(Float),
          instrument: { op: :clear_dead_requests }
        },
        'redis_queued_locks.reindex_locks' => {
          idx_key_cnt: be_a(Integer), idx_time: be_a(Numeric), at: be_a(Float),
          instrument: { op: :reindex_locks }
        }
      }.each do |event_name, payload|
        events, logs = reported.call(event_name)
        expect(events.map { |event| event[:payload] }).to contain_exactly(match(payload))
        expect(logs.size).to eq(1)
      end
    end

    aggregate_failures 'lock info queries: no logs and no instrumentation' do
      client.lock('obs.info', ttl: 10_000)
      test_notifier.notifications.clear
      test_logger.logs.clear

      client.locked?('obs.info')
      client.queued?('obs.info')
      client.lock_info('obs.info')
      client.queue_info('obs.info')
      client.locks
      client.locks_info
      client.queues
      client.queues_info
      client.keys

      expect(test_notifier.notifications).to be_empty
      expect(test_logger.logs).to be_empty
      client.unlock('obs.info')
    end
  end

  specify 'lock_obtaining_failed: logs and instrumentation of the failed lock acquirement' do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new
    test_logger = Class.new do
      attr_reader :logs

      def initialize
        @logs = []
      end

      def debug(progname = nil, &block)
        logs << (block ? yield : progname)
      end
    end.new

    holder = RedisQueuedLocks::Client.new(redis)
    holder.lock('obs.busy', ttl: 30_000)
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config['instrumenter'] = test_notifier
      config['logger'] = test_logger
      config['retry_delay'] = 10
      config['retry_jitter'] = 0
    end
    failures = lambda do
      test_notifier.notifications.filter_map do |notification|
        notification[:payload] if notification[:event] == 'redis_queued_locks.lock_obtaining_failed'
      end
    end
    failure_payload = lambda do |lock_key, rw_mode, ttl, result, instrument|
      match({
        lock_key:, rw_mode:, priority: 0, ttl:, acq_id: client.current_acquirer_id,
        hst_id: client.current_host_id, ts: be_a(Float), acq_time: be_a(Numeric), result:,
        instrument:
      })
    end

    aggregate_failures 'the failure result (without exceptions)' do
      client.lock('obs.busy', ttl: 5_000, fail_fast: true, instrument: { op: :fail_fast })
      client.lock('obs.busy', ttl: 5_000, retry_count: 2, read_write_mode: :read)
      expect(failures.call).to contain_exactly(
        failure_payload.call(
          'rql:lock:obs.busy', :write, 5_000, :fail_fast_no_try, { op: :fail_fast }
        ),
        failure_payload.call('rql:lock:obs.busy', :read, 5_000, :retry_limit_reached, nil)
      )
      failure_logs = test_logger.logs.grep(/\A\[redis_queued_locks\.lock_obtaining_failed\] /)
      expect(failure_logs).to contain_exactly(
        include("lock_key => 'rql:lock:obs.busy'").and(include("result => 'fail_fast_no_try'")),
        include("rw_mode => 'read'").and(include("result => 'retry_limit_reached'"))
      )
    end

    aggregate_failures 'raised errors: reported before the error is raised' do
      test_notifier.notifications.clear
      expect do
        client.lock!('obs.busy', ttl: 5_000, retry_count: 1)
      end.to raise_error(RedisQueuedLocks::LockAcquirementRetryLimitError)
      expect do
        client.lock!('obs.busy', ttl: 5_000, timeout: 1, retry_count: nil, retry_delay: 100)
      end.to raise_error(RedisQueuedLocks::LockAcquirementTimeoutError)
      expect(failures.call).to contain_exactly(
        failure_payload.call('rql:lock:obs.busy', :write, 5_000, :retry_limit_reached, nil),
        failure_payload.call('rql:lock:obs.busy', :write, 5_000, :timeout_reached, nil)
      )
    end

    aggregate_failures 'errors of the block of code under the obtained lock are not reported' do
      test_notifier.notifications.clear
      expect do
        client.lock('obs.free', ttl: 5_000) { raise RedisQueuedLocks::LockAlreadyObtainedError }
      end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
      expect(failures.call).to be_empty
    end

    aggregate_failures 'lock series: the lock of the series that is not obtained' do
      test_notifier.notifications.clear
      client.lock_series('obs.series', 'obs.busy', ttl: 5_000, fail_fast: true) { :never }
      expect(failures.call).to contain_exactly(
        failure_payload.call('rql:lock:obs.busy', :write, be_a(Integer), :fail_fast_no_try, nil)
      )
      expect(client.locked?('obs.series')).to eq(false)
    end

    holder.unlock('obs.busy')
  end

  specify 'detailed lock acquirement timeout error' do
    redis = RedisClient.config.new_pool(
      # NOTE:
      #   - long connect_/read_/write_ timeouts is used for problems inside the github runners
      #     in RBS tests where all our code is "totally slow"
      #     (and each spec can fail on 1.0-seconds-timeout with Socket's timeout error);
      #   - long <timeout:> is used for some test-cases;
      timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
    )
    client = RedisQueuedLocks::Client.new(redis) do |config|
      # NOTE: false by default
      # config['detailed_acq_timeout_error'] = false
    end

    client.lock('some-long-lock', ttl: 30_000)

    expect do
      client.lock('some-long-lock', timeout: 2, retry_count: nil, raise_errors: true)
    end.to raise_error(RedisQueuedLocks::LockAcquirementTimeoutError)

    common_timeout_error = begin
      client.lock('some-long-lock', timeout: 2, retry_count: nil, raise_errors: true)
    rescue RedisQueuedLocks::LockAcquirementTimeoutError => error
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
    rescue RedisQueuedLocks::LockAcquirementTimeoutError => error
      error
    end

    aggregate_failures 'detailed error message content' do
      expect(detailed_timeout_error.message).to include('<2 seconds> timeout.')
      expect(detailed_timeout_error.message).to include('the lock "rql:lock:some-long-lock"')
      expect(detailed_timeout_error.message).to include('<Lock Data>')
      expect(detailed_timeout_error.message).not_to include('<Lock Data> => <no_data>')
      expect(detailed_timeout_error.message).to include('<Queue Data> => <no_data>')
    end

    # NOTE: the waiter gives up on its own (bounded timeout) and is joined at the end:
    #   an unbounded waiter outlives the example and obtains the lock in the next one;
    waiter = Thread.new do
      client.lock('some-long-lock', ttl: 30_000, timeout: 3, retry_count: nil)
    end

    detailed_timeout_error = begin
      client.lock(
        'some-long-lock',
        timeout: 2,
        retry_count: nil,
        raise_errors: true,
        detailed_acq_timeout_error: true
      )
    rescue RedisQueuedLocks::LockAcquirementTimeoutError => error
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

    waiter.join
    redis.close
  end

  specify 'timed lock' do
    redis = RedisClient.config.new_pool(
      # NOTE:
      #   - long connect_/read_/write_ timeouts is used for problems inside the github runners
      #     in RBS tests where all our code is "totally slow"
      #     (and each spec can fail on 1.0-seconds-timeout with Socket's timeout error);
      #   - long <timeout:> is used for some test-cases;
      timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
    )
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
      expect(timed_lock_error.message).to include("acq_id: \"#{client.current_acquirer_id}\"")
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
        "acq_id: \"#{client.current_acquirer_id}\""
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

  specify 'internal timeouts: the timed block can not swallow the timeout' do
    client = RedisQueuedLocks::Client.new(redis)

    # NOTE: the internal timeouts are not StandardErrors (the user block can not rescue them)
    aggregate_failures 'timed lock: rescue inside the block' do
      swallowed = []
      reached = []
      ensured = []

      user_blocks = {
        'rescue StandardError' => proc do
          sleep(2)
        rescue StandardError => error
          swallowed << error
        end,
        'rescue Timeout::Error' => proc do
          sleep(2)
        rescue Timeout::Error => error
          swallowed << error
        end,
        'rescue nil' => proc { sleep(2) rescue nil },
        'ensure' => proc do
          sleep(2)
        ensure
          ensured << :ensure
        end
      }

      user_blocks.each do |case_name, user_block|
        expect do
          client.lock('internal.timeouts.timed', timed: true, ttl: 500) do
            user_block.call
            reached << case_name
          end
        end.to raise_error(RedisQueuedLocks::TimedLockTimeoutError)
        expect(client.locked?('internal.timeouts.timed')).to eq(false)
      end

      expect(swallowed).to be_empty
      expect(reached).to be_empty
      expect(ensured).to eq([:ensure]) # NOTE: `ensure` of the block still works
    end
  end

  specify 'internal timeouts: the logger can not swallow the acquirement timeout' do
    aggregate_failures 'acquirement timeout: the logger is interrupted inside the WATCH block' do
      # NOTE: one connection: the next transaction uses the connection of the interrupted attempt
      single_connection_redis = RedisClient.config(db: 0).new_pool(
        timeout: 5, size: 1, connect_timeout: 5, read_timeout: 5, write_timeout: 5
      )
      slow_logger = Class.new do
        attr_reader :slowed

        def initialize
          @slowed = false
        end

        def debug(progname = nil, &block)
          message = block ? yield : progname
          # NOTE: the first attempt (with WATCH) logs the obtained lock inside the WATCH block:
          #   the timeout interrupts the logger (`rescue nil` of the log visitor can not swallow it)
          return if @slowed || !message.to_s.include?('try_lock.exit__lock_still_obtained')

          @slowed = true
          sleep(3)
        end
      end.new

      holder = RedisQueuedLocks::Client.new(redis)
      holder.lock('internal.timeouts.acq', ttl: 10_000)
      acquirer = RedisQueuedLocks::Client.new(single_connection_redis) do |config|
        config['logger'] = slow_logger
        config['log_lock_try'] = true
      end

      # NOTE: a swallowed timeout => the retries continue => :retry_limit_reached
      result = acquirer.lock(
        'internal.timeouts.acq', ttl: 5_000, timeout: 1, retry_count: 3, retry_delay: 10
      )
      expect(slow_logger.slowed).to eq(true)
      expect(result).to match({ ok: false, result: :timeout_reached })

      # NOTE: a watched key is changed: a transaction on the connection with the active WATCH of
      #   the interrupted attempt would be aborted (`nil`)
      holder.unlock('internal.timeouts.acq')
      transaction_result = single_connection_redis.multi do |transaction|
        transaction.call('SET', 'internal.timeouts.probe', '1')
      end
      expect(transaction_result).to eq(['OK'])

      single_connection_redis.call('DEL', 'internal.timeouts.probe')
      single_connection_redis.close
    end
  end

  specify 'user timeouts (`Timeout.timeout` without a class): no WATCH left on the connection' do
    # NOTE: one connection: the next transaction uses the connection of the interrupted attempt
    single_connection_redis = RedisClient.config(db: 0).new_pool(
      timeout: 5, size: 1, connect_timeout: 5, read_timeout: 5, write_timeout: 5
    )
    slow_logger = Class.new do
      attr_reader :slowed

      def initialize
        @slowed = false
      end

      def debug(progname = nil, &block)
        message = block ? yield : progname
        # NOTE: the first attempt (with WATCH) logs the obtained lock inside the WATCH block:
        #   the user's timeout (`Timeout::ExitException`) interrupts it there
        return if @slowed || !message.to_s.include?('try_lock.exit__lock_still_obtained')

        @slowed = true
        sleep(3)
      end
    end.new

    holder = RedisQueuedLocks::Client.new(redis)
    holder.lock('user.timeouts.acq', ttl: 10_000)
    acquirer = RedisQueuedLocks::Client.new(single_connection_redis) do |config|
      config['logger'] = slow_logger
      config['log_lock_try'] = true
    end

    expect do
      Timeout.timeout(1) do
        acquirer.lock(
          'user.timeouts.acq', ttl: 5_000, timeout: nil, retry_count: 3, retry_delay: 10
        )
      end
    end.to raise_error(Timeout::Error)
    expect(slow_logger.slowed).to eq(true)

    # NOTE: a watched key is changed: a transaction on the connection with the active WATCH of
    #   the interrupted attempt would be aborted (`nil`)
    holder.unlock('user.timeouts.acq')
    transaction_result = single_connection_redis.multi do |transaction|
      transaction.call('SET', 'user.timeouts.probe', '1')
    end
    expect(transaction_result).to eq(['OK'])

    single_connection_redis.call('DEL', 'user.timeouts.probe')
    single_connection_redis.close
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
    end.to raise_error(RedisQueuedLocks::LockAcquirementRetryLimitError)

    expect do
      client.lock!('some-kek-super-pek', retry_count: 1, timeout: 1)
    end.to raise_error(RedisQueuedLocks::LockAcquirementRetryLimitError)
  end

  specify 'requeue after queue_ttl: the lock request is queued again in the same attempt' do
    # NOTE: the lock request that waits longer than its `queue_ttl` gets a new position on the next
    #   attempt (`dead_score_reached__reset_acquirer_position`); the queueing drops the dead
    #   requests (its old position too) before `ZADD NX`, so the new position is queued in the same
    #   attempt (each waiter is alone in its lock queue: no other lock request drops its old
    #   position before it); both modes wait for the write lock of the holder (in parallel: each
    #   waiter is a separate acquirer);
    test_logger = Class.new do
      attr_reader :logs

      def initialize
        @logs = []
      end

      def debug(progname = nil, &block)
        logs << (block ? yield : progname)
      end
    end.new
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config['logger'] = test_logger
      config['log_lock_try'] = true
    end
    holder_client = RedisQueuedLocks::Client.new(redis)
    waiters = %i[write read].to_h do |read_write_mode|
      holder_client.lock("requeue.#{read_write_mode}", ttl: 2_500)
      waiter = Thread.new do
        client.lock(
          "requeue.#{read_write_mode}",
          read_write_mode:, queue_ttl: 1, retry_count: nil, retry_delay: 100, retry_jitter: 0,
          timeout: 10
        )
      end
      [read_write_mode, waiter]
    end
    logs = lambda do |event, read_write_mode|
      test_logger.logs.grep(
        /\A\[redis_queued_locks\.#{event}\] lock_key => 'rql:lock:requeue\.#{read_write_mode}' /
      )
    end

    aggregate_failures 'write and read lock requests' do
      waiters.each do |read_write_mode, waiter|
        expect(waiter.value).to match({
          ok: true,
          result: hash_including(lock_key: "rql:lock:requeue.#{read_write_mode}")
        })
        expect(
          logs.call('dead_score_reached__reset_acquirer_position', read_write_mode)
        ).not_to be_empty
        # NOTE: the requeued lock request is never missing in its lock queue
        expect(logs.call('try_lock\.exit__queue_ttl_reached', read_write_mode)).to be_empty
      end
    end

    waiters.each_key { |read_write_mode| client.unlock("requeue.#{read_write_mode}") }
    expect(client.keys).to be_empty
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
      'rem_ttl' => be_a(Integer),
      'rw_mode' => 'write'
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
        match({
          'acq_id' => be_a(String), 'score' => be_a(Numeric), 'rw_mode' => 'write', 'priority' => 0
        }),
        match({
          'acq_id' => be_a(String), 'score' => be_a(Numeric), 'rw_mode' => 'write', 'priority' => 0
        })
      ])
    })

    thread_a.join
    thread_b.join
  end

  specify 'release locks of the concrete acquirer and host' do
    test_notifier = Class.new do
      attr_reader :notifications
      attr_reader :redis_storage_client
      attr_reader :last_in_memory_rlo_event

      def initialize(redis_storage_client)
        @redis_storage_client = redis_storage_client
        @last_in_memory_rlo_event = nil
      end

      def notify(event, payload = {})
        if event == 'redis_queued_locks.release_locks_of'
          @last_in_memory_rlo_event = payload
        end

        redis_storage_client.call('LPUSH', 'rlo_notifs', JSON.dump({
          event:,
          payload:
        }))
      end

      def events
        # NOTE:
        #   - don't worry about the ideal ways of data extraction
        #   - see the line #3 of this file
        redis_storage_client.call('LRANGE', 'rlo_notifs', 0, 100).map { |event| JSON.parse(event) }
      end

      def release_locks_of__events
        events.select { |event| event['event'] == 'redis_queued_locks.release_locks_of' }
      end
    end.new(redis)

    client = RedisQueuedLocks::Client.new(redis) do |config|
      config['instrumenter'] = test_notifier
      config['clear_locks_of__lock_scan_size'] = 150 # NOTE: new configs
      config['clear_locks_of__queue_scan_size'] = 250 # NOTE: new configs
    end

    redis.call('FLUSHDB')

    fork do
      in_fork__redis = RedisClient.config(db: 0).new_pool(
        # NOTE:
        #   - long connect_/read_/write_ timeouts is used for problems inside the github runners
        #     in RBS tests where all our code is "totally slow"
        #     (and each spec can fail on 1.0-seconds-timeout with Socket's timeout error);
        #   - long <timeout:> is used for some test-cases;
        timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
      )
      in_fork__test_notifier = Class.new do
        attr_reader :notifications
        attr_reader :redis_storage_client

        def initialize(redis_storage_client)
          @redis_storage_client = redis_storage_client
        end

        def notify(event, payload = {})
          redis_storage_client.call('LPUSH', 'rlo_notifs', JSON.stringify({
            event:,
            payload:
          }))
        end
      end.new(in_fork__redis)

      in_fork__client = RedisQueuedLocks::Client.new(in_fork__redis) do |config|
        config['instrumenter'] = in_fork__test_notifier
      end

      # create some long living lock
      in_fork__client.lock('super-mega-long-lock-1', ttl: 500_000)

      # produce zombie acq in lock queue
      Thread.new do
        in_fork__redis.call(
          'HSET',
          'in-fork--host-info',
          'side_thread__acq_id', in_fork__client.current_acquirer_id,
          'side_thread__hst_id', in_fork__client.current_host_id
        )
        in_fork__client.lock(
          'super-mega-long-lock-1',
          ttl: 500_000, retry_count: nil, timeout: nil
        )
      end

      sleep(1)

      in_fork__redis.call(
        'HSET',
        'in-fork--host-info',
        'main_thread__acq_id', in_fork__client.current_acquirer_id,
        'main_thread__hst_id', in_fork__client.current_host_id
      )
    end

    sleep(3)

    client.lock('super-mega-long-lock-2', ttl: 500_000)

    # NOTE: we should have 2 locks for now
    aggregate_failures 'current state: locks, queues' do
      expect(client.locks).to contain_exactly(
        'rql:lock:super-mega-long-lock-1', # from another process
        'rql:lock:super-mega-long-lock-2' # from the current process
      )

      # no empty queues, just one queue with just one acquirer inside
      expect(client.queues).to contain_exactly(
        'rql:lock_queue:super-mega-long-lock-1'
      )
    end

    # rubocop:disable all
    in_fork_client_info = redis.call('HMGET', 'in-fork--host-info',
      'side_thread__acq_id', 'side_thread__hst_id',
      'main_thread__acq_id', 'main_thread__hst_id'
    )
    # rubocop:enable all

    # rubocop:disable Layout/LineLength
    in_fork__side_thread__acq_id = in_fork_client_info[0] # <--- without any keys, just only has a position in queue
    in_fork__side_thread__hst_id = in_fork_client_info[1] # <--- without any keys, just only has a position in queue

    in_fork__main_thread__acq_id = in_fork_client_info[2] # <--- holds super-mega-long-lock-1
    in_fork__main_thread__hst_id = in_fork_client_info[3] # <--- holds super-mega-long-lock-1
    # rubocop:enable Layout/LineLength

    aggregate_failures 'in_fork__side_thread: remove from the queue' do
      expect(client.queues).to contain_exactly(
        'rql:lock_queue:super-mega-long-lock-1'
      )

      expect(test_notifier.release_locks_of__events.size).to eq(0)

      # NOTE:
      #   - drop "waiting hst/acq" => our queue should be empty after that;
      #   - no any lock will be dropped cuz side thread does not acquire any lock;
      result = client.release_locks_of(
        host_id: in_fork__side_thread__hst_id,
        acquirer_id: in_fork__side_thread__acq_id
      )

      expect(test_notifier.release_locks_of__events.size).to eq(1)

      expect(result).to match({
        ok: true,
        result: match({
          rel_key_cnt: 0, # <-- no any key is cleared for side__thread
          tch_queue_cnt: 1, # <-- side_thread-acquirer is removed from the queue
          rel_time: be_a(Numeric)
        })
      })

      expect(client.queues).to be_empty # <-- side_thread-aqcuirer is removed from the queue
    end

    aggregate_failures 'in_fork__main_thread: remove all locks' do
      expect(client.locks).to contain_exactly(
        'rql:lock:super-mega-long-lock-1', # in_form__main_thread
        'rql:lock:super-mega-long-lock-2' # current_process
      )

      expect(test_notifier.release_locks_of__events.size).to eq(1)

      result = client.release_locks_of(
        host_id: in_fork__main_thread__hst_id,
        acquirer_id: in_fork__main_thread__acq_id
      )

      expect(test_notifier.release_locks_of__events.size).to eq(2)

      # rubocop:disable Layout/LineLength
      expect(result).to match({
        ok: true,
        result: match({
          rel_key_cnt: 1, # <-- removed locks from in_fork__main_thread
          tch_queue_cnt: 0, # <-- no any queue is "touched" cuz main_thread "is not inside the any queue"
          rel_time: be_a(Numeric)
        })
      })
      # rubocop:enable Layout/LineLength

      # NOTE: 'rql:lock:super-mega-long-lock-1' from in_fork__main_thread is removed
      expect(client.locks).to contain_exactly(
        'rql:lock:super-mega-long-lock-2' # current_process
      )
    end

    aggregate_failures 'current process: remove current locks' do
      expect(client.locks).to contain_exactly(
        'rql:lock:super-mega-long-lock-2' # current_process holds this lock
      )

      expect(test_notifier.release_locks_of__events.size).to eq(2)

      result = client.release_locks_of(
        host_id: client.current_host_id,
        acquirer_id: client.current_acquirer_id
      )

      expect(test_notifier.release_locks_of__events.size).to eq(3)

      # rubocop:disable Layout/LineLength
      expect(result).to match({
        ok: true,
        result: match({
          rel_key_cnt: 1, # <-- removed locks from current process
          tch_queue_cnt: 0, # <-- no any queue is "touched" cuz current process "is not inside the any queue"
          rel_time: be_a(Numeric)
        })
      })
      # rubocop:enable Layout/LineLength
      #
      expect(client.locks).to be_empty
    end

    aggregate_failures 'clear_current_locks: remove locks hosted by the current process' do
      client.lock('super-mega-long-lock-3', ttl: 500_000)

      fork do
        in_fork__redis = RedisClient.config(db: 0).new_pool(
          # NOTE:
          #   - long connect_/read_/write_ timeouts is used for problems inside the github runners
          #     in RBS tests where all our code is "totally slow"
          #     (and each spec can fail on 1.0-seconds-timeout with Socket's timeout error);
          #   - long <timeout:> is used for some test-cases;
          timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
        )
        in_fork__client = RedisQueuedLocks::Client.new(in_fork__redis)

        # create some long living lock
        in_fork__client.lock('super-mega-long-lock-4', ttl: 500_000)
        sleep(1)
      end

      sleep(2)

      expect(test_notifier.release_locks_of__events.size).to eq(3)

      expect(client.locks).to contain_exactly(
        'rql:lock:super-mega-long-lock-3', # from current process
        'rql:lock:super-mega-long-lock-4' # from forked process
      )

      result = client.release_current_locks
      expect(test_notifier.release_locks_of__events.size).to eq(4)
      # rubocop:disable Layout/LineLength
      expect(result).to match({
        ok: true,
        result: match({
          rel_key_cnt: 1, # <-- removed locks from current process
          tch_queue_cnt: 0, # <-- no any queue is "touched" cuz current process "is not inside the any queue"
          rel_time: be_a(Numeric)
        })
      })
      # rubocop:enable Layout/LineLength

      expect(client.locks).to contain_exactly(
        'rql:lock:super-mega-long-lock-4' # <-- from forked process
      )
    end

    aggregate_failures 'instrumentation event structure' do
      # NOTE: four events
      expect(test_notifier.release_locks_of__events.size).to eq(4)
      # NOTE: check any of them for the correct structure
      expect(test_notifier.release_locks_of__events.sample['payload']).to match({
        'at' => be_a(Float),
        'hst_id' => be_a(String),
        'acq_id' => be_a(String),
        'rel_time' => be_a(Numeric),
        'rel_key_cnt' => be_a(Integer),
        'tch_queue_cnt' => be_a(Integer),
        'instrument' => nil
      })
      expect(test_notifier.last_in_memory_rlo_event).to match({
        at: be_a(Float),
        hst_id: client.hst_id, # (String) last lock is released from the current thread
        acq_id: client.acq_id, # (String) last lock is released from the current thread
        rel_time: be_a(Numeric),
        rel_key_cnt: be_a(Integer),
        tch_queue_cnt: be_a(Integer),
        instrument: nil
      })
    end
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
      config['retry_count'] = 3
      config['instrumenter'] = test_notifier
    end

    redis_for_info = RedisClient.config(db: 1).new_pool(
      # NOTE:
      #   - long connect_/read_/write_ timeouts is used for problems inside the github runners
      #     in RBS tests where all our code is "totally slow"
      #     (and each spec can fail on 1.0-seconds-timeout with Socket's timeout error);
      #   - long <timeout:> is used for some test-cases;
      timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
    )
    redis_for_info.call('FLUSHDB')

    client_for_info = RedisQueuedLocks::Client.new(redis) do |config|
      config['retry_count'] = 3
      config['instrumenter'] = test_notifier
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
      contain_exactly(*%w[acq_id hst_id ts ini_ttl lock_key rem_ttl rw_mode kek a]),
      contain_exactly(*%w[acq_id hst_id ts ini_ttl lock_key rem_ttl rw_mode pek b])
    )
    # NOTE: the write lock info has the lock key like the read lock info and `#lock_info`
    expect(locks_info_a.map { |val| val[:info]['lock_key'] }).to contain_exactly(
      'rql:lock:locklock-pekpek-123',
      'rql:lock:locklock-pekpek-567'
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
      contain_exactly(*%w[acq_id hst_id ts ini_ttl lock_key rem_ttl rw_mode kek a]),
      contain_exactly(*%w[acq_id hst_id ts ini_ttl lock_key rem_ttl rw_mode pek b])
    )
    # NOTE: the write lock info has the lock key like the read lock info and `#lock_info`
    expect(locks_info_b.map { |val| val[:info]['lock_key'] }).to contain_exactly(
      'rql:lock:locklock-pekpek-123',
      'rql:lock:locklock-pekpek-567'
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
        contain_exactly(*%w[acq_id score rw_mode priority]),
        contain_exactly(*%w[acq_id score rw_mode priority]),
        contain_exactly(*%w[acq_id score rw_mode priority])
      ),
      contain_exactly(
        contain_exactly(*%w[acq_id score rw_mode priority]),
        contain_exactly(*%w[acq_id score rw_mode priority]),
        contain_exactly(*%w[acq_id score rw_mode priority])
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

  specify 'config works well (touch configs - should be no errors)' do
    expect do
      RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = 3
        config['retry_delay'] = 200
        config['retry_jitter'] = 25
        config['try_to_lock_timeout'] = 10
        config['default_lock_ttl'] = 5_000
        config['default_queue_ttl'] = 15
        config['detailed_acq_timeout_error'] = false
        config['lock_release_batch_size'] = 100
        config['clear_locks_of__lock_scan_size'] = 300
        config['clear_locks_of__queue_scan_size'] = 300
        config['key_extraction_batch_size'] = 500
        config['instrumenter'] = RedisQueuedLocks::Instrument::VoidNotifier
        config['uniq_identifier'] = -> { RedisQueuedLocks::Resource.calc_uniq_identity }
        config['logger'] = RedisQueuedLocks::Logging::VoidLogger
        config['log_lock_try'] = false
        config['dead_request_ttl'] = 1 * 24 * 60 * 60 * 1000
        config['lock_index_enabled'] = false
        config['lock_index_enabled'] = true
        config['lock_index_grace_period'] = 60_000
        config['is_timed_by_default'] = false
        config['default_conflict_strategy'] = :wait_for_lock
        config['default_access_strategy'] = :queued
        config['log_sampling_enabled'] = false
        config['log_sampling_percent'] = 15
        config['log_sampler'] = RedisQueuedLocks::Logging::Sampler
        config['instr_sampling_enabled'] = false
        config['instr_sampling_percent'] = 15
        config['instr_sampler'] = RedisQueuedLocks::Instrument::Sampler
        config['swarm.auto_swarm'] = false
        config['swarm.supervisor.liveness_probing_period'] = 2
        config['swarm.probe_hosts.enabled_for_swarm'] = true
        config['swarm.probe_hosts.probe_period'] = 2
        config['swarm.probe_hosts.redis_config.sentinel'] = false
        config['swarm.probe_hosts.redis_config.pooled'] = false
        config['swarm.probe_hosts.redis_config.config'] = {}
        config['swarm.probe_hosts.redis_config.pool_config'] = {}
        config['swarm.flush_zombies.enabled_for_swarm'] = true
        config['swarm.flush_zombies.zombie_ttl'] = 15_000
        config['swarm.flush_zombies.zombie_lock_scan_size'] = 500
        config['swarm.flush_zombies.zombie_queue_scan_size'] = 500
        config['swarm.flush_zombies.zombie_flush_period'] = 10
        config['swarm.flush_zombies.redis_config.sentinel'] = false
        config['swarm.flush_zombies.redis_config.pooled'] = false
        config['swarm.flush_zombies.redis_config.config'] = {}
        config['swarm.flush_zombies.redis_config.pool_config'] = {}
      end
    end.not_to raise_error
  end

  describe 'lock request priorities' do
    # NOTE: helpers of the priority examples:
    #   - the holder takes the lock in a thread and releases it by its block (`#unlock` would drop
    #     the queued lock requests too: the waiting acquirers would requeue them in any order);
    #   - lock requests are queued one by one (the next request is started when the previous one
    #     is in the queue): positions of the same priority follow the start order;
    #   - each requester is a separate acquirer (thread) that records the moment of the obtaining;
    let(:prio_client) do
      RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
    end
    let(:wait_until) do
      lambda do |&condition|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until condition.call
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise 'the awaited condition is not reached'
          end

          sleep(0.01) # NOTE: polling with a bounded timeout
        end
      end
    end
    let(:queued_requests) do
      lambda do |lock_name|
        info = prio_client.queue_info(lock_name)
        info ? info['queue'].size + info.fetch('read_queue', []).size : 0
      end
    end
    let(:hold_lock) do
      lambda do |lock_name, release|
        holder = Thread.new { prio_client.lock(lock_name, ttl: 30_000) { release.pop } }
        wait_until.call { prio_client.locked?(lock_name) }
        holder
      end
    end
    let(:enqueue_requests) do
      lambda do |lock_name, requests, timeline|
        timeline_lock = Mutex.new
        requests.map do |name, read_write_mode, priority|
          queued_before = queued_requests.call(lock_name)
          requester = Thread.new do
            prio_client.lock(
              lock_name, ttl: 30_000, read_write_mode:, priority:, retry_count: nil, timeout: 20
            ) do
              timeline_lock.synchronize { timeline << name }
              sleep(0.05) # NOTE: other lock requests wait for the release of the lock
            end
          end
          wait_until.call { queued_requests.call(lock_name) > queued_before }
          requester
        end
      end
    end

    specify 'the lock request position: the priority band and the requeue time limit' do
      [-100, -37, -1, 0, 1, 42, 100].each do |priority|
        position = RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority)
        expect(position).to be_within(1).of(Time.now.to_f - (priority * (2**32)))
        expect(RedisQueuedLocks::Resource.lock_request_priority(position)).to eq(priority)
        # NOTE: the band of any priority starts at its lower edge (no special highest band)
        expect(RedisQueuedLocks::Resource.lock_priority_band_floor(priority)).to eq(
          -priority * (2**32)
        )
        # NOTE: the requeue check decodes the enqueue time from the position of any priority
        expect(RedisQueuedLocks::Resource.dead_score_reached?(position, priority, 15)).to eq(false)
        expect(
          RedisQueuedLocks::Resource.dead_score_reached?(position - 16, priority, 15)
        ).to eq(true)
      end
    end

    specify 'strict priority: higher priorities go first, FIFO inside the same priority' do
      timeline = []
      release = Thread::Queue.new
      holder = hold_lock.call('prio.order', release)
      requesters = enqueue_requests.call('prio.order', [
        [:lowest, :write, -100],
        [:normal_first, :write, 0],
        [:highest_first, :write, 100],
        [:low, :write, -50],
        [:normal_second, :write, 0],
        [:high, :write, 37],
        [:highest_second, :write, 100]
      ], timeline)

      aggregate_failures 'queue: requests of higher priorities are ahead' do
        queue = prio_client.queue_info('prio.order')['queue']
        expect(queue.map { |request| request['priority'] }).to eq([100, 100, 37, 0, 0, -50, -100])
        expect(queue.map { |request| request['score'] }).to eq(
          queue.map { |request| request['score'] }.sort
        )
      end

      release << true
      [holder, *requesters].each(&:join)
      expect(timeline).to eq(
        %i[highest_first highest_second high normal_first normal_second low lowest]
      )
      expect(prio_client.keys).to be_empty
    end

    specify 'strict priority between read and write lock requests' do
      timeline = []
      release = Thread::Queue.new
      holder = hold_lock.call('prio.rw', release)
      requesters = enqueue_requests.call('prio.rw', [
        [:write_normal, :write, 0],
        [:read_high, :read, 60],
        [:write_high, :write, 60],
        [:read_low, :read, -1]
      ], timeline)

      release << true
      [holder, *requesters].each(&:join)
      # NOTE:
      #   - the high read request is ahead of every write request: it obtains the lock first;
      #   - the high write request is the head of the write lock queue: it waits for the read lock
      #     of the high read request only, then the normal write request goes;
      #   - the low read request waits for both write requests (they are ahead of it);
      expect(timeline).to eq(%i[read_high write_high write_normal read_low])
      expect(prio_client.keys).to be_empty
    end

    specify 'dead lock requests of any priority do not block the queues' do
      dead_position = lambda do |priority|
        RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority) - 60
      end
      obtained = match({ ok: true, result: hash_including(process: :lock_obtaining) })

      aggregate_failures 'a dead request of the same priority: dropped before the queue heads' do
        redis.call(
          'ZADD', 'rql:lock_queue:prio.dead', dead_position.call(77), 'rql:acq:1/2/3/4/dead'
        )
        expect(
          prio_client.lock('prio.dead', priority: 77, queue_ttl: 5, retry_count: 1)
        ).to obtained
        expect(redis.call('EXISTS', 'rql:lock_queue:prio.dead')).to eq(0)
        prio_client.unlock('prio.dead')
      end

      aggregate_failures 'dead write requests of higher priorities: dropped in the same attempt' do
        redis.call(
          'ZADD', 'rql:lock_queue:prio.dead',
          dead_position.call(100), 'rql:acq:1/2/3/4/dead_highest',
          dead_position.call(1), 'rql:acq:1/2/3/4/dead_high'
        )
        expect(
          prio_client.lock('prio.dead', priority: -1, queue_ttl: 5, retry_count: 1)
        ).to obtained
        expect(redis.call('EXISTS', 'rql:lock_queue:prio.dead')).to eq(0)
        prio_client.unlock('prio.dead')
      end

      aggregate_failures 'a dead read request of a higher priority does not block writers' do
        redis.call(
          'ZADD', 'rql:lock_read_queue:prio.dead', dead_position.call(1), 'rql:acq:1/2/3/4/dead'
        )
        expect(prio_client.lock('prio.dead', priority: 0, queue_ttl: 5, retry_count: 1)).to obtained
        expect(redis.call('EXISTS', 'rql:lock_read_queue:prio.dead')).to eq(0)
        prio_client.unlock('prio.dead')
      end

      aggregate_failures 'a dead write request of a higher priority does not block readers' do
        redis.call(
          'ZADD', 'rql:lock_queue:prio.dead', dead_position.call(50), 'rql:acq:1/2/3/4/dead'
        )
        expect(
          prio_client.lock(
            'prio.dead', read_write_mode: :read, priority: 0, queue_ttl: 5, retry_count: 1
          )
        ).to obtained
        expect(redis.call('EXISTS', 'rql:lock_queue:prio.dead')).to eq(0)
        prio_client.unlock('prio.dead')
      end

      aggregate_failures 'requests of priorities out of the range (newer RQL versions)' do
        # NOTE: the band and the enqueue time are decoded from the position of any priority
        redis.call(
          'ZADD', 'rql:lock_queue:prio.dead', dead_position.call(150), 'rql:acq:1/2/3/4/dead'
        )
        expect(prio_client.lock('prio.dead', queue_ttl: 5, retry_count: 1)).to obtained
        expect(redis.call('EXISTS', 'rql:lock_queue:prio.dead')).to eq(0)
        prio_client.unlock('prio.dead')

        # NOTE: an alive request of a higher priority blocks (it is not dropped)
        redis.call(
          'ZADD', 'rql:lock_queue:prio.dead',
          RedisQueuedLocks::Resource.calc_initial_acquirer_position(150), 'rql:acq:1/2/3/4/alive'
        )
        expect(prio_client.lock('prio.dead', queue_ttl: 5, retry_count: 1)).to match({
          ok: false, result: :retry_limit_reached
        })
        expect(redis.call('ZRANGE', 'rql:lock_queue:prio.dead', '0', '-1')).to eq(
          ['rql:acq:1/2/3/4/alive']
        )
        redis.call('DEL', 'rql:lock_queue:prio.dead')
      end

      aggregate_failures 'dead requests of lower priorities never block (dropped by their band)' do
        redis.call(
          'ZADD', 'rql:lock_queue:prio.dead', dead_position.call(-1), 'rql:acq:1/2/3/4/dead'
        )
        expect(
          prio_client.lock('prio.dead', priority: 1, queue_ttl: 5, retry_count: 1) { :obtained }
        ).to eq(:obtained)
        # NOTE: a request of a lower priority is never ahead: the attempts of higher priorities
        #   keep it, the attempts of its band drop it (or `#clear_dead_requests`)
        expect(redis.call('ZRANGE', 'rql:lock_queue:prio.dead', '0', '-1')).to eq(
          ['rql:acq:1/2/3/4/dead']
        )
        expect(
          prio_client.lock('prio.dead', priority: -1, queue_ttl: 5, retry_count: 1) { :obtained }
        ).to eq(:obtained)
        expect(redis.call('EXISTS', 'rql:lock_queue:prio.dead')).to eq(0)
      end
    end

    specify 'dead blocking requests: one more round trip per removal (attempt and pre-check)' do
      # NOTE: round trips are observed via a separate pool (the same db, one connection) with
      #   a recording middleware; `inject` adds lock requests right before a pipeline is sent;
      round_trips = []
      inject = nil
      recorder = Module.new do
        define_method(:call) do |command, redis_config, &block|
          round_trips << [command.first]
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |commands, redis_config, &block|
          inject&.call(commands)
          round_trips << commands.map(&:first)
          super(commands, redis_config, &block)
        end
      end
      recorded_redis =
        RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5, size: 1)
      test_logger = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << "#{progname} : #{yield if block_given?}"
        end
      end.new
      client = RedisQueuedLocks::Client.new(recorded_redis) do |config|
        config['retry_delay'] = 1
        config['retry_jitter'] = 1
        config['logger'] = test_logger
        config['log_lock_try'] = true
      end
      holder_client = RedisQueuedLocks::Client.new(redis)
      queue = 'rql:lock_queue:prio.trips'
      dead_request = lambda do |priority|
        [
          RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority) - 60,
          "rql:acq:1/2/3/4/dead#{priority}"
        ]
      end
      removal_round_trip = %w[ZREMRANGEBYSCORE ZREMRANGEBYSCORE ZRANGE ZRANGE]
      # NOTE: the lock data reads of the exit logs (`log_lock_try`: HGETALL) are not counted
      counted_round_trips = lambda do
        round_trips.reject { |commands| commands == ['HGETALL'] }
      end
      removal_logs = lambda do
        test_logger.logs.grep(/try_lock\.dead_request_removed\]/)
      end
      client.locked?('prio.trips') # NOTE: establish the recorded connection

      aggregate_failures 'the attempt: one round trip per dead band ahead' do
        redis.call('ZADD', queue, *dead_request.call(100), *dead_request.call(50))
        round_trips.clear
        expect(client.lock('prio.trips', ttl: 1_000, retry_count: 1)).to match({
          ok: true, result: hash_including(process: :lock_obtaining)
        })
        # NOTE: WATCH, the lock state with the queueing, two removals, MULTI/EXEC
        expect(counted_round_trips.call.size).to eq(5)
        expect(round_trips.count(removal_round_trip)).to eq(2)
        expect(removal_logs.call).to contain_exactly(
          a_string_including("dead_acq_id => 'rql:acq:1/2/3/4/dead100' dead_priority => 100"),
          a_string_including("dead_acq_id => 'rql:acq:1/2/3/4/dead50' dead_priority => 50")
        )
        client.unlock('prio.trips')
      end

      aggregate_failures 'the attempt: both dead blocking requests in one round trip' do
        test_logger.logs.clear
        # NOTE: the head of the write lock queue and the earlier read lock request (other bands)
        redis.call('ZADD', queue, *dead_request.call(70))
        redis.call('ZADD', 'rql:lock_read_queue:prio.trips', *dead_request.call(30))
        round_trips.clear
        expect(client.lock('prio.trips', ttl: 1_000, retry_count: 1)).to match({
          ok: true, result: hash_including(process: :lock_obtaining)
        })
        # NOTE: WATCH, the lock state with the queueing, one removal of both bands, MULTI/EXEC
        expect(counted_round_trips.call.size).to eq(4)
        expect(round_trips).to include(
          %w[ZREMRANGEBYSCORE ZREMRANGEBYSCORE ZREMRANGEBYSCORE ZREMRANGEBYSCORE ZRANGE ZRANGE]
        )
        expect(removal_logs.call).to contain_exactly(
          a_string_including("dead_acq_id => 'rql:acq:1/2/3/4/dead70' dead_priority => 70"),
          a_string_including("dead_acq_id => 'rql:acq:1/2/3/4/dead30' dead_priority => 30")
        )
        client.unlock('prio.trips')
      end

      aggregate_failures 'the attempt: no round trips while the blocking request is alive' do
        redis.call(
          'ZADD', queue,
          RedisQueuedLocks::Resource.calc_initial_acquirer_position(50), 'rql:acq:1/2/3/4/alive'
        )
        round_trips.clear
        expect(client.lock('prio.trips', ttl: 1_000, retry_count: 1)).to match({
          ok: false, result: :retry_limit_reached
        })
        # NOTE: WATCH, the lock state with the queueing, MULTI/EXEC, the dequeue (ZREM)
        expect(counted_round_trips.call.size).to eq(4)
        expect(round_trips).not_to include(removal_round_trip)
        redis.call('DEL', queue)
      end

      aggregate_failures 'the pre-check of a retry: the same removal' do
        test_logger.logs.clear
        holder = Thread.new { holder_client.lock('prio.trips', ttl: 10_000) }
        holder.join
        # NOTE: the dead request appears after the first attempt (right before the pre-check)
        lock_state_pipelines = 0
        inject = lambda do |commands|
          next unless commands.include?(['TIME'])

          lock_state_pipelines += 1
          redis.call('ZADD', queue, *dead_request.call(9)) if lock_state_pipelines == 2
        end
        round_trips.clear
        expect(client.lock('prio.trips', ttl: 1_000, retry_count: 2)).to match({
          ok: false, result: :retry_limit_reached
        })
        inject = nil
        # NOTE: the first attempt (WATCH, the lock state with the queueing, MULTI/EXEC),
        #   the pre-check, the removal, the dequeue (ZREM)
        expect(counted_round_trips.call.size).to eq(6)
        expect(round_trips.count { |commands| commands.include?('WATCH') }).to eq(1)
        expect(counted_round_trips.call[4]).to eq(removal_round_trip)
        expect(removal_logs.call).to contain_exactly(
          a_string_including("dead_acq_id => 'rql:acq:1/2/3/4/dead9' dead_priority => 9")
        )
        expect(redis.call('ZSCORE', queue, 'rql:acq:1/2/3/4/dead9')).to eq(nil)
        holder_client.unlock('prio.trips')
      end

      aggregate_failures 'up to MAX_DEAD_REQUEST_REMOVALS bands per attempt' do
        test_logger.logs.clear
        max_removals =
          RedisQueuedLocks::Acquirer::AcquireLock::TryToLock::MAX_DEAD_REQUEST_REMOVALS
        dead_requests = (1..(max_removals + 1)).flat_map { |priority| dead_request.call(priority) }
        redis.call('ZADD', queue, *dead_requests)
        round_trips.clear
        expect(client.lock('prio.trips', ttl: 1_000, retry_count: 2)).to match({
          ok: true, result: hash_including(process: :lock_obtaining)
        })
        # NOTE: the first attempt (WATCH, the lock state with the queueing, removals, MULTI/EXEC),
        #   the pre-check of the retry with the last removal, the attempt (WATCH, the lock state
        #   with the queueing, MULTI/EXEC)
        expect(counted_round_trips.call.size).to eq(3 + max_removals + 2 + 3)
        expect(round_trips.count(removal_round_trip)).to eq(max_removals + 1)
        expect(removal_logs.call.size).to eq(max_removals + 1)
        client.unlock('prio.trips')
      end

      expect(client.keys).to be_empty
      recorded_redis.close
    end

    specify 'clear_dead_requests drops dead requests of all priorities' do
      position = lambda do |priority, age|
        RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority) - age
      end
      redis.call(
        'ZADD', 'rql:lock_queue:prio.clear',
        position.call(150, 60), 'rql:acq:1/2/3/4/dead_out_of_range',
        position.call(100, 60), 'rql:acq:1/2/3/4/dead_high',
        position.call(37, 60), 'rql:acq:1/2/3/4/dead_middle',
        position.call(0, 60), 'rql:acq:1/2/3/4/dead_normal_first',
        position.call(0, 50), 'rql:acq:1/2/3/4/dead_normal_second',
        position.call(-100, 60), 'rql:acq:1/2/3/4/dead_low',
        position.call(100, 1), 'rql:acq:1/2/3/4/alive_high',
        position.call(-100, 1), 'rql:acq:1/2/3/4/alive_low'
      )
      redis.call(
        'ZADD', 'rql:lock_read_queue:prio.clear', position.call(1, 60), 'rql:acq:1/2/3/4/dead_read'
      )
      prio_client.reindex_locks if prio_client.config['lock_index_enabled']

      expect(prio_client.clear_dead_requests(dead_ttl: 30_000)).to match({
        ok: true,
        result: {
          processed_queues: contain_exactly(
            'rql:lock_queue:prio.clear', 'rql:lock_read_queue:prio.clear'
          )
        }
      })
      # NOTE: alive requests of the highest and the lowest priority stay (in the queue order)
      expect(prio_client.queue_info('prio.clear')).to match({
        'lock_queue' => 'rql:lock_queue:prio.clear',
        'queue' => [
          {
            'acq_id' => 'rql:acq:1/2/3/4/alive_high', 'score' => be_a(Float),
            'rw_mode' => 'write', 'priority' => 100
          },
          {
            'acq_id' => 'rql:acq:1/2/3/4/alive_low', 'score' => be_a(Float),
            'rw_mode' => 'write', 'priority' => -100
          }
        ]
      })
      prio_client.unlock('prio.clear')
    end

    specify 'lock requests at infinite positions (manual writes): -inf is dead, +inf is behind' do
      # NOTE: RQL never writes infinite positions (manual writes of the lock request queues): the
      #   priority of `-inf` is the highest one, of `+inf` the lowest one; a request at `-inf` is
      #   dead (like before priorities: it is dropped when it blocks a lock request and by
      #   `#clear_dead_requests`), a request at `+inf` is behind all requests (never dead);
      obtained = match({ ok: true, result: hash_including(process: :lock_obtaining) })
      request = lambda do |acq_id, score, rw_mode, priority|
        { 'acq_id' => acq_id, 'score' => score, 'rw_mode' => rw_mode, 'priority' => priority }
      end

      aggregate_failures 'the priority of the infinite positions' do
        expect(RedisQueuedLocks::Resource.lock_request_priority(-Float::INFINITY)).to eq(100)
        expect(RedisQueuedLocks::Resource.lock_request_priority(Float::INFINITY)).to eq(-100)
      end

      aggregate_failures 'queue info' do
        redis.call(
          'ZADD', 'rql:lock_queue:prio.inf',
          '-inf', 'rql:acq:1/2/3/4/first', '+inf', 'rql:acq:1/2/3/4/last'
        )
        redis.call('ZADD', 'rql:lock_read_queue:prio.inf', '-inf', 'rql:acq:1/2/3/4/reader')
        prio_client.reindex_locks if prio_client.config['lock_index_enabled']

        expect(prio_client.queue_info('prio.inf')).to match({
          'lock_queue' => 'rql:lock_queue:prio.inf',
          'queue' => [
            request.call('rql:acq:1/2/3/4/first', -Float::INFINITY, 'write', 100),
            request.call('rql:acq:1/2/3/4/last', Float::INFINITY, 'write', -100)
          ],
          'read_lock_queue' => 'rql:lock_read_queue:prio.inf',
          'read_queue' => [request.call('rql:acq:1/2/3/4/reader', -Float::INFINITY, 'read', 100)]
        })
        expect(prio_client.queues_info).to contain_exactly(
          {
            queue: 'rql:lock_queue:prio.inf',
            requests: [
              request.call('rql:acq:1/2/3/4/first', -Float::INFINITY, 'write', 100),
              request.call('rql:acq:1/2/3/4/last', Float::INFINITY, 'write', -100)
            ]
          },
          {
            queue: 'rql:lock_read_queue:prio.inf',
            requests: [request.call('rql:acq:1/2/3/4/reader', -Float::INFINITY, 'read', 100)]
          }
        )
      end

      aggregate_failures 'clear_dead_requests drops the requests at -inf' do
        prio_client.clear_dead_requests(dead_ttl: 30_000)
        expect(redis.call('ZRANGE', 'rql:lock_queue:prio.inf', '0', '-1')).to eq(
          ['rql:acq:1/2/3/4/last']
        )
        expect(redis.call('EXISTS', 'rql:lock_read_queue:prio.inf')).to eq(0)
        prio_client.unlock('prio.inf')
      end

      aggregate_failures 'a request at -inf does not block the write queue (+inf: behind)' do
        redis.call(
          'ZADD', 'rql:lock_queue:prio.inf',
          '-inf', 'rql:acq:1/2/3/4/first', '+inf', 'rql:acq:1/2/3/4/last'
        )
        expect(prio_client.lock('prio.inf', retry_count: 1)).to obtained
        expect(redis.call('ZRANGE', 'rql:lock_queue:prio.inf', '0', '-1')).to eq(
          ['rql:acq:1/2/3/4/last']
        )
        prio_client.unlock('prio.inf')
      end

      aggregate_failures 'a write request at -inf does not block readers' do
        redis.call('ZADD', 'rql:lock_queue:prio.inf', '-inf', 'rql:acq:1/2/3/4/first')
        expect(prio_client.lock('prio.inf', read_write_mode: :read, retry_count: 1)).to obtained
        expect(redis.call('EXISTS', 'rql:lock_queue:prio.inf')).to eq(0)
        prio_client.unlock('prio.inf')
      end

      aggregate_failures 'a read request at -inf does not block writers' do
        redis.call('ZADD', 'rql:lock_read_queue:prio.inf', '-inf', 'rql:acq:1/2/3/4/reader')
        expect(prio_client.lock('prio.inf', retry_count: 1)).to obtained
        expect(redis.call('EXISTS', 'rql:lock_read_queue:prio.inf')).to eq(0)
        prio_client.unlock('prio.inf')
      end

      expect(prio_client.keys).to be_empty
    end

    specify 'queue info, the default priority from config, arguments validation' do
      high_client = RedisQueuedLocks::Client.new(redis) do |config|
        config['default_lock_priority'] = 100
      end
      release = Thread::Queue.new
      holder = hold_lock.call('prio.info', release)
      requesters = [
        Thread.new { prio_client.lock('prio.info', retry_count: nil, timeout: 20) {} },
        Thread.new do
          high_client.lock('prio.info', read_write_mode: :read, retry_count: nil, timeout: 20) {}
        end
      ]
      wait_until.call { queued_requests.call('prio.info') == 2 }

      aggregate_failures 'the priority of the requests in queue info' do
        info = prio_client.queue_info('prio.info')
        # NOTE: the default priority keeps the position equal to the enqueue time (the positions of
        #   older RQL versions), the priority band shifts it down by 2**32 seconds per priority
        expect(info['queue']).to match([{
          'acq_id' => be_a(String), 'score' => be_within(5).of(Time.now.to_f),
          'rw_mode' => 'write', 'priority' => 0
        }])
        expect(info['read_queue']).to match([{
          'acq_id' => be_a(String), 'score' => be_within(5).of(Time.now.to_f - (100 * (2**32))),
          'rw_mode' => 'read', 'priority' => 100
        }])
        expect(prio_client.queues_info).to contain_exactly(
          { queue: 'rql:lock_queue:prio.info', requests: [hash_including('priority' => 0)] },
          { queue: 'rql:lock_read_queue:prio.info', requests: [hash_including('priority' => 100)] }
        )
      end

      release << true
      [holder, *requesters].each(&:join)

      aggregate_failures 'arguments validation' do
        expect { prio_client.lock('prio.info', priority: 101) }.to raise_error(
          RedisQueuedLocks::ArgumentError,
          "`:priority` argument should be an Integer from -100 to 100 or a priority name of " \
          "`config['lock_priorities']` (:lowest, :low, :normal, :high, :highest), got 101."
        )
        expect { prio_client.lock!('prio.info', priority: -101) }.to raise_error(
          RedisQueuedLocks::ArgumentError, /priority/
        )
        expect { prio_client.lock_series('prio.a', 'prio.b', priority: 500) }.to raise_error(
          RedisQueuedLocks::ArgumentError, /priority/
        )
        # NOTE: (RBS) type-invalid values can't reach the runtime validation under the RBS runtime
        #   type checks (the hook raises first)
        unless RBS_RUNTIME_TEST
          expect { prio_client.lock('prio.info', priority: 1.0) }.to raise_error(
            RedisQueuedLocks::ArgumentError, /priority/
          )
          expect { prio_client.lock('prio.info', priority: nil) }.to raise_error(
            RedisQueuedLocks::ArgumentError, /priority/
          )
        end
        expect { prio_client.config['default_lock_priority'] = 101 }.to raise_error(
          RedisQueuedLocks::ConfigValidationError
        )
        expect { prio_client.config['default_lock_priority'] = -101 }.to raise_error(
          RedisQueuedLocks::ConfigValidationError
        )
        expect { prio_client.config['default_lock_priority'] = 0.5 }.to raise_error(
          RedisQueuedLocks::ConfigValidationError
        )
      end
      expect(prio_client.keys).to be_empty
    end

    specify 'priority names (config lock_priorities): order, default priority, validation' do
      timeline = []
      release = Thread::Queue.new
      # NOTE: application priority names next to the default ones
      prio_client.config['lock_priorities'] =
        prio_client.config['lock_priorities'].merge(payment: 90, email: -10)
      holder = hold_lock.call('prio.names', release)
      requesters = enqueue_requests.call('prio.names', [
        %i[email write email],
        %i[normal write normal],
        %i[payment write payment],
        %i[low read low],
        %i[high write high],
        %i[highest read highest]
      ], timeline)

      aggregate_failures 'names are resolved to their Integer priorities' do
        info = prio_client.queue_info('prio.names')
        expect(info['queue'].map { |request| request['priority'] }).to eq([90, 50, 0, -10])
        expect(info['read_queue'].map { |request| request['priority'] }).to eq([100, -50])
      end

      release << true
      [holder, *requesters].each(&:join)
      # NOTE: the read request of the highest priority goes first, the low read request waits for
      #   the write requests of higher priorities (strict priority between modes)
      expect(timeline).to eq(%i[highest payment high normal email low])

      aggregate_failures 'the default priority by name' do
        low_client = RedisQueuedLocks::Client.new(redis) do |config|
          config['default_lock_priority'] = :low
        end
        release = Thread::Queue.new
        holder = hold_lock.call('prio.names.default', release)
        requester = Thread.new do
          low_client.lock('prio.names.default', retry_count: nil, timeout: 20) {}
        end
        wait_until.call { queued_requests.call('prio.names.default') == 1 }
        expect(prio_client.queue_info('prio.names.default')['queue']).to match(
          [hash_including('priority' => -50)]
        )
        release << true
        [holder, requester].each(&:join)
      end

      aggregate_failures 'unknown priority names' do
        expect { prio_client.lock('prio.names', priority: :urgent) }.to raise_error(
          RedisQueuedLocks::ArgumentError,
          "`:priority` argument should be an Integer from -100 to 100 or a priority name of " \
          "`config['lock_priorities']` (:lowest, :low, :normal, :high, :highest, :payment, " \
          ":email), got :urgent."
        )
        expect { prio_client.lock!('prio.names', priority: :urgent) }.to raise_error(
          RedisQueuedLocks::ArgumentError, /got :urgent/
        )
        expect { prio_client.lock_series('prio.a', 'prio.b', priority: :urgent) }.to raise_error(
          RedisQueuedLocks::ArgumentError, /got :urgent/
        )
        # NOTE: a priority name of the default priority is checked on each lock acquirement (the
        #   priority names can be configured after the default priority)
        urgent_client = RedisQueuedLocks::Client.new(redis) do |config|
          config['default_lock_priority'] = :urgent
        end
        expect { urgent_client.lock('prio.names') }.to raise_error(
          RedisQueuedLocks::ArgumentError, /got :urgent/
        )
      end

      aggregate_failures 'config validation' do
        [{ 'high' => 1 }, { high: 101 }, { high: -101 }, { high: 1.5 }, [[:high, 1]], nil]
          .each do |invalid_priorities|
            expect { prio_client.config['lock_priorities'] = invalid_priorities }.to raise_error(
              RedisQueuedLocks::ConfigValidationError
            )
          end
        expect { prio_client.config['default_lock_priority'] = 'high' }.to raise_error(
          RedisQueuedLocks::ConfigValidationError
        )
        # NOTE: the default priority names (frozen: the default value is shared by all clients)
        default_priorities = RedisQueuedLocks::Client.new(redis).config['lock_priorities']
        expect(default_priorities).to eq(
          { lowest: -100, low: -50, normal: 0, high: 50, highest: 100 }
        )
        expect(default_priorities).to be_frozen
      end
      expect(prio_client.keys).to be_empty
    end

    specify 'priority in logs and instrumentation of the lock events' do
      test_notifier = Class.new do
        attr_reader :notifications

        def initialize
          @notifications = []
        end

        def notify(event, payload = {})
          notifications << { event:, payload: }
        end
      end.new
      test_logger = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << (block ? yield : progname)
        end
      end.new
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['instrumenter'] = test_notifier
        config['logger'] = test_logger
      end

      client.lock('prio.events', priority: -1) { :ok }
      client.lock('prio.events.named', priority: :high) { :ok }
      client.lock_series('prio.events.a', 'prio.events.b', priority: 1) { :ok }
      client.lock('prio.events.busy', ttl: 30_000)
      client.lock('prio.events.busy', priority: 1, fail_fast: true)
      client.lock_series('prio.events.c', 'prio.events.d', priority: :low) { :ok }
      client.lock('prio.events.reentrant', priority: :high, conflict_strategy: :work_through) do
        client.lock('prio.events.reentrant', priority: :high, conflict_strategy: :work_through) do
          :ok
        end
      end
      client.lock(
        'prio.events.extendable', priority: -7, conflict_strategy: :extendable_work_through
      ) do
        client.lock(
          'prio.events.extendable', priority: -7, conflict_strategy: :extendable_work_through
        ) { :ok }
      end

      expect(test_notifier.notifications).to include(
        match({
          event: 'redis_queued_locks.lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events', priority: -1)
        }),
        match({
          event: 'redis_queued_locks.lock_hold_and_release',
          payload: hash_including(lock_key: 'rql:lock:prio.events', priority: -1)
        }),
        # NOTE: a priority name is reported as its Integer priority
        match({
          event: 'redis_queued_locks.lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.named', priority: 50)
        }),
        match({
          event: 'redis_queued_locks.lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.a', priority: 1)
        }),
        match({
          event: 'redis_queued_locks.lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.b', priority: 1)
        }),
        match({
          event: 'redis_queued_locks.lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.busy', priority: 0)
        }),
        match({
          event: 'redis_queued_locks.lock_obtaining_failed',
          payload: hash_including(
            lock_key: 'rql:lock:prio.events.busy', priority: 1, result: :fail_fast_no_try
          )
        }),
        # NOTE: lock series events (the priority of the series)
        match({
          event: 'redis_queued_locks.lock_series_obtained',
          payload: hash_including(
            lock_keys: ['rql:lock:prio.events.a', 'rql:lock:prio.events.b'], priority: 1
          )
        }),
        match({
          event: 'redis_queued_locks.lock_series_hold_and_release',
          payload: hash_including(
            lock_keys: ['rql:lock:prio.events.a', 'rql:lock:prio.events.b'], priority: 1
          )
        }),
        match({
          event: 'redis_queued_locks.lock_series_obtained',
          payload: hash_including(
            lock_keys: ['rql:lock:prio.events.c', 'rql:lock:prio.events.d'], priority: -50
          )
        }),
        # NOTE: reentrant lock events (the requested priority)
        match({
          event: 'redis_queued_locks.reentrant_lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.reentrant', priority: 50)
        }),
        match({
          event: 'redis_queued_locks.reentrant_lock_hold_completes',
          payload: hash_including(lock_key: 'rql:lock:prio.events.reentrant', priority: 50)
        }),
        match({
          event: 'redis_queued_locks.extendable_reentrant_lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.extendable', priority: -7)
        }),
        match({
          event: 'redis_queued_locks.reentrant_lock_hold_completes',
          payload: hash_including(lock_key: 'rql:lock:prio.events.extendable', priority: -7)
        })
      )
      expect(test_logger.logs).to include(
        a_string_including(
          '[redis_queued_locks.lock_obtained]', "lock_key => 'rql:lock:prio.events'",
          "rw_mode => 'write' priority => -1 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.lock_obtained]', "lock_key => 'rql:lock:prio.events.named'",
          "rw_mode => 'write' priority => 50 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.lock_obtaining_failed]', "lock_key => 'rql:lock:prio.events.busy'",
          "rw_mode => 'write' priority => 1 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.start_lock_obtaining]', "lock_key => 'rql:lock:prio.events'",
          "rw_mode => 'write' priority => -1"
        ),
        a_string_including(
          '[redis_queued_locks.start_try_to_lock_cycle]', "lock_key => 'rql:lock:prio.events'",
          "rw_mode => 'write' priority => -1"
        ),
        a_string_including(
          '[redis_queued_locks.reentrant_lock_obtained]',
          "lock_key => 'rql:lock:prio.events.reentrant'",
          "rw_mode => 'write' priority => 50 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.extendable_reentrant_lock_obtained]',
          "lock_key => 'rql:lock:prio.events.extendable'",
          "rw_mode => 'write' priority => -7 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.start_lock_series_obtaining]', 'prio.events.c',
          "rw_mode => 'write' priority => -50"
        ),
        a_string_including(
          '[redis_queued_locks.lock_series_obtained]', 'prio.events.c',
          "rw_mode => 'write' priority => -50 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.expire_lock_series]', 'prio.events.c',
          "rw_mode => 'write' priority => -50"
        )
      )
      client.unlock('prio.events.busy')
      expect(client.keys).to be_empty
    end

    specify 'priorities in the try-lock logs (log_lock_try)' do
      test_logger = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << (block ? yield : progname)
        end
      end.new
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['logger'] = test_logger
        config['log_lock_try'] = true
      end
      holder_client = RedisQueuedLocks::Client.new(redis)
      position = lambda do |priority|
        RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority)
      end
      try_logs = lambda do |event|
        test_logger.logs.grep(/\A\[redis_queued_locks\.try_lock\.#{event}\] /)
      end
      failed_attempt = { ok: false, result: :retry_limit_reached }

      aggregate_failures 'the own priority and the first request of the queue' do
        redis.call('ZADD', 'rql:lock_queue:prio.trylog', position.call(50), 'rql:acq:1/2/3/4/high')
        expect(client.lock('prio.trylog', priority: -5, retry_count: 1)).to match(failed_attempt)
        expect(try_logs.call('acq_added_to_queue')).to include(
          a_string_including("rw_mode => 'write' priority => -5")
        )
        expect(try_logs.call('get_first_from_queue')).to include(
          a_string_including(
            "first_acq_id_in_queue => 'rql:acq:1/2/3/4/high' first_priority_in_queue => 50"
          )
        )
        expect(try_logs.call('exit__no_first')).to include(
          a_string_including(
            "first_acq_id_in_queue => 'rql:acq:1/2/3/4/high' first_priority_in_queue => 50 "
          )
        )
        redis.call('DEL', 'rql:lock_queue:prio.trylog')
      end

      aggregate_failures 'the earlier request of the opposite mode' do
        redis.call(
          'ZADD', 'rql:lock_read_queue:prio.trylog', position.call(30), 'rql:acq:1/2/3/4/reader'
        )
        expect(client.lock('prio.trylog', retry_count: 1)).to match(failed_attempt)
        expect(try_logs.call('exit__read_request_ahead')).to include(
          a_string_including("ahead_acq_id => 'rql:acq:1/2/3/4/reader' ahead_priority => 30")
        )
        redis.call('DEL', 'rql:lock_read_queue:prio.trylog')

        redis.call(
          'ZADD', 'rql:lock_queue:prio.trylog', position.call(30), 'rql:acq:1/2/3/4/writer'
        )
        expect(
          client.lock('prio.trylog', read_write_mode: :read, retry_count: 1)
        ).to match(failed_attempt)
        expect(try_logs.call('exit__write_request_ahead')).to include(
          a_string_including("ahead_acq_id => 'rql:acq:1/2/3/4/writer' ahead_priority => 30")
        )
        redis.call('DEL', 'rql:lock_queue:prio.trylog')
      end

      aggregate_failures 'the obtained lock: the own request is the first one' do
        holder_client.lock('prio.trylog', ttl: 10_000)
        expect(client.lock('prio.trylog', priority: :low, retry_count: 1)).to match(failed_attempt)
        expect(try_logs.call('exit__lock_still_obtained')).to include(
          a_string_including(
            "first_acq_id_in_queue => '#{client.current_acquirer_id}' " \
            "first_priority_in_queue => -50 "
          )
        )
        holder_client.unlock('prio.trylog')

        holder_client.lock('prio.trylog', ttl: 10_000, read_write_mode: :read)
        expect(client.lock('prio.trylog', priority: 7, retry_count: 1)).to match(failed_attempt)
        expect(try_logs.call('exit__read_lock_still_obtained')).to include(
          a_string_including(
            "first_acq_id_in_queue => '#{client.current_acquirer_id}' first_priority_in_queue => 7"
          )
        )
        holder_client.unlock('prio.trylog')
      end

      expect(client.keys).to be_empty
    end
  end

  describe 'read/write locks' do
    specify 'readers share the lock, writer waits for readers, reader waits for writer (FIFO)' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
      timeline = {}
      timeline_lock = Mutex.new
      mark = lambda do |event|
        timeline_lock.synchronize { timeline[event] = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      readers = Array.new(2) do |index|
        Thread.new do
          client.lock('rw.shared', read_write_mode: :read, ttl: 10_000) do
            mark.call(:"reader#{index}_in")
            sleep(0.5)
            mark.call(:"reader#{index}_out")
          end
        end
      end
      sleep(0.2) # NOTE: give a timespot to readers to obtain the lock
      writer = Thread.new do
        client.lock('rw.shared', read_write_mode: :write, ttl: 10_000) do
          mark.call(:writer_in)
          sleep(0.3)
          mark.call(:writer_out)
        end
      end
      sleep(0.1) # NOTE: give a timespot to the writer to take its place in the lock queue
      late_reader = Thread.new do
        client.lock('rw.shared', read_write_mode: :read, ttl: 10_000) { mark.call(:late_reader_in) }
      end
      [*readers, writer, late_reader].each(&:join)

      aggregate_failures 'readers work in parallel' do
        expect(timeline[:reader0_in]).to be < timeline[:reader1_out]
        expect(timeline[:reader1_in]).to be < timeline[:reader0_out]
      end
      aggregate_failures 'writer waits for all readers' do
        expect(timeline[:writer_in]).to be >= timeline[:reader0_out]
        expect(timeline[:writer_in]).to be >= timeline[:reader1_out]
      end
      aggregate_failures 'later reader waits for the earlier writer (:queued access strategy)' do
        expect(timeline[:late_reader_in]).to be >= timeline[:writer_out]
      end
      expect(client.locked?('rw.shared')).to eq(false)
      expect(client.queued?('rw.shared')).to eq(false)
    end

    specify ':random access strategy: readers do not wait for earlier write lock requests' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
        config['default_access_strategy'] = :random
      end
      timeline = {}
      timeline_lock = Mutex.new
      mark = lambda do |event|
        timeline_lock.synchronize { timeline[event] = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      reader = Thread.new do
        client.lock('rw.random', read_write_mode: :read, ttl: 10_000) do
          sleep(0.6)
          mark.call(:reader_out)
        end
      end
      sleep(0.2) # NOTE: give a timespot to the reader to obtain the lock
      writer = Thread.new do
        client.lock('rw.random', read_write_mode: :write, ttl: 10_000) { mark.call(:writer_in) }
      end
      sleep(0.1) # NOTE: give a timespot to the writer to try to obtain the lock
      late_reader = Thread.new do
        client.lock('rw.random', read_write_mode: :read, ttl: 10_000) { mark.call(:late_reader_in) }
      end
      [reader, writer, late_reader].each(&:join)

      expect(timeline[:late_reader_in]).to be < timeline[:reader_out]
      expect(timeline[:late_reader_in]).to be < timeline[:writer_in]
      expect(timeline[:writer_in]).to be >= timeline[:reader_out]
    end

    specify 'mutual exclusion under concurrency' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 5
        config['retry_jitter'] = 5
      end
      state = { readers: 0, writers: 0, max_readers: 0, violations: 0, completed: 0 }
      state_lock = Mutex.new

      workers = Array.new(8) do |worker|
        Thread.new do
          random = Random.new(worker)
          12.times do
            mode = (random.rand < 0.75) ? :read : :write
            client.lock('rw.invariant', read_write_mode: mode, ttl: 10_000, timeout: 30) do
              state_lock.synchronize do
                if mode == :read
                  state[:readers] += 1
                  state[:max_readers] = state[:readers] if state[:readers] > state[:max_readers]
                  state[:violations] += 1 if state[:writers] > 0
                else
                  state[:writers] += 1
                  state[:violations] += 1 if state[:writers] > 1 || state[:readers] > 0
                end
              end
              sleep(random.rand(0.002..0.01))
              state_lock.synchronize do
                (mode == :read) ? (state[:readers] -= 1) : (state[:writers] -= 1)
                state[:completed] += 1
              end
            end
          end
        end
      end
      workers.each(&:join)

      expect(state).to match({
        readers: 0,
        writers: 0,
        max_readers: be >= 2,
        violations: 0,
        completed: 8 * 12
      })
      expect(client.locked?('rw.invariant')).to eq(false)
      expect(client.queued?('rw.invariant')).to eq(false)
    end

    specify 'reentrant read/write locks of the same acquirer' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = 3
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      aggregate_failures 'read -> read (:work_through)' do
        client.lock('rw.reentrant', read_write_mode: :read, ttl: 10_000) do
          result = client.lock(
            'rw.reentrant', read_write_mode: :read, ttl: 10_000, conflict_strategy: :work_through
          )
          expect(result).to match({
            ok: true, result: hash_including(process: :conflict_work_through)
          })
          client.lock(
            'rw.reentrant', read_write_mode: :read, ttl: 10_000, conflict_strategy: :work_through
          ) { :inner }
          # NOTE: the inner block does not release the outer read lock
          expect(client.lock_info('rw.reentrant')).to match(hash_including(
            'rw_mode' => 'read',
            'readers' => contain_exactly(hash_including('acq_id' => client.current_acquirer_id))
          ))
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'read -> read (:extendable_work_through)' do
        client.lock('rw.reentrant', read_write_mode: :read, ttl: 5_000) do
          client.lock(
            'rw.reentrant',
            read_write_mode: :read,
            ttl: 20_000,
            conflict_strategy: :extendable_work_through
          ) do
            expect(client.lock_info('rw.reentrant')['rem_ttl']).to be > 20_000
          end
          # NOTE:
          #   - the extension is returned back after the inner block;
          #   - the returned extension is decreased by the time spent inside the inner block
          #     and by the redis time shift error (the same as for extendable write locks);
          expect(client.lock_info('rw.reentrant')['rem_ttl']).to be < 5_100
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'read -> read (:dead_locking)' do
        client.lock('rw.reentrant', read_write_mode: :read, ttl: 10_000) do
          expect do
            client.lock!('rw.reentrant', read_write_mode: :read, conflict_strategy: :dead_locking)
          end.to raise_error(RedisQueuedLocks::ConflictLockObtainError)
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'write -> read (:work_through): read lock under the obtained write lock' do
        client.lock('rw.reentrant', read_write_mode: :write, ttl: 10_000) do
          client.lock(
            'rw.reentrant', read_write_mode: :read, conflict_strategy: :work_through
          ) do
            expect(client.lock_info('rw.reentrant')['acq_id']).to eq(client.current_acquirer_id)
          end
          # NOTE: the inner block does not release the outer write lock
          expect(client.lock_info('rw.reentrant')['acq_id']).to eq(client.current_acquirer_id)
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'read -> write (lock upgrade) fails for non-waiting conflict strategies' do
        client.lock('rw.reentrant', read_write_mode: :read, ttl: 10_000) do
          %i[work_through extendable_work_through].each do |strategy|
            expect(
              client.lock('rw.reentrant', read_write_mode: :write, conflict_strategy: strategy)
            ).to match({ ok: false, result: :conflict_lock_upgrade })
            expect do
              client.lock!('rw.reentrant', read_write_mode: :write, conflict_strategy: strategy)
            end.to raise_error(RedisQueuedLocks::ConflictLockObtainError, /upgrade/)
          end
          expect(
            client.lock('rw.reentrant', read_write_mode: :write, conflict_strategy: :dead_locking)
          ).to match({ ok: false, result: :conflict_dead_lock })
          expect(client.queued?('rw.reentrant')).to eq(false)
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'read -> write (:wait_for_lock): waits for its own read lock expiration' do
        client.lock('rw.reentrant', read_write_mode: :read, ttl: 400)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.lock(
          'rw.reentrant',
          read_write_mode: :write,
          ttl: 10_000,
          conflict_strategy: :wait_for_lock,
          retry_count: nil,
          timeout: 5
        )
        waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(waited).to be >= 0.3
        expect(client.lock_info('rw.reentrant')).to include('acq_id' => client.current_acquirer_id)
        client.unlock('rw.reentrant')
      end
    end

    specify 'fail_fast with read/write locks' do
      client = RedisQueuedLocks::Client.new(redis)
      # NOTE: (thread references are kept till the end of the spec in order to keep acquirer ids)
      holders = []
      take = lambda do |mode|
        holder = Thread.new { client.lock('rw.ff', read_write_mode: mode, ttl: 10_000) }
        holders << holder
        holder.value
      end

      take.call(:write)
      expect(client.lock('rw.ff', read_write_mode: :read, fail_fast: true)).to match({
        ok: false, result: :fail_fast_no_try
      })
      expect do
        client.lock!('rw.ff', read_write_mode: :read, fail_fast: true)
      end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
      client.unlock('rw.ff')

      take.call(:read)
      expect(client.lock('rw.ff', read_write_mode: :write, fail_fast: true)).to match({
        ok: false, result: :fail_fast_no_try
      })
      expect do
        client.lock!('rw.ff', read_write_mode: :write, fail_fast: true)
      end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
      expect(client.lock('rw.ff', read_write_mode: :read, ttl: 10_000, fail_fast: true)).to match({
        ok: true, result: hash_including(process: :lock_obtaining)
      })
      expect(client.lock_info('rw.ff')['readers'].size).to eq(2)
      client.unlock('rw.ff')
    end

    specify 'expired read locks and dead lock requests do not block other requests' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
      holders = Array.new(2) do |index|
        Thread.new { client.lock('rw.expired', read_write_mode: :read, ttl: [300, 1_000][index]) }
      end
      holders.each(&:join)
      sleep(0.5) # NOTE: the first read lock is expired, the second one is still alive

      aggregate_failures 'expired read locks are ignored' do
        expect(client.lock_info('rw.expired')).to match(hash_including(
          'readers' => contain_exactly(
            hash_including('acq_id' => holders[1].value[:result][:acq_id])
          )
        ))
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.lock('rw.expired', read_write_mode: :write, ttl: 10_000, retry_count: nil)
        waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(waited).to be < 2
        client.unlock('rw.expired')
      end

      aggregate_failures 'dead write lock request does not block readers' do
        redis.call('ZADD', 'rql:lock_queue:rw.dead', Time.now.to_f - 60, 'rql:acq:1/2/3/4/dead')
        result = client.lock('rw.dead', read_write_mode: :read, queue_ttl: 5, retry_count: 1)
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(redis.call('EXISTS', 'rql:lock_queue:rw.dead')).to eq(0)
        client.unlock('rw.dead')
      end

      aggregate_failures 'dead read lock request does not block writers' do
        redis.call(
          'ZADD', 'rql:lock_read_queue:rw.dead', Time.now.to_f - 60, 'rql:acq:1/2/3/4/dead'
        )
        result = client.lock('rw.dead', read_write_mode: :write, queue_ttl: 5, retry_count: 1)
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(redis.call('EXISTS', 'rql:lock_read_queue:rw.dead')).to eq(0)
        client.unlock('rw.dead')
      end
    end

    specify 'read lock request is dequeued on timeout' do
      client = RedisQueuedLocks::Client.new(redis)
      holder = Thread.new { client.lock('rw.timeout', read_write_mode: :write, ttl: 10_000) }
      holder.join

      result = client.lock('rw.timeout', read_write_mode: :read, timeout: 1, retry_count: nil)
      expect(result).to match({ ok: false, result: :timeout_reached })
      expect(client.queue_info('rw.timeout')).to eq(nil)
      expect(client.queued?('rw.timeout')).to eq(false)
      client.unlock('rw.timeout')
    end

    specify 'lock info, queue info and #unlock with read/write locks' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
      reader = Thread.new { client.lock('rw.info', read_write_mode: :read, ttl: 10_000) }
      reader.join
      writer = Thread.new do
        client.lock('rw.info', read_write_mode: :write, ttl: 10_000, timeout: 10) { :written }
      end
      sleep(0.2) # NOTE: give a timespot to the writer to take its place in the lock queue
      late_reader = Thread.new do
        client.lock('rw.info', read_write_mode: :read, ttl: 10_000, timeout: 10) { :read }
      end
      sleep(0.2) # NOTE: give a timespot to the reader to take its place in the read lock queue

      aggregate_failures 'lock info' do
        expect(client.locked?('rw.info')).to eq(true)
        expect(client.lock_info('rw.info')).to match({
          'lock_key' => 'rql:lock:rw.info',
          'rw_mode' => 'read',
          'rem_ttl' => be_a(Integer),
          'readers' => contain_exactly({
            'acq_id' => reader.value[:result][:acq_id],
            'hst_id' => reader.value[:result][:hst_id],
            'ts' => be_a(Float),
            'ini_ttl' => 10_000,
            'rem_ttl' => be_a(Integer)
          })
        })
        expect(client.locks).to include('rql:lock:rw.info')
        # NOTE: `locks_info` extracts the read lock info by itself (the same format as `lock_info`)
        expect(client.locks_info).to include(match({
          lock: 'rql:lock:rw.info',
          status: :alive,
          info: {
            'lock_key' => 'rql:lock:rw.info',
            'rw_mode' => 'read',
            'rem_ttl' => be_a(Integer),
            'readers' => contain_exactly({
              'acq_id' => reader.value[:result][:acq_id],
              'hst_id' => reader.value[:result][:hst_id],
              'ts' => be_a(Float),
              'ini_ttl' => 10_000,
              'rem_ttl' => be_a(Integer)
            })
          }
        }))
        expect(client.keys).to include('rql:lock_readers:rw.info')
      end

      aggregate_failures 'queue info' do
        expect(client.queued?('rw.info')).to eq(true)
        expect(client.queue_info('rw.info')).to match({
          'lock_queue' => 'rql:lock_queue:rw.info',
          'queue' => contain_exactly(
            {
              'acq_id' => be_a(String), 'score' => be_a(Numeric), 'rw_mode' => 'write',
              'priority' => 0
            }
          ),
          'read_lock_queue' => 'rql:lock_read_queue:rw.info',
          'read_queue' => contain_exactly(
            {
              'acq_id' => be_a(String), 'score' => be_a(Numeric), 'rw_mode' => 'read',
              'priority' => 0
            }
          )
        })
        expect(client.queues).to include('rql:lock_queue:rw.info', 'rql:lock_read_queue:rw.info')
        expect(client.queues_info.map { |info| info[:queue] }).to include(
          'rql:lock_queue:rw.info',
          'rql:lock_read_queue:rw.info'
        )
        expect(client.queues_info).to include(
          match({
            queue: 'rql:lock_queue:rw.info',
            requests: contain_exactly(match(hash_including('rw_mode' => 'write')))
          }),
          match({
            queue: 'rql:lock_read_queue:rw.info',
            requests: contain_exactly(match(hash_including('rw_mode' => 'read')))
          })
        )
      end

      aggregate_failures '#unlock releases read locks' do
        expect(client.unlock('rw.info')).to match({
          ok: true,
          result: match({
            rel_time: be_a(Numeric),
            rel_key: 'rql:lock:rw.info',
            rel_queue: 'rql:lock_queue:rw.info',
            lock_res: :released,
            queue_res: :released
          })
        })
        expect(writer.value).to eq(:written)
        expect(late_reader.value).to eq(:read)
        expect(client.locked?('rw.info')).to eq(false)
        expect(client.queued?('rw.info')).to eq(false)
      end
    end

    specify 'clear_current_locks, clear_locks and clear_dead_requests with read locks' do
      client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures 'clear_current_locks' do
        client.lock('rw.clear', read_write_mode: :read, ttl: 10_000)
        redis.call(
          'ZADD', 'rql:lock_read_queue:rw.clear.queue', Time.now.to_f, client.current_acquirer_id
        )
        # NOTE: the queue is written directly (not by RQL acquirers): the keyspace SCAN finds it,
        #   the lock index gets it by `#reindex_locks` (the lock index is the only lookup then);
        client.reindex_locks if client.config['lock_index_enabled']
        expect(client.locked?('rw.clear')).to eq(true)
        expect(client.clear_current_locks).to match({
          ok: true,
          result: match({ rel_key_cnt: 1, tch_queue_cnt: 1, rel_time: be_a(Numeric) })
        })
        expect(client.locked?('rw.clear')).to eq(false)
        expect(client.queued?('rw.clear.queue')).to eq(false)
      end

      aggregate_failures 'clear_locks' do
        client.lock('rw.clear', read_write_mode: :read, ttl: 10_000)
        redis.call('ZADD', 'rql:lock_read_queue:rw.clear', Time.now.to_f, 'rql:acq:1/2/3/4/waiting')
        # NOTE: the queue is written directly (not by RQL acquirers): the keyspace SCAN finds it,
        #   the lock index gets it by `#reindex_locks` (the lock index is the only lookup then);
        client.reindex_locks if client.config['lock_index_enabled']
        expect(client.clear_locks).to match({
          ok: true,
          # NOTE: readers registry, read lock data and read lock queue
          result: match({ rel_key_cnt: 3, rel_time: be_a(Numeric) })
        })
        expect(client.locked?('rw.clear')).to eq(false)
        expect(client.queued?('rw.clear')).to eq(false)
      end

      aggregate_failures 'clear_dead_requests' do
        redis.call(
          'ZADD', 'rql:lock_read_queue:rw.dead', Time.now.to_f - 60, 'rql:acq:1/2/3/4/dead'
        )
        # NOTE: the queue is written directly (not by RQL acquirers): the keyspace SCAN finds it,
        #   the lock index gets it by `#reindex_locks` (the lock index is the only lookup then);
        client.reindex_locks if client.config['lock_index_enabled']
        expect(client.clear_dead_requests(dead_ttl: 1_000)).to match({
          ok: true,
          result: match({ processed_queues: contain_exactly('rql:lock_read_queue:rw.dead') })
        })
        expect(client.queued?('rw.dead')).to eq(false)
      end
    end

    specify 'queue info with read lock requests only' do
      client = RedisQueuedLocks::Client.new(redis)
      reader = 'rql:acq:1/2/3/4/reader'
      redis.call('ZADD', 'rql:lock_read_queue:rw.read.queue', Time.now.to_f, reader)
      # NOTE: the queue is written directly (not by RQL acquirers): the keyspace SCAN finds it,
      #   the lock index gets it by `#reindex_locks` (the lock index is the only lookup then);
      client.reindex_locks if client.config['lock_index_enabled']

      aggregate_failures 'the queue of write lock requests does not exist' do
        expect(client.queue_info('rw.read.queue')).to match({
          'lock_queue' => 'rql:lock_queue:rw.read.queue',
          'queue' => [],
          'read_lock_queue' => 'rql:lock_read_queue:rw.read.queue',
          'read_queue' => contain_exactly(
            { 'acq_id' => reader, 'score' => be_a(Numeric), 'rw_mode' => 'read', 'priority' => 0 }
          )
        })
        expect(client.queues_info).to contain_exactly(
          match({
            queue: 'rql:lock_read_queue:rw.read.queue',
            requests: contain_exactly(
              { 'acq_id' => reader, 'score' => be_a(Numeric), 'rw_mode' => 'read', 'priority' => 0 }
            )
          })
        )
      end

      aggregate_failures 'no lock queues' do
        redis.call('ZREM', 'rql:lock_read_queue:rw.read.queue', reader)
        expect(client.queue_info('rw.read.queue')).to eq(nil)
        expect(client.queues_info).to eq(Set.new)
      end
    end

    specify 'zombie read locks' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['swarm.auto_swarm'] = false
        # NOTE: we will manually probe hosts and flush zombies
        config['swarm.probe_hosts.enabled_for_swarm'] = false
        config['swarm.flush_zombies.enabled_for_swarm'] = false
        config['swarm.flush_zombies.zombie_ttl'] = 1_000
      end

      client.lock('rw.zombie', read_write_mode: :read, ttl: 500_000)
      client.probe_hosts
      sleep(1.5) # NOTE: zombie_ttl is reached (no more host probes)

      zombie_host = client.current_host_id
      zombie_acquirer = client.current_acquirer_id
      zombie_read_lock = 'rql:lock_readers:rw.zombie'

      expect(client.locked?('rw.zombie')).to eq(true)
      expect(client.zombies_info).to match({
        zombie_hosts: include(zombie_host),
        zombie_acquirers: include(zombie_acquirer),
        zombie_locks: include(zombie_read_lock)
      })
      expect(client.zombie_locks).to include(zombie_read_lock)
      expect(client.zombie_acquirers).to include(zombie_acquirer)

      expect(client.flush_zombies).to match({
        ok: true,
        deleted_zombie_hosts: include(zombie_host),
        deleted_zombie_acquirers: include(zombie_acquirer),
        deleted_zombie_locks: include(zombie_read_lock)
      })
      expect(client.locked?('rw.zombie')).to eq(false)
      expect(client.zombie_locks).to eq(Set.new)
    end

    specify 'zombie lock requests (write and read lock queues)' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['swarm.auto_swarm'] = false
        # NOTE: we will manually probe hosts and flush zombies
        config['swarm.probe_hosts.enabled_for_swarm'] = false
        config['swarm.flush_zombies.enabled_for_swarm'] = false
        config['swarm.flush_zombies.zombie_ttl'] = 1_000
      end

      # NOTE: each fiber is a separate acquirer of the current (zombie) host
      writer_fibers = Array.new(2) do |index|
        Fiber.new do
          client.lock("rw.zombie.write.#{index}", ttl: 500_000)
          client.current_acquirer_id
        end
      end
      reader_fiber = Fiber.new do
        client.lock('rw.zombie.read', read_write_mode: :read, ttl: 500_000)
        client.current_acquirer_id
      end
      zombie_writers = writer_fibers.map(&:resume)
      zombie_reader = reader_fiber.resume
      # NOTE: an acquirer of the zombie host that holds no locks (requests only)
      zombie_requester = client.current_acquirer_id(fiber_id: 123_456_789)
      live_acquirer = 'rql:acq:1/2/3/4/live'

      # NOTE: zombie and live requests in the queues of another lock (both modes)
      now = Time.now.to_f
      redis.call(
        'ZADD', 'rql:lock_queue:rw.zombie.queue',
        now, zombie_writers[0], now, zombie_writers[1], now, zombie_requester, now, live_acquirer
      )
      redis.call(
        'ZADD', 'rql:lock_read_queue:rw.zombie.queue',
        now, zombie_writers[1], now, zombie_reader, now, zombie_requester, now, live_acquirer
      )
      # NOTE: the queues are written directly (not by RQL acquirers, like keys of older RQL
      #   versions): the keyspace SCAN finds them, the lock index gets them by `#reindex_locks`
      #   (the swarm finds locks and queues via the lock index only then);
      client.reindex_locks if client.config['lock_index_enabled']

      client.probe_hosts
      sleep(1.5) # NOTE: zombie_ttl is reached (no more host probes)

      # NOTE: zombie acquirers of the zombie info are the acquirers of zombie locks
      expect(client.zombie_acquirers).to contain_exactly(*zombie_writers, zombie_reader)
      expect(client.flush_zombies).to match({
        ok: true,
        deleted_zombie_hosts: include(client.current_host_id),
        # NOTE: requests of the zombie host are dropped even without locks (and reported)
        deleted_zombie_acquirers: contain_exactly(*zombie_writers, zombie_reader, zombie_requester),
        deleted_zombie_locks: include(
          'rql:lock:rw.zombie.write.0',
          'rql:lock:rw.zombie.write.1',
          'rql:lock_readers:rw.zombie.read'
        )
      })
      # NOTE: only the requests of zombie acquirers (of zombie hosts) are dropped
      expect(client.queue_info('rw.zombie.queue')).to match({
        'lock_queue' => 'rql:lock_queue:rw.zombie.queue',
        'queue' => contain_exactly(
          {
            'acq_id' => live_acquirer, 'score' => be_a(Numeric), 'rw_mode' => 'write',
            'priority' => 0
          }
        ),
        'read_lock_queue' => 'rql:lock_read_queue:rw.zombie.queue',
        'read_queue' => contain_exactly(
          {
            'acq_id' => live_acquirer, 'score' => be_a(Numeric), 'rw_mode' => 'read',
            'priority' => 0
          }
        )
      })
      expect(client.zombie_locks).to eq(Set.new)

      client.clear_locks
    end

    specify 'lock state pipeline layout' do
      # NOTE: (see "pipeline layout" in `TryToLock#try_to_lock`)
      #   - try-lock replies of the lock state pipeline are read by their positions;
      #   - read lock requests do not send the write-only commands (the write-only tail), so
      #     the read lock request pipeline should be the beginning of the write lock request
      #     pipeline and the write-only tail should be the last part of it;
      #   - eager queueing (`:wait_for_lock`) sends the lock request queueing commands right after
      #     the head of the lock state pipeline; without eager queueing (`:work_through`) they are
      #     sent in a separate pipeline;
      #   - the dead requests of the priority band of the request are dropped before `ZADD NX`
      #     (the old position of a requeued request is dropped before its new position is added)
      #     and the queue heads (other bands: only a dead blocking request, in another round trip);
      #   - the enabled lock index adds the lock index commands to the end of the queueing commands
      #     (their replies are not read);
      #   - pipelines are observed via a separate pool (the same db) with a recording middleware;
      try_to_lock = RedisQueuedLocks::Acquirer::AcquireLock::TryToLock
      pipelines = []
      recorder = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          pipelines << commands.map(&:dup)
          super(commands, redis_config, &block)
        end
      end
      recorded_redis = RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      client = RedisQueuedLocks::Client.new(recorded_redis)
      queue = 'rql:lock_queue:rw.pipeline'
      read_queue = 'rql:lock_read_queue:rw.pipeline'
      lock_index_enabled = client.config['lock_index_enabled']
      queueing_size = lock_index_enabled ? 9 : 5

      # NOTE: the lock state pipeline (the only one with TIME) and the pipeline with
      #   the lock request queueing (ZADD NX) of an uncontended lock
      lock_pipelines = lambda do |read_write_mode, conflict_strategy, priority = 0|
        pipelines.clear
        client.lock('rw.pipeline', read_write_mode:, conflict_strategy:, priority:, ttl: 10_000) {}
        [
          pipelines.find { |commands| commands.include?(['TIME']) },
          pipelines.find do |commands|
            commands.any? { |command| command[0..2] in ['ZADD', _, 'NX'] }
          end
        ]
      end
      # NOTE: the dead request removal of the priority band (`(-p * 2**32) .. (now - queue ttl) -
      #   p * 2**32`); the default queue ttl is 15 seconds
      expect_band_removal = lambda do |command, band_queue, priority|
        expect(command[0..2]).to eq(['ZREMRANGEBYSCORE', band_queue, (-priority * (2**32)).to_s])
        expect(Float(command[3])).to be_within(5).of(Time.now.to_f - 15 - (priority * (2**32)))
      end
      expect_queueing = lambda do |queueing, request_queue, opposite_request_queue, priority = 0|
        expect(queueing.map(&:first)).to eq(
          %w[ZREMRANGEBYSCORE ZREMRANGEBYSCORE ZADD ZRANGE ZRANGE] +
          # NOTE: the request queue TTL and the lock index (the enabled lock index only: new
          #   commands go to the end)
          (lock_index_enabled ? %w[PEXPIRE PEXPIRE ZADD ZREMRANGEBYSCORE] : [])
        )
        # NOTE: the priority band of the request (before `ZADD NX` and the queue heads)
        expect_band_removal.call(queueing[0], request_queue, priority)
        expect_band_removal.call(queueing[1], opposite_request_queue, priority)
        expect(queueing[2]).to match(['ZADD', request_queue, 'NX', be_a(String), be_a(String)])
        expect(Float(queueing[2][3])).to be_within(5).of(Time.now.to_f - (priority * (2**32)))
        expect(queueing[try_to_lock::QUEUE_HEAD_REPLY]).to eq(
          ['ZRANGE', request_queue, '0', '0', 'WITHSCORES']
        )
        expect(queueing[try_to_lock::OPPOSITE_QUEUE_HEAD_REPLY]).to eq(
          ['ZRANGE', opposite_request_queue, '0', '0', 'WITHSCORES']
        )
        next unless lock_index_enabled

        expect(queueing[5]).to eq(['PEXPIRE', request_queue, '15000', 'NX'])
        expect(queueing[6]).to eq(['PEXPIRE', request_queue, '15000', 'GT'])
        expect(queueing[7]).to match(
          ['ZADD', 'rql:index:locks', 'GT', match(/\A\d+\z/), 'rw.pipeline']
        )
        expect(queueing[8]).to match(
          ['ZREMRANGEBYSCORE', 'rql:index:locks', '-inf', match(/\A\d+\z/)]
        )
      end

      %i[wait_for_lock work_through].each do |conflict_strategy|
        write_state, write_queueing = lock_pipelines.call(:write, conflict_strategy)
        read_state, read_queueing = lock_pipelines.call(:read, conflict_strategy)

        aggregate_failures "the write-only tail (#{conflict_strategy})" do
          # NOTE: command names only (queueing commands have mode-specific keys)
          expect(write_state.first(read_state.size).map(&:first)).to eq(read_state.map(&:first))
          expect(write_state.drop(read_state.size)).to eq([
            ['ZRANGE', 'rql:lock_readers:rw.pipeline', '-1', '-1', 'WITHSCORES']
          ])
        end

        aggregate_failures "lock request queueing (#{conflict_strategy})" do
          if conflict_strategy == :wait_for_lock
            # NOTE: eager queueing: right after the head of the lock state pipeline
            queueing_at = try_to_lock::LOCK_STATE_QUEUE_REPLIES_AT
            expect(write_queueing).to equal(write_state)
            expect(read_queueing).to equal(read_state)
            expect_queueing.call(write_state[queueing_at, queueing_size], queue, read_queue)
            expect_queueing.call(read_state[queueing_at, queueing_size], read_queue, queue)
          else
            # NOTE: a separate pipeline
            expect(write_queueing).not_to equal(write_state)
            expect(read_queueing).not_to equal(read_state)
            expect_queueing.call(write_queueing, queue, read_queue)
            expect_queueing.call(read_queueing, read_queue, queue)
          end
        end
      end

      aggregate_failures 'lock request queueing of other priorities' do
        [100, 1, -1, -100].each do |priority|
          write_state, = lock_pipelines.call(:write, :wait_for_lock, priority)
          read_state, = lock_pipelines.call(:read, :wait_for_lock, priority)
          queueing_at = try_to_lock::LOCK_STATE_QUEUE_REPLIES_AT
          expect_queueing.call(write_state[queueing_at, queueing_size], queue, read_queue, priority)
          expect_queueing.call(read_state[queueing_at, queueing_size], read_queue, queue, priority)
        end
      end
      expect(client.keys).to be_empty

      recorded_redis.close
    end

    specify 'unlock round trips' do
      # NOTE: round trips are observed via a separate pool (the same db) with a recording middleware
      round_trips = []
      recorder = Module.new do
        define_method(:call) do |command, redis_config, &block|
          round_trips << [command.first]
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |commands, redis_config, &block|
          round_trips << commands.map(&:first)
          super(commands, redis_config, &block)
        end
      end
      recorded_redis = RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      client = RedisQueuedLocks::Client.new(recorded_redis)
      readers_client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures 'without read locks: one round trip (the release transaction)' do
        client.lock('rw.unlock', ttl: 10_000)
        round_trips.clear
        expect(client.unlock('rw.unlock')).to match({
          ok: true,
          result: hash_including(queue_res: :nothing_to_release, lock_res: :released)
        })
        expect(round_trips.size).to eq(1)
        expect(round_trips.first).to include('MULTI', 'ZRANGE', 'EXEC')
      end

      aggregate_failures 'with read locks: the read lock data is dropped in one more round trip' do
        # NOTE: each thread is a separate acquirer (thread references are kept till the end)
        readers = Array.new(2) do
          Thread.new do
            readers_client.lock('rw.unlock', read_write_mode: :read, ttl: 10_000)
          end
        end
        readers.each(&:join)
        read_lock_keys = readers.map do |reader|
          RedisQueuedLocks::Resource.prepare_read_lock_key(
            'rw.unlock', reader.value[:result][:acq_id]
          )
        end
        expect(redis.call('EXISTS', *read_lock_keys)).to eq(2)

        round_trips.clear
        expect(client.unlock('rw.unlock')).to match({
          ok: true,
          result: hash_including(lock_res: :released)
        })
        expect(round_trips.size).to eq(2)
        expect(round_trips.last).to eq(['DEL'])
        expect(redis.call('EXISTS', *read_lock_keys)).to eq(0)
        expect(client.locked?('rw.unlock')).to eq(false)
      end

      expect(client.keys).to be_empty
      recorded_redis.close
    end

    specify 'pre-check of retries and fail_fast attempts (round trips)' do
      # NOTE: round trips are observed via a separate pool (the same db, one connection) with
      #   a recording middleware;
      round_trips = []
      recorder = Module.new do
        define_method(:call) do |command, redis_config, &block|
          round_trips << [command.first]
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |commands, redis_config, &block|
          round_trips << commands.map(&:first)
          super(commands, redis_config, &block)
        end
      end
      recorded_redis =
        RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5, size: 1)
      test_logger = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << "#{progname} : #{yield if block_given?}"
        end
      end.new
      client = RedisQueuedLocks::Client.new(recorded_redis) do |config|
        config['retry_delay'] = 1
        config['retry_jitter'] = 1
      end
      holder_client = RedisQueuedLocks::Client.new(redis)

      # NOTE: the lock is obtained by another acquirer (the thread reference is kept till the end)
      holder = Thread.new { holder_client.lock('rw.precheck', ttl: 10_000) }
      holder.join
      client.locked?('rw.precheck') # NOTE: establish the recorded connection

      aggregate_failures 'retries: one round trip for each failed retry (no WATCH)' do
        round_trips.clear
        expect(client.lock('rw.precheck', ttl: 1_000, retry_count: 3)).to match({
          ok: false,
          result: :retry_limit_reached
        })
        # NOTE:
        #   the first attempt (WATCH, lock state with the queueing, MULTI/EXEC),
        #   two pre-checked retries, the dequeue (ZREM)
        expect(round_trips.size).to eq(6)
        expect(round_trips.count { |commands| commands.include?('WATCH') }).to eq(1)
      end

      aggregate_failures 'retries: the pre-checked retries log the same events as the attempts' do
        client.lock(
          'rw.precheck', ttl: 1_000, retry_count: 3, logger: test_logger, log_lock_try: true
        )
        %w[acq_added_to_queue remove_expired_acqs get_first_from_queue exit__lock_still_obtained]
          .each do |event|
            expect(test_logger.logs.count { |log| log.include?("try_lock.#{event}]") }).to eq(3)
          end
      end

      aggregate_failures 'fail_fast on the obtained lock: one round trip' do
        round_trips.clear
        expect(client.lock('rw.precheck', fail_fast: true)).to match({
          ok: false,
          result: :fail_fast_no_try
        })
        expect(round_trips.size).to eq(1)
      end

      aggregate_failures 'fail_fast on the free lock: the pre-check and the attempt' do
        holder_client.unlock('rw.precheck')
        round_trips.clear
        expect(client.lock('rw.precheck', fail_fast: true, ttl: 1_000)).to match({
          ok: true,
          result: hash_including(process: :lock_obtaining)
        })
        # NOTE: pre-check, WATCH, lock state, lock request queueing, MULTI/EXEC
        expect(round_trips.size).to eq(5)
      end

      client.clear_locks
      recorded_redis.close
    end

    specify 'lock-iterating operations: one pass (keyspace or lock index) with small batches' do
      client = RedisQueuedLocks::Client.new(redis)
      acquirer_id = client.current_acquirer_id
      host_id = client.current_host_id
      dead_acquirer = 'rql:acq:1/2/3/4/dead'
      live_acquirer = 'rql:acq:1/2/3/4/live'
      write_locks = %w[scan.w.0 scan.w.1 scan.w.2]
      # NOTE: the readers registry (and read lock data) of a lock with `queue:` in its name
      #   matches the lock queues pattern (`rql:lock_*queue:*`) too
      read_locks = %w[scan.r.0 scan.r.1 scan.my_queue:r]
      write_locks.each { |lock_name| client.lock(lock_name, ttl: 60_000) }
      read_locks.each { |lock_name| client.lock(lock_name, read_write_mode: :read, ttl: 60_000) }
      lock_keys = (write_locks + read_locks).map { |lock_name| "rql:lock:#{lock_name}" }

      now = Time.now.to_f
      queues = %w[scan.q.0 scan.q.1 scan.q.2].flat_map do |lock_name|
        ["rql:lock_queue:#{lock_name}", "rql:lock_read_queue:#{lock_name}"]
      end
      queues.each do |lock_queue|
        redis.call(
          'ZADD', lock_queue, now - 60, dead_acquirer, now, live_acquirer, now, acquirer_id
        )
      end
      # NOTE: the queues are written directly (not by RQL acquirers): the keyspace SCAN finds
      #   them, the lock index gets them by `#reindex_locks` (the lock index is the only lookup
      #   then);
      client.reindex_locks if client.config['lock_index_enabled']
      # NOTE: a key matched by `KEY_PATTERN` (`rql:lock*`) out of the lock key families
      redis.call('SET', 'rql:lockX', 'value')

      aggregate_failures 'locks and queues' do
        expect(client.locks(scan_size: 2)).to contain_exactly(*lock_keys)
        expect(client.queues(scan_size: 2)).to contain_exactly(*queues)
        expect(client.locks_info(scan_size: 2)).to contain_exactly(
          *write_locks.map do |lock_name|
            match({
              lock: "rql:lock:#{lock_name}",
              status: :alive,
              info: hash_including(
                'acq_id' => acquirer_id, 'lock_key' => "rql:lock:#{lock_name}", 'rw_mode' => 'write'
              )
            })
          end,
          *read_locks.map do |lock_name|
            match({
              lock: "rql:lock:#{lock_name}",
              status: :alive,
              info: hash_including(
                'rw_mode' => 'read',
                'readers' => contain_exactly(
                  hash_including('acq_id' => acquirer_id, 'ts' => be_a(Float), 'ini_ttl' => 60_000)
                )
              )
            })
          end
        )
        expect(client.queues_info(scan_size: 2)).to contain_exactly(
          *queues.map do |lock_queue|
            match({
              queue: lock_queue,
              requests: contain_exactly(
                hash_including('acq_id' => dead_acquirer),
                hash_including('acq_id' => live_acquirer),
                hash_including('acq_id' => acquirer_id)
              )
            })
          end
        )
      end

      aggregate_failures 'clear_dead_requests' do
        # NOTE: 6 queues (keyspace) or 9 lock names (6 queues, lock index): full batches and
        #   the rest
        expect(client.clear_dead_requests(dead_ttl: 30_000, scan_size: 4)).to match({
          ok: true,
          result: match({ processed_queues: contain_exactly(*queues) })
        })
        queues.each do |lock_queue|
          expect(redis.call('ZRANGE', lock_queue, '0', '-1')).to contain_exactly(
            live_acquirer, acquirer_id
          )
        end
      end

      aggregate_failures 'clear_locks_of' do
        expect(
          client.clear_locks_of(host_id:, acquirer_id:, lock_scan_size: 2, queue_scan_size: 4)
        ).to match({
          ok: true,
          # NOTE: 3 write locks + 3 read locks; requests in 6 queues
          result: match({ rel_key_cnt: 6, tch_queue_cnt: 6, rel_time: be_a(Numeric) })
        })
        expect(client.locks).to be_empty
        queues.each do |lock_queue|
          expect(redis.call('ZRANGE', lock_queue, '0', '-1')).to eq([live_acquirer])
        end
      end

      aggregate_failures 'clear_locks' do
        client.lock('scan.w.0', ttl: 60_000)
        client.lock('scan.r.0', read_write_mode: :read, ttl: 60_000)
        expect(client.clear_locks(batch_size: 2)).to match({
          ok: true,
          # NOTE: write lock, readers registry, read lock data, 6 lock queues
          result: match({ rel_key_cnt: 9, rel_time: be_a(Numeric) })
        })
        if client.config['lock_index_enabled']
          # NOTE: keys out of the lock key families are not visited (they are not lock keys)
          expect(client.keys).to be_empty
          expect(redis.call('EXISTS', 'rql:lockX')).to eq(1)
          # NOTE: the released lock names are dropped from the lock index
          expect(redis.call('ZCARD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY)).to eq(0)
        else
          # NOTE: keys out of the lock key families are not deleted (`#keys` lists all `rql:lock*`)
          expect(client.keys).to contain_exactly('rql:lockX')
        end
      end

      redis.call('DEL', 'rql:lockX')
    end

    specify 'zombie locks and requests with small batches' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['swarm.auto_swarm'] = false
        # NOTE: we will manually probe hosts and flush zombies
        config['swarm.probe_hosts.enabled_for_swarm'] = false
        config['swarm.flush_zombies.enabled_for_swarm'] = false
        config['swarm.flush_zombies.zombie_ttl'] = 1_000
      end

      # NOTE: each fiber is a separate acquirer of the current (zombie) host
      zombie_fibers = Array.new(3) do |index|
        Fiber.new do
          client.lock("zombie.batch.w.#{index}", ttl: 500_000)
          client.lock("zombie.batch.r.#{index}", read_write_mode: :read, ttl: 500_000)
          client.current_acquirer_id
        end
      end
      zombie_acquirers = zombie_fibers.map(&:resume)
      zombie_locks = Array.new(3) do |index|
        ["rql:lock:zombie.batch.w.#{index}", "rql:lock_readers:zombie.batch.r.#{index}"]
      end.flatten
      live_acquirer = 'rql:acq:1/2/3/4/live'

      now = Time.now.to_f
      queues = %w[zombie.batch.q.0 zombie.batch.q.1 zombie.batch.q.2].flat_map do |lock_name|
        ["rql:lock_queue:#{lock_name}", "rql:lock_read_queue:#{lock_name}"]
      end
      queues.each do |lock_queue|
        redis.call(
          'ZADD', lock_queue,
          now, zombie_acquirers[0], now, zombie_acquirers[2], now, live_acquirer
        )
      end
      # NOTE: the queues are written directly (not by RQL acquirers, like keys of older RQL
      #   versions): the keyspace SCAN finds them, the lock index gets them by `#reindex_locks`
      #   (the swarm finds locks and queues via the lock index only then);
      client.reindex_locks(scan_size: 2) if client.config['lock_index_enabled']

      client.probe_hosts
      sleep(1.5) # NOTE: zombie_ttl is reached (no more host probes)

      expect(client.zombies_info(lock_scan_size: 2)).to match({
        zombie_hosts: include(client.current_host_id),
        zombie_acquirers: contain_exactly(*zombie_acquirers),
        zombie_locks: contain_exactly(*zombie_locks)
      })
      expect(client.flush_zombies(lock_scan_size: 2, queue_scan_size: 2)).to match({
        ok: true,
        deleted_zombie_hosts: include(client.current_host_id),
        deleted_zombie_acquirers: contain_exactly(*zombie_acquirers),
        deleted_zombie_locks: contain_exactly(*zombie_locks)
      })
      expect(client.locks).to be_empty
      queues.each do |lock_queue|
        expect(redis.call('ZRANGE', lock_queue, '0', '-1')).to eq([live_acquirer])
      end
      # NOTE: no zombie hosts after the flush => no zombie locks (and no SCAN)
      expect(client.zombies_info(lock_scan_size: 2)).to match({
        zombie_hosts: Set.new,
        zombie_acquirers: Set.new,
        zombie_locks: Set.new
      })

      client.clear_locks
    end

    specify 'read lock meta and read lock data' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      aggregate_failures 'each reader has its own data (meta)' do
        holders = Array.new(2) do |index|
          Thread.new do
            client.lock(
              'rw.meta',
              read_write_mode: :read,
              ttl: 10_000,
              meta: { 'reader' => index.to_s, 'num' => index }
            )
          end
        end
        holders.each(&:join)
        results = holders.map { |holder| holder.value[:result] }
        read_lock_keys = results.map do |result|
          RedisQueuedLocks::Resource.prepare_read_lock_key('rw.meta', result[:acq_id])
        end

        expect(client.lock_info('rw.meta')['readers']).to contain_exactly(
          *results.each_with_index.map do |result, index|
            {
              'acq_id' => result[:acq_id],
              'hst_id' => result[:hst_id],
              'ts' => be_a(Float),
              'ini_ttl' => 10_000,
              'rem_ttl' => be_a(Integer),
              'reader' => index.to_s,
              'num' => index.to_s
            }
          end
        )
        expect(client.locks_info).to include(match({
          lock: 'rql:lock:rw.meta',
          status: :alive,
          info: hash_including(
            'readers' => contain_exactly(
              hash_including('reader' => '0'),
              hash_including('reader' => '1')
            )
          )
        }))
        expect(client.keys).to include(*read_lock_keys)

        # NOTE:
        #   acquirer and host ids are not stored in the read lock data (both are derived from
        #   the acquirer id), the info reports them as the first fields (like the write lock info)
        read_lock_keys.each_with_index do |read_lock_key, index|
          expect(redis.call('HGETALL', read_lock_key)).to match({
            'ts' => be_a(String),
            'ini_ttl' => '10000',
            'reader' => index.to_s,
            'num' => index.to_s
          })
        end
        expect(client.lock_info('rw.meta')['readers'].map { |reader| reader.keys.first(2) }).to eq(
          [%w[acq_id hst_id], %w[acq_id hst_id]]
        )

        # NOTE: #unlock drops the read lock data too
        client.unlock('rw.meta')
        expect(redis.call('EXISTS', *read_lock_keys)).to eq(0)
      end

      aggregate_failures 'read lock data of reentrant read locks' do
        client.lock('rw.meta', read_write_mode: :read, ttl: 10_000, meta: { 'kek' => 'pek' }) do
          client.lock('rw.meta', read_write_mode: :read, conflict_strategy: :work_through) { 1 }
          client.lock(
            'rw.meta',
            read_write_mode: :read,
            ttl: 2_000,
            conflict_strategy: :extendable_work_through
          ) { 1 }

          expect(client.lock_info('rw.meta')['readers']).to contain_exactly(hash_including(
            'acq_id' => client.current_acquirer_id,
            'kek' => 'pek',
            'ini_ttl' => 10_000,
            'spc_cnt' => 2,
            'l_spc_ts' => be_a(Float),
            'spc_ext_ttl' => 2_000,
            'l_spc_ext_ini_ttl' => 2_000,
            'l_spc_ext_ts' => be_a(Float)
          ))
        end
        # NOTE: the read lock and its data are released after the block
        expect(client.locked?('rw.meta')).to eq(false)
        expect(client.keys).to eq(Set.new)
      end
    end

    specify 'lock series of read locks' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
      timeline = {}
      timeline_lock = Mutex.new
      mark = lambda do |event|
        timeline_lock.synchronize { timeline[event] = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      aggregate_failures 'read lock series share the locks, writer waits for them' do
        readers = Array.new(2) do |index|
          Thread.new do
            client.lock_series(
              'rw.series.a', 'rw.series.b',
              read_write_mode: :read,
              ttl: 10_000,
              meta: { 'series' => index.to_s }
            ) do
              mark.call(:"reader#{index}_in")
              sleep(0.5)
              mark.call(:"reader#{index}_out")
            end
          end
        end
        sleep(0.2) # NOTE: give a timespot to readers to obtain the lock series
        expect(client.lock_info('rw.series.a')['readers']).to contain_exactly(
          hash_including('series' => '0'),
          hash_including('series' => '1')
        )
        expect(client.lock_info('rw.series.b')['readers'].size).to eq(2)

        writer = Thread.new do
          client.lock('rw.series.b', read_write_mode: :write, ttl: 10_000) { mark.call(:writer_in) }
        end
        [*readers, writer].each(&:join)

        expect(timeline[:reader0_in]).to be < timeline[:reader1_out]
        expect(timeline[:reader1_in]).to be < timeline[:reader0_out]
        expect(timeline[:writer_in]).to be >= timeline[:reader0_out]
        expect(timeline[:writer_in]).to be >= timeline[:reader1_out]
        # NOTE: read locks (and their data) are released after the block
        expect(client.keys).to eq(Set.new)
      end

      aggregate_failures 'read locks of the failed lock series are released' do
        holder = Thread.new { client.lock('rw.series.c', read_write_mode: :write, ttl: 10_000) }
        holder.join

        expect do
          client.lock_series!(
            'rw.series.a', 'rw.series.c', read_write_mode: :read, fail_fast: true
          ) { :never }
        end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
        expect(client.locked?('rw.series.a')).to eq(false)
        client.unlock('rw.series.c')
      end

      aggregate_failures 'reentrant read locks of the lock series are not released by the series' do
        client.lock('rw.series.a', read_write_mode: :read, ttl: 10_000) do
          client.lock_series(
            'rw.series.a', 'rw.series.b',
            read_write_mode: :read,
            conflict_strategy: :work_through
          ) { :ok }
          # NOTE: the outer read lock is still obtained, the series lock is released
          expect(client.lock_info('rw.series.a')['readers']).to contain_exactly(
            hash_including('acq_id' => client.current_acquirer_id)
          )
          expect(client.locked?('rw.series.b')).to eq(false)
        end
        expect(client.locked?('rw.series.a')).to eq(false)
      end
    end

    specify '#unlock_read and #extend_lock_ttl for read locks' do
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
        config['instrumenter'] = test_notifier
      end
      other_reader = Thread.new { client.lock('rw.own', read_write_mode: :read, ttl: 10_000) }
      other_reader.join
      other_acquirer_id = other_reader.value[:result][:acq_id]
      client.lock('rw.own', read_write_mode: :read, ttl: 3_000, meta: { 'kek' => 'pek' })
      own_acquirer_id = client.current_acquirer_id
      read_lock_key = RedisQueuedLocks::Resource.prepare_read_lock_key('rw.own', own_acquirer_id)
      reader_info = lambda do |acquirer_id|
        client.lock_info('rw.own')['readers'].find { |reader| reader['acq_id'] == acquirer_id }
      end

      aggregate_failures 'extend_lock_ttl extends the read lock of the current acquirer only' do
        expect(client.extend_lock_ttl('rw.own', 20_000, read_write_mode: :read)).to eq({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(reader_info.call(own_acquirer_id)['rem_ttl']).to be > 20_000
        expect(reader_info.call(other_acquirer_id)['rem_ttl']).to be <= 10_000
        expect(redis.call('PTTL', read_lock_key)).to be > 20_000
        expect(redis.call('PTTL', 'rql:lock_readers:rw.own')).to be > 20_000
      end

      aggregate_failures 'unlock_read releases the read lock of the current acquirer only' do
        expect(client.unlock_read('rw.own')).to match({
          ok: true,
          result: {
            rel_time: be_a(Numeric),
            rel_key: 'rql:lock:rw.own',
            rel_acq_id: own_acquirer_id,
            lock_res: :released
          }
        })
        expect(client.lock_info('rw.own')['readers']).to contain_exactly(
          hash_including('acq_id' => other_acquirer_id)
        )
        expect(redis.call('EXISTS', read_lock_key)).to eq(0)
        expect(test_notifier.notifications).to include(match({
          event: 'redis_queued_locks.explicit_read_lock_release',
          payload: hash_including(
            lock_key: 'rql:lock:rw.own',
            acq_id: own_acquirer_id,
            lock_res: :released,
            rel_time: be_a(Numeric),
            at: be_a(Float)
          )
        }))

        # NOTE: there is no read lock of the current acquirer anymore
        expect(client.release_read_lock('rw.own')).to match({
          ok: true, result: hash_including(lock_res: :nothing_to_release)
        })
        expect(client.extend_lock_ttl('rw.own', 1_000, read_write_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
      end

      aggregate_failures 'unlock_read releases the read lock of the custom acquirer only' do
        custom_reader = Thread.new { client.lock('rw.custom', read_write_mode: :read, ttl: 10_000) }
        custom_reader.join
        custom_acquirer_id = custom_reader.value[:result][:acq_id]
        custom_read_lock_key =
          RedisQueuedLocks::Resource.prepare_read_lock_key('rw.custom', custom_acquirer_id)
        client.lock('rw.custom', read_write_mode: :read, ttl: 10_000)

        expect(
          client.unlock_read('rw.custom', acquirer_id: custom_acquirer_id, identity: 'ignored')
        ).to match({
          ok: true,
          result: {
            rel_time: be_a(Numeric),
            rel_key: 'rql:lock:rw.custom',
            rel_acq_id: custom_acquirer_id,
            lock_res: :released
          }
        })
        expect(client.lock_info('rw.custom')['readers']).to contain_exactly(
          hash_including('acq_id' => own_acquirer_id)
        )
        expect(redis.call('EXISTS', custom_read_lock_key)).to eq(0)
        expect(test_notifier.notifications).to include(match({
          event: 'redis_queued_locks.explicit_read_lock_release',
          payload: hash_including(lock_key: 'rql:lock:rw.custom', acq_id: custom_acquirer_id)
        }))
        expect(client.unlock_read('rw.custom', acquirer_id: custom_acquirer_id)).to match({
          ok: true, result: hash_including(lock_res: :nothing_to_release)
        })

        client.unlock('rw.custom')
      end

      aggregate_failures 'expired read lock is not extended (not revived)' do
        client.lock('rw.expiring', read_write_mode: :read, ttl: 100)
        sleep(0.2) # NOTE: the read lock is expired
        expect(client.extend_lock_ttl('rw.expiring', 10_000, read_write_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
        expect(client.locked?('rw.expiring')).to eq(false)
      end

      aggregate_failures 'read lock is not extended while the write lock is held' do
        writer = Thread.new { client.lock('rw.written', ttl: 10_000) }
        writer.join
        expect(client.extend_lock_ttl('rw.written', 10_000, read_write_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
        client.unlock('rw.written')
      end

      client.unlock('rw.own')
    end

    specify '#extend_lock_ttl with all_read_locks: true' do
      client = RedisQueuedLocks::Client.new(redis)
      reader_threads = [5_000, 8_000, 100].map do |ttl|
        Thread.new { client.lock('rw.all', read_write_mode: :read, ttl:) }
      end
      reader_threads.each(&:join)
      long_reader_ids = reader_threads.first(2).map { |thread| thread.value[:result][:acq_id] }
      expired_reader_id = reader_threads.last.value[:result][:acq_id]
      own_reader_id = client.current_acquirer_id
      reader_ttl = lambda do |acquirer_id|
        client.lock_info('rw.all')['readers'].find { |reader| reader['acq_id'] == acquirer_id }
          &.fetch('rem_ttl')
      end
      sleep(0.2) # NOTE: the last read lock is expired

      aggregate_failures 'all live read locks are extended, expired read locks are not revived' do
        expect(
          client.extend_lock_ttl('rw.all', 20_000, read_write_mode: :read, all_read_locks: true)
        ).to eq({ ok: true, result: { extended_locks_count: 2 } })
        expect(reader_ttl.call(long_reader_ids[0])).to be_between(24_000, 25_000)
        expect(reader_ttl.call(long_reader_ids[1])).to be_between(27_000, 28_000)
        expect(reader_ttl.call(expired_reader_id)).to eq(nil)
        long_reader_ids.each do |acquirer_id|
          read_lock_key = RedisQueuedLocks::Resource.prepare_read_lock_key('rw.all', acquirer_id)
          expect(redis.call('PTTL', read_lock_key)).to be > 24_000
        end
        expect(redis.call('PTTL', 'rql:lock_readers:rw.all')).to be > 27_000
      end

      aggregate_failures 'all_read_locks: false (default) extends the own read lock only' do
        # NOTE: the current acquirer has no read lock
        expect(reader_ttl.call(own_reader_id)).to eq(nil)
        expect(client.extend_lock_ttl('rw.all', 1_000, read_write_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
      end

      aggregate_failures 'all_read_locks is ignored for write mode' do
        # NOTE: there is no write lock (only read locks)
        expect(client.extend_lock_ttl('rw.all', 1_000, all_read_locks: true)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
        expect(reader_ttl.call(long_reader_ids[0])).to be <= 25_000
      end

      aggregate_failures 'no live read locks or the write lock is held' do
        expect(
          client.extend_lock_ttl('rw.all.none', 1_000, read_write_mode: :read, all_read_locks: true)
        ).to eq({ ok: false, result: :async_expire_or_no_lock })

        writer = Thread.new { client.lock('rw.all.written', ttl: 10_000) }
        writer.join
        expect(
          client.extend_lock_ttl(
            'rw.all.written', 1_000, read_write_mode: :read, all_read_locks: true
          )
        ).to eq({ ok: false, result: :async_expire_or_no_lock })
      end

      client.unlock('rw.all')
      client.unlock('rw.all.written')
      expect(client.keys).to be_empty
    end

    specify 'read/write lock arguments validation' do
      client = RedisQueuedLocks::Client.new(redis)

      # NOTE: (RBS) invalid values are checked via untyped entry points (lock_series has no RBS)
      expect do
        RedisQueuedLocks::Acquirer::ExtendLockTTL.extend_lock_ttl(
          redis, 'rw.args', 1_000, :reed, false, client.current_acquirer_id,
          client.config['lock_index_enabled'],
          client.config['logger'], client.config['instrumenter'], nil,
          false, 15, RedisQueuedLocks::Logging::Sampler, false,
          false, 15, RedisQueuedLocks::Instrument::Sampler, false
        )
      end.to raise_error(RedisQueuedLocks::ArgumentError, /read_write_mode/)
      # NOTE: (RBS) a type-invalid value (`nil` for `bool all_read_locks`) can't reach the runtime
      #   validation under the RBS runtime type checks (the hook raises first)
      unless RBS_RUNTIME_TEST
        expect do
          RedisQueuedLocks::Acquirer::ExtendLockTTL.extend_lock_ttl(
            redis, 'rw.args', 1_000, :read, nil, client.current_acquirer_id,
            client.config['lock_index_enabled'],
            client.config['logger'], client.config['instrumenter'], nil,
            false, 15, RedisQueuedLocks::Logging::Sampler, false,
            false, 15, RedisQueuedLocks::Instrument::Sampler, false
          )
        end.to raise_error(RedisQueuedLocks::ArgumentError, /all_read_locks/)
        # NOTE: `all_read_locks` is ignored for `:write` mode
        expect(
          RedisQueuedLocks::Acquirer::ExtendLockTTL.extend_lock_ttl(
            redis, 'rw.args', 1_000, :write, nil, client.current_acquirer_id,
            client.config['lock_index_enabled'],
            client.config['logger'], client.config['instrumenter'], nil,
            false, 15, RedisQueuedLocks::Logging::Sampler, false,
            false, 15, RedisQueuedLocks::Instrument::Sampler, false
          )
        ).to eq({ ok: false, result: :async_expire_or_no_lock })
      end
      expect do
        client.lock('rw.args', read_write_mode: :read, meta: { 'acq_id' => 'pek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError, /meta/)
      expect do
        client.lock('rw.args', read_write_mode: :read, ttl: 0)
      end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
      expect do
        client.lock_series('rw.args.a', 'rw.args.b', read_write_mode: :reed)
      end.to raise_error(RedisQueuedLocks::ArgumentError, /read_write_mode/)
      expect(client.locked?('rw.args')).to eq(false)
    end

    specify 'read/write locks: logs and instrumentation' do
      test_logger = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << "#{progname} : #{yield if block_given?}"
        end
      end.new
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
        config['logger'] = test_logger
        config['log_lock_try'] = true
        config['instrumenter'] = test_notifier
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      client.lock('rw.logs', read_write_mode: :read) { :ok }

      aggregate_failures 'read lock logs' do
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.try_lock.obtain__free_to_acquire]', "rw_mode => 'read'"
          ),
          a_string_including('[redis_queued_locks.lock_obtained]', "rw_mode => 'read'"),
          a_string_including('[redis_queued_locks.expire_lock]', "rw_mode => 'read'")
        )
      end
      aggregate_failures 'read lock instrumentation' do
        expect(test_notifier.notifications).to include(
          match({
            event: 'redis_queued_locks.lock_obtained',
            payload: hash_including(lock_key: 'rql:lock:rw.logs', rw_mode: :read)
          }),
          match({
            event: 'redis_queued_locks.lock_hold_and_release',
            payload: hash_including(lock_key: 'rql:lock:rw.logs', rw_mode: :read)
          })
        )
      end

      holder = Thread.new { client.lock('rw.logs', read_write_mode: :read, ttl: 10_000) }
      holder.join
      test_logger.logs.clear
      client.lock('rw.logs', read_write_mode: :write, retry_count: 1)

      aggregate_failures 'write lock waits for readers (logs)' do
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.try_lock.exit__read_lock_still_obtained]', "rw_mode => 'write'"
          )
        )
      end
      client.unlock('rw.logs')

      test_logger.logs.clear
      client.lock('rw.logs.reentrant', ttl: 5_000) do
        client.lock('rw.logs.reentrant', ttl: 5_000, conflict_strategy: :extendable_work_through) do
          :ok
        end
      end

      aggregate_failures 'extendable reentrant lock logs (the same host key as other logs)' do
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.extendable_reentrant_lock_obtained]',
            "hst_id => '#{client.current_host_id}'",
            "rw_mode => 'write'"
          )
        )
        expect(test_logger.logs.grep(/host_id =>/)).to be_empty
      end

      test_logger.logs.clear
      test_notifier.notifications.clear
      series_lock_keys = ['rql:lock:rw.logs.series.a', 'rql:lock:rw.logs.series.b']
      client.lock_series(
        'rw.logs.series.a', 'rw.logs.series.b', read_write_mode: :read, ttl: 5_000
      ) { :ok }

      aggregate_failures 'lock series logs and instrumentation (rw_mode of the series)' do
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.start_lock_series_obtaining]',
            "lock_keys => '#{series_lock_keys.inspect}' queue_ttl =>",
            "rw_mode => 'read'"
          ),
          a_string_including('[redis_queued_locks.lock_series_obtained]', "rw_mode => 'read'"),
          a_string_including('[redis_queued_locks.expire_lock_series]', "rw_mode => 'read'")
        )
        expect(test_notifier.notifications).to include(
          match({
            event: 'redis_queued_locks.lock_series_obtained',
            payload: hash_including(lock_keys: series_lock_keys, rw_mode: :read, ts: be_a(Float))
          }),
          match({
            event: 'redis_queued_locks.lock_series_hold_and_release',
            payload: hash_including(lock_keys: series_lock_keys, rw_mode: :read, ts: be_a(Float))
          })
        )
      end
      expect(client.keys).to be_empty
    end
  end
end

RSpec.describe RedisQueuedLocks do
  include_context 'redis_queued_locks redis'

  context 'with the disabled lock index (keyspace SCAN)', lock_index_enabled: false do
    include_examples 'redis_queued_locks'
  end

  context 'with the enabled lock index (lock index ZSCAN)', lock_index_enabled: true do
    include_examples 'redis_queued_locks'
  end

  # NOTE: the lock index specifics (the lock index mode is configured by each example)
  describe 'lock index' do
    let(:lock_index) { RedisQueuedLocks::Resource::LOCK_INDEX_KEY }
    # NOTE: the lock index score of the lock name relative to the current client time (in ms)
    let(:index_score_ahead) do
      lambda do |lock_name|
        score = redis.call('ZSCORE', lock_index, lock_name)
        score && (score.to_i - RedisQueuedLocks::Resource.lock_index_time)
      end
    end
    # NOTE: the default `config['lock_index_grace_period']`
    let(:grace_period) { 60_000 }
    # NOTE: the lock index score (ahead of the current time) of the given key lifetime
    let(:upper_bound) do
      -> (lifetime) { be_between(lifetime + grace_period - 1_000, lifetime + grace_period) }
    end

    specify 'lock names are indexed with the upper bound of the lock key lifetime' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      aggregate_failures 'write lock: the lock ttl (longer than the queue ttl of the request)' do
        client.lock('idx.write', ttl: 100_000, queue_ttl: 5)
        expect(index_score_ahead.call('idx.write')).to upper_bound.call(100_000)
      end

      aggregate_failures 'read lock: the read lock ttl (longer than the request queue ttl)' do
        client.lock('idx.read', read_write_mode: :read, ttl: 100_000, queue_ttl: 5)
        expect(index_score_ahead.call('idx.read')).to upper_bound.call(100_000)
      end

      aggregate_failures 'lock request: the request queue lives as long as the latest request' do
        # NOTE: each thread is a separate acquirer (thread references are kept till the end)
        holder = Thread.new { client.lock('idx.queue', ttl: 10_000) }
        holder.join
        waiter = Thread.new do
          client.lock('idx.queue', ttl: 1_000, queue_ttl: 120, timeout: 10, retry_count: nil)
        end
        sleep(0.3) # NOTE: give a timespot to queue the lock request (retries refresh it)
        expect(redis.call('PTTL', 'rql:lock_queue:idx.queue')).to be_between(119_000, 120_000)
        expect(index_score_ahead.call('idx.queue')).to upper_bound.call(120_000)
        client.unlock('idx.queue')
        expect(waiter.value).to match(
          { ok: true, result: hash_including(process: :lock_obtaining) }
        )
      end

      aggregate_failures 'grace period: per-call option and config' do
        client.lock('idx.grace', ttl: 100_000, queue_ttl: 5, lock_index_grace_period: 1_000)
        expect(index_score_ahead.call('idx.grace')).to be_between(100_000, 101_000)
        config_client = RedisQueuedLocks::Client.new(redis) do |config|
          config['lock_index_enabled'] = true
          config['lock_index_grace_period'] = 5_000
        end
        config_client.lock('idx.grace.config', ttl: 100_000, queue_ttl: 5)
        expect(index_score_ahead.call('idx.grace.config')).to be_between(104_000, 105_000)
      end

      aggregate_failures 'lock series: each lock of the series' do
        client.lock_series('idx.series.a', 'idx.series.b', ttl: 100_000, queue_ttl: 5)
        # NOTE: the series lock ttl: (ttl + retry_delay + retry_jitter) * (locks left in the series)
        expect(index_score_ahead.call('idx.series.a')).to upper_bound.call(200_030)
        expect(index_score_ahead.call('idx.series.b')).to upper_bound.call(100_015)
      end

      aggregate_failures 'the lock index is not an RQL lock key' do
        expect(client.keys).not_to include(lock_index)
        expect(client.locks).not_to include(lock_index)
      end

      client.clear_locks
    end

    specify 'lock extensions increase the lock index score' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
      end
      score = -> (lock_name) { redis.call('ZSCORE', lock_index, lock_name)&.to_i }

      aggregate_failures '#extend_lock_ttl (write lock)' do
        client.lock('idx.ext.write', ttl: 100_000, queue_ttl: 5)
        initial_score = score.call('idx.ext.write')
        expect(client.extend_lock_ttl('idx.ext.write', 30_000)).to match({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(score.call('idx.ext.write')).to eq(initial_score + 30_000)
      end

      aggregate_failures '#extend_lock_ttl (read locks)' do
        client.lock('idx.ext.read', read_write_mode: :read, ttl: 100_000, queue_ttl: 5)
        initial_score = score.call('idx.ext.read')
        expect(client.extend_lock_ttl('idx.ext.read', 30_000, read_write_mode: :read)).to match({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(score.call('idx.ext.read')).to eq(initial_score + 30_000)
        expect(
          client.extend_lock_ttl(
            'idx.ext.read', 20_000, read_write_mode: :read, all_read_locks: true
          )
        ).to match({ ok: true, result: { extended_locks_count: 1 } })
        expect(score.call('idx.ext.read')).to eq(initial_score + 50_000)
      end

      aggregate_failures 'reentrant locks (:extendable_work_through)' do
        %i[write read].each do |read_write_mode|
          lock_name = "idx.ext.reentrant.#{read_write_mode}"
          client.lock(lock_name, read_write_mode:, ttl: 100_000, queue_ttl: 5) do
            initial_score = score.call(lock_name)
            client.lock(
              lock_name,
              read_write_mode:, ttl: 40_000, conflict_strategy: :extendable_work_through
            ) do
              expect(score.call(lock_name)).to eq(initial_score + 40_000)
            end
          end
        end
      end

      aggregate_failures 'locks without the lock index entry are not indexed by extensions' do
        # NOTE: a lock written directly (like a lock of an older RQL version)
        redis.call(
          'HSET', 'rql:lock:idx.ext.legacy',
          'acq_id', 'rql:acq:1/2/3/4/legacy', 'hst_id', 'rql:hst:1/2/4/legacy'
        )
        redis.call('PEXPIRE', 'rql:lock:idx.ext.legacy', 100_000)
        expect(client.extend_lock_ttl('idx.ext.legacy', 30_000)).to match({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(score.call('idx.ext.legacy')).to eq(nil)
        expect(client.extend_lock_ttl('idx.ext.no_lock', 30_000)).to match({
          ok: false, result: :async_expire_or_no_lock
        })
        expect(score.call('idx.ext.no_lock')).to eq(nil)
      end

      client.clear_locks
    end

    specify 'expired lock names are dropped from the lock index' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
      end
      expired_score = RedisQueuedLocks::Resource.lock_index_time - 1_000
      redis.call('ZADD', lock_index, expired_score, 'idx.expired.0', expired_score, 'idx.expired.1')

      aggregate_failures 'each lock request queueing drops the expired lock names' do
        client.lock('idx.alive', ttl: 10_000)
        expect(redis.call('ZRANGE', lock_index, '0', '-1')).to eq(['idx.alive'])
      end

      aggregate_failures 'zombie flushing drops the expired lock names' do
        redis.call('ZADD', lock_index, expired_score, 'idx.expired.2')
        # NOTE: zombie flushing works only when zombie hosts exist
        redis.call(
          'HSET', RedisQueuedLocks::Resource::SWARM_KEY, 'rql:hst:1/2/3/zombie', Time.now.to_f - 60
        )
        expect(client.flush_zombies).to match(
          hash_including(ok: true, deleted_zombie_hosts: include('rql:hst:1/2/3/zombie'))
        )
        expect(redis.call('ZRANGE', lock_index, '0', '-1')).to eq(['idx.alive'])
      end

      aggregate_failures 'the lock name lives in the index till the end of the grace period' do
        # NOTE: the lifetime of the lock keys: 1 second (the queue ttl of the lock request)
        client.lock('idx.short', ttl: 100, queue_ttl: 1, lock_index_grace_period: 1_000)
        sleep(1.1) # NOTE: the lock keys are expired, the grace period is not over yet
        # NOTE: lock requests of other locks (each queueing drops the expired lock names)
        client.lock('idx.prune.0', ttl: 10_000)
        expect(redis.call('ZRANGE', lock_index, '0', '-1')).to include('idx.short')
        sleep(1.2) # NOTE: the grace period is over
        client.lock('idx.prune.1', ttl: 10_000)
        expect(redis.call('ZRANGE', lock_index, '0', '-1')).not_to include('idx.short')
      end

      client.clear_locks
    end

    specify 'zombie locks are found via the lock index (no keyspace SCAN)' do
      # NOTE: commands are observed via a separate pool (the same db) with a recording middleware
      commands = []
      recorder = Module.new do
        define_method(:call) do |command, redis_config, &block|
          commands << command.first
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |pipeline_commands, redis_config, &block|
          commands.concat(pipeline_commands.map(&:first))
          super(pipeline_commands, redis_config, &block)
        end
      end
      recorded_redis = RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      client = RedisQueuedLocks::Client.new(recorded_redis) do |config|
        config['lock_index_enabled'] = true
        config['swarm.auto_swarm'] = false
        # NOTE: we will manually flush zombies
        config['swarm.probe_hosts.enabled_for_swarm'] = false
        config['swarm.flush_zombies.enabled_for_swarm'] = false
        config['swarm.flush_zombies.zombie_ttl'] = 1_000
      end
      zombie_host = client.current_host_id
      zombie_acquirer = client.current_acquirer_id
      # NOTE: keys of other applications (the swarm never visits them)
      redis.pipelined do |pipeline|
        100.times { |index| pipeline.call('SET', "foreign:#{index}", 'value') }
      end

      client.lock('idx.zombie.write', ttl: 500_000)
      client.lock('idx.zombie.read', read_write_mode: :read, ttl: 500_000)
      # NOTE: a lock written directly (like a lock of an older RQL version): not indexed
      redis.call(
        'HSET', 'rql:lock:idx.zombie.legacy', 'acq_id', zombie_acquirer, 'hst_id', zombie_host
      )
      redis.call('PEXPIRE', 'rql:lock:idx.zombie.legacy', 500_000)
      # NOTE: the current host is a zombie host (the last probe is older than zombie_ttl)
      redis.call('HSET', RedisQueuedLocks::Resource::SWARM_KEY, zombie_host, Time.now.to_f - 60)

      aggregate_failures 'zombie info and zombie flushing iterate over the lock index' do
        commands.clear
        expect(client.zombie_locks).to contain_exactly(
          'rql:lock:idx.zombie.write', 'rql:lock_readers:idx.zombie.read'
        )
        expect(client.flush_zombies).to match({
          ok: true,
          deleted_zombie_hosts: contain_exactly(zombie_host),
          deleted_zombie_acquirers: contain_exactly(zombie_acquirer),
          deleted_zombie_locks: contain_exactly(
            'rql:lock:idx.zombie.write', 'rql:lock_readers:idx.zombie.read'
          )
        })
        expect(commands).to include('ZSCAN')
        expect(commands).not_to include('SCAN')
        expect(client.locked?('idx.zombie.write')).to eq(false)
        expect(client.locked?('idx.zombie.read')).to eq(false)
        # NOTE: the lock without the lock index entry is not found
        expect(client.locked?('idx.zombie.legacy')).to eq(true)
        expect(redis.call('EXISTS', 'foreign:0', 'foreign:99')).to eq(2)
      end

      aggregate_failures 'locks without the lock index entry are found after #reindex_locks' do
        expect(client.reindex_locks).to match({ ok: true, result: { idx_key_cnt: 1 } })
        redis.call('HSET', RedisQueuedLocks::Resource::SWARM_KEY, zombie_host, Time.now.to_f - 60)
        expect(client.flush_zombies).to match(
          hash_including(deleted_zombie_locks: contain_exactly('rql:lock:idx.zombie.legacy'))
        )
        expect(client.locked?('idx.zombie.legacy')).to eq(false)
      end

      recorded_redis.close
    end

    specify '#reindex_locks: keys without the lock index entry (older RQL versions)' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
      end
      legacy_acquirer = 'rql:acq:1/2/3/4/legacy'
      read_lock_key = "rql:lock_reader:idx.legacy.read:#{legacy_acquirer}"
      now = Time.now.to_f
      # NOTE: RQL keys written directly (without the lock index entries)
      redis.call(
        'HSET', 'rql:lock:idx.legacy.write',
        'acq_id', legacy_acquirer, 'hst_id', 'rql:hst:1/2/4/legacy'
      )
      redis.call('PEXPIRE', 'rql:lock:idx.legacy.write', 100_000)
      redis.call(
        'ZADD', 'rql:lock_readers:idx.legacy.read', (now * 1_000) + 200_000, legacy_acquirer
      )
      redis.call('PEXPIRE', 'rql:lock_readers:idx.legacy.read', 200_000)
      redis.call('HSET', read_lock_key, 'ts', now, 'ini_ttl', 200_000)
      redis.call('PEXPIRE', read_lock_key, 200_000)
      redis.call('ZADD', 'rql:lock_queue:idx.legacy.queue', now, legacy_acquirer)
      redis.call('ZADD', 'rql:lock_read_queue:idx.legacy.queue', now, legacy_acquirer)
      # NOTE: an indexed lock with a bigger index score (the score is never decreased)
      client.lock('idx.indexed', ttl: 300_000, queue_ttl: 5)
      far_score = RedisQueuedLocks::Resource.lock_index_time + 1_000_000
      redis.call('ZADD', lock_index, 'XX', far_score, 'idx.indexed')
      # NOTE: a key out of the lock key families and a key of another application
      redis.call('SET', 'rql:lockX', 'value')
      redis.call('SET', 'foreign', 'value')

      # NOTE: 5 keys (write lock, readers registry, 2 lock queues, indexed lock): a remainder batch
      expect(client.reindex_locks(scan_size: 2, queue_ttl: 30)).to match({
        ok: true, result: { idx_key_cnt: 5 }
      })

      aggregate_failures 'lock names with the upper bound of the key lifetime' do
        expect(index_score_ahead.call('idx.legacy.write')).to upper_bound.call(100_000)
        expect(index_score_ahead.call('idx.legacy.read')).to upper_bound.call(200_000)
        expect(index_score_ahead.call('idx.legacy.queue')).to upper_bound.call(30_000)
        expect(redis.call('ZSCORE', lock_index, 'idx.indexed').to_i).to eq(far_score)
        expect(redis.call('ZRANGE', lock_index, '0', '-1')).to contain_exactly(
          'idx.legacy.write', 'idx.legacy.read', 'idx.legacy.queue', 'idx.indexed'
        )
      end

      aggregate_failures 'lock queues without TTL get the queue ttl' do
        expect(redis.call('PTTL', 'rql:lock_queue:idx.legacy.queue')).to be_between(29_000, 30_000)
        expect(redis.call('PTTL', 'rql:lock_read_queue:idx.legacy.queue')).to be_between(
          29_000, 30_000
        )
      end

      aggregate_failures 'idempotent' do
        expect(client.reindex_locks).to match({ ok: true, result: { idx_key_cnt: 5 } })
        expect(redis.call('ZCARD', lock_index)).to eq(4)
      end

      aggregate_failures 'keys out of the lock key families are not touched' do
        expect(redis.call('PTTL', 'rql:lockX')).to eq(-1)
        expect(redis.call('PTTL', 'foreign')).to eq(-1)
        expect(redis.call('PTTL', read_lock_key)).to be_between(199_000, 200_000)
      end

      client.clear_locks
      redis.call('DEL', 'rql:lockX', 'foreign')
    end

    specify 'the lock obtaining transaction indexes the lock (a dropped entry is restored)' do
      # NOTE: the lock index entry of the lock name is dropped right before the obtaining
      #   transaction (like a concurrent `#unlock`/`#clear_locks` between the lock request queueing
      #   and the obtaining): the obtained lock should be indexed by its own transaction;
      side_redis = RedisClient.config(db: 0).new_client
      race_lock_names = %w[idx.race.write idx.race.read]
      dropper = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          # NOTE: the lock of the obtaining transaction (write lock data or read lock data key)
          hset_key = (commands.first == ['MULTI']) ? commands.assoc('HSET')&.at(1) : nil
          dropped_lock_name = race_lock_names.find do |lock_name|
            hset_key == "rql:lock:#{lock_name}" ||
              hset_key&.start_with?("rql:lock_reader:#{lock_name}:")
          end
          if dropped_lock_name
            side_redis.call('ZREM', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, dropped_lock_name)
          end
          super(commands, redis_config, &block)
        end
      end
      dropping_redis = RedisClient.config(db: 0, middlewares: [dropper]).new_pool(timeout: 5)
      client = RedisQueuedLocks::Client.new(dropping_redis) do |config|
        config['lock_index_enabled'] = true
      end

      client.lock('idx.race.write', ttl: 100_000, queue_ttl: 5)
      client.lock('idx.race.read', read_write_mode: :read, ttl: 100_000, queue_ttl: 5)

      expect(index_score_ahead.call('idx.race.write')).to upper_bound.call(100_000)
      expect(index_score_ahead.call('idx.race.read')).to upper_bound.call(100_000)

      client.clear_locks
      dropping_redis.close
      side_redis.close
    end

    specify '#unlock and #clear_locks drop the lock names from the lock index' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
      lock_names = -> { redis.call('ZRANGE', lock_index, '0', '-1') }

      aggregate_failures '#unlock' do
        client.lock('idx.unlock.write', ttl: 100_000)
        client.lock('idx.unlock.read', read_write_mode: :read, ttl: 100_000)
        client.unlock('idx.unlock.write')
        client.unlock('idx.unlock.read')
        expect(lock_names.call).to eq([])
      end

      aggregate_failures '#unlock: a waiting lock request indexes the lock name again' do
        # NOTE: each thread is a separate acquirer (thread references are kept till the end)
        holder = Thread.new { client.lock('idx.unlock.wait', ttl: 100_000) }
        holder.join
        waiter = Thread.new do
          client.lock('idx.unlock.wait', ttl: 1_000, timeout: 10, retry_count: nil)
        end
        sleep(0.3) # NOTE: give a timespot to queue the lock request (retries refresh it)
        client.unlock('idx.unlock.wait')
        expect(waiter.value).to match(
          { ok: true, result: hash_including(process: :lock_obtaining) }
        )
        expect(lock_names.call).to eq(['idx.unlock.wait'])
        client.unlock('idx.unlock.wait')
      end

      aggregate_failures '#clear_locks (with expired lock names)' do
        client.lock('idx.clear.0', ttl: 100_000)
        client.lock('idx.clear.1', read_write_mode: :read, ttl: 100_000)
        redis.call(
          'ZADD', lock_index, RedisQueuedLocks::Resource.lock_index_time - 1_000, 'idx.expired'
        )
        expect(client.clear_locks(batch_size: 1)).to match({
          ok: true,
          # NOTE: write lock, readers registry, read lock data
          result: match({ rel_key_cnt: 3, rel_time: be_a(Numeric) })
        })
        expect(lock_names.call).to eq([])
        expect(client.keys).to be_empty
      end
    end

    specify 'lock-iterating operations use the lock index (no keyspace SCAN)' do
      # NOTE: commands are observed via a separate pool (the same db) with a recording middleware
      commands = []
      recorder = Module.new do
        define_method(:call) do |command, redis_config, &block|
          commands << command.first
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |pipeline_commands, redis_config, &block|
          commands.concat(pipeline_commands.map(&:first))
          super(pipeline_commands, redis_config, &block)
        end
      end
      recorded_redis = RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      client = RedisQueuedLocks::Client.new(recorded_redis) do |config|
        config['lock_index_enabled'] = true
      end
      acquirer_id = client.current_acquirer_id
      host_id = client.current_host_id
      # NOTE: keys of other applications (lock-iterating operations never visit them)
      redis.pipelined do |pipeline|
        100.times { |index| pipeline.call('SET', "foreign:#{index}", 'value') }
      end

      client.lock('idx.ops.write', ttl: 100_000)
      client.lock('idx.ops.read', read_write_mode: :read, ttl: 100_000)
      # NOTE: a lock request of another acquirer (queued by RQL: indexed)
      requester = Thread.new { client.lock('idx.ops.write', ttl: 1_000, retry_count: 1) }
      requester.join
      redis.call('ZADD', 'rql:lock_queue:idx.ops.queue', Time.now.to_f, 'rql:acq:1/2/3/4/live')
      # NOTE: a lock written directly (like a lock of an older RQL version): not indexed
      redis.call(
        'HSET', 'rql:lock:idx.ops.legacy', 'acq_id', acquirer_id, 'hst_id', host_id
      )
      redis.call('PEXPIRE', 'rql:lock:idx.ops.legacy', 100_000)
      read_lock_key = "rql:lock_reader:idx.ops.read:#{acquirer_id}"

      aggregate_failures 'info operations' do
        commands.clear
        expect(client.locks).to contain_exactly('rql:lock:idx.ops.write', 'rql:lock:idx.ops.read')
        expect(client.locks_info.map { |lock| lock[:lock] }).to contain_exactly(
          'rql:lock:idx.ops.write', 'rql:lock:idx.ops.read'
        )
        # NOTE: the request of the requester is dequeued after its retries (no lock queues)
        expect(client.queues).to eq(Set.new)
        expect(client.queues_info).to eq(Set.new)
        expect(client.keys).to contain_exactly(
          'rql:lock:idx.ops.write', 'rql:lock_readers:idx.ops.read', read_lock_key
        )
        expect(commands).to include('ZSCAN')
        expect(commands).not_to include('SCAN')
      end

      aggregate_failures 'keys without the lock index entry are found after #reindex_locks' do
        client.reindex_locks
        expect(client.locks).to contain_exactly(
          'rql:lock:idx.ops.write', 'rql:lock:idx.ops.read', 'rql:lock:idx.ops.legacy'
        )
        expect(client.queues).to contain_exactly('rql:lock_queue:idx.ops.queue')
      end

      aggregate_failures 'cleanup operations' do
        commands.clear
        expect(client.clear_dead_requests(dead_ttl: 1)).to match({
          ok: true,
          result: match({ processed_queues: contain_exactly('rql:lock_queue:idx.ops.queue') })
        })
        expect(client.clear_current_locks).to match({
          ok: true,
          # NOTE: write lock, legacy write lock, read lock (the request was dropped as dead)
          result: match({ rel_key_cnt: 3, tch_queue_cnt: 0, rel_time: be_a(Numeric) })
        })
        expect(client.clear_locks).to match({ ok: true, result: hash_including(rel_key_cnt: 0) })
        expect(commands).to include('ZSCAN')
        expect(commands).not_to include('SCAN')
        expect(client.keys).to be_empty
        expect(redis.call('EXISTS', 'foreign:0', 'foreign:99')).to eq(2)
      end

      recorded_redis.close
    end

    specify 'the disabled lock index (default): no lock index commands, keyspace lookups' do
      # NOTE: commands are observed via a separate pool (the same db) with a recording middleware
      commands = []
      recorder = Module.new do
        define_method(:call) do |command, redis_config, &block|
          commands << command.map(&:to_s)
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |pipeline_commands, redis_config, &block|
          commands.concat(pipeline_commands.map { |command| command.map(&:to_s) })
          super(pipeline_commands, redis_config, &block)
        end
      end
      recorded_redis = RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      # NOTE: the library default (the example has no `lock_index_enabled` metadata)
      expect(RedisQueuedLocks::Config.new['lock_index_enabled']).to eq(false)
      client = RedisQueuedLocks::Client.new(recorded_redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
        config['swarm.flush_zombies.zombie_ttl'] = 1_000
      end
      host_id = client.current_host_id
      acquirer_id = client.current_acquirer_id

      aggregate_failures 'lock acquirement, extension and release' do
        client.lock('noidx.write', ttl: 100_000)
        client.lock('noidx.read', read_write_mode: :read, ttl: 100_000)
        # NOTE: reentrant lock extensions (write: four extension commands without the lock index)
        %i[write read].each do |read_write_mode|
          expect(
            client.lock(
              "noidx.#{read_write_mode}",
              read_write_mode:, ttl: 1_000, conflict_strategy: :extendable_work_through
            )
          ).to match(
            { ok: true, result: hash_including(process: :extendable_conflict_work_through) }
          )
        end
        expect(client.extend_lock_ttl('noidx.write', 10_000)).to match({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(
          client.extend_lock_ttl('noidx.read', 10_000, read_write_mode: :read)
        ).to match({ ok: true, result: { extended_locks_count: 1 } })
        # NOTE: a waiting lock request (each thread is a separate acquirer, references are kept)
        holder = Thread.new { client.lock('noidx.queue', ttl: 10_000) }
        holder.join
        waiter = Thread.new do
          client.lock('noidx.queue', ttl: 1_000, timeout: 10, retry_count: nil)
        end
        sleep(0.3) # NOTE: give a timespot to queue the lock request
        # NOTE: lock request queues have no TTL
        expect(redis.call('PTTL', 'rql:lock_queue:noidx.queue')).to eq(-1)
        client.unlock('noidx.queue')
        expect(waiter.value).to match(
          { ok: true, result: hash_including(process: :lock_obtaining) }
        )
      end

      aggregate_failures 'lock-iterating operations scan the keyspace' do
        # NOTE: a lock written directly (like a lock of an older RQL version): found without
        #   `#reindex_locks`
        redis.call('HSET', 'rql:lock:noidx.legacy', 'acq_id', acquirer_id, 'hst_id', host_id)
        redis.call('PEXPIRE', 'rql:lock:noidx.legacy', 100_000)
        commands.clear
        expect(client.locks).to contain_exactly(
          'rql:lock:noidx.write', 'rql:lock:noidx.read', 'rql:lock:noidx.queue',
          'rql:lock:noidx.legacy'
        )
        expect(client.queues).to eq(Set.new)
        expect(client.keys).to include('rql:lock:noidx.legacy', 'rql:lock_readers:noidx.read')
        # NOTE: the current host is a zombie host (the last probe is older than zombie_ttl)
        redis.call('HSET', RedisQueuedLocks::Resource::SWARM_KEY, host_id, Time.now.to_f - 60)
        expect(client.zombie_locks).to contain_exactly(
          'rql:lock:noidx.write', 'rql:lock_readers:noidx.read', 'rql:lock:noidx.legacy'
        )
        expect(client.flush_zombies).to match(
          hash_including(
            ok: true,
            deleted_zombie_locks: contain_exactly(
              'rql:lock:noidx.write', 'rql:lock_readers:noidx.read', 'rql:lock:noidx.legacy'
            )
          )
        )
        expect(client.clear_dead_requests).to match(
          { ok: true, result: { processed_queues: Set.new } }
        )
        expect(client.clear_locks).to match({ ok: true, result: hash_including(rel_key_cnt: 1) })
        expect(commands.map(&:first)).to include('SCAN')
        expect(commands.map(&:first)).not_to include('ZSCAN')
      end

      aggregate_failures 'the lock index is never touched' do
        expect(commands.flatten).not_to include(RedisQueuedLocks::Resource::LOCK_INDEX_KEY)
        expect(redis.call('EXISTS', RedisQueuedLocks::Resource::LOCK_INDEX_KEY)).to eq(0)
        expect(client.keys).to be_empty
      end

      recorded_redis.close
    end

    specify 'enabling the lock index: locks of the disabled lock index after #reindex_locks' do
      disabled_client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = false
      end
      enabled_client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
      end
      disabled_client.lock('idx.migration', ttl: 100_000)

      aggregate_failures 'locks of the disabled lock index are not indexed' do
        expect(disabled_client.locks).to contain_exactly('rql:lock:idx.migration')
        expect(enabled_client.locks).to be_empty
      end

      aggregate_failures 'locks of the disabled lock index are indexed by #reindex_locks' do
        expect(enabled_client.reindex_locks).to match({ ok: true, result: { idx_key_cnt: 1 } })
        expect(index_score_ahead.call('idx.migration')).to upper_bound.call(100_000)
        expect(enabled_client.locks).to contain_exactly('rql:lock:idx.migration')
      end

      enabled_client.clear_locks
      expect(disabled_client.keys).to be_empty
    end

    specify 'lock index config validation' do
      expect do
        RedisQueuedLocks::Client.new(redis) { |config| config['lock_index_enabled'] = 'true' }
      end.to raise_error(RedisQueuedLocks::ConfigValidationError)
      expect do
        RedisQueuedLocks::Client.new(redis) { |config| config['lock_index_grace_period'] = -1 }
      end.to raise_error(RedisQueuedLocks::ConfigValidationError)
    end
  end
end
