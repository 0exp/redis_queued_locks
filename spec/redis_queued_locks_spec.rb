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
  describe 'Lock Series' do
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
        # X and Y should not be obtained at all! B - obtained by the outer logic!
        RedisQueuedLocks::LockAcquirementRetryLimitError,
        'Failed to acquire the lock series ["rql:lock:x", "rql:lock:y", "rql:lock:b"] ' \
        '(blocked by "rql:lock:b") for the given retry_count limit (3 times).'
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
        # X and Y should not be obtained at all! C - obtained by the outer logic!
        RedisQueuedLocks::LockAcquirementRetryLimitError,
        'Failed to acquire the lock series ["rql:lock:x", "rql:lock:y", "rql:lock:c"] ' \
        '(blocked by "rql:lock:c") for the given retry_count limit (3 times).'
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
      # X and Y should not be obtained at all! D - obtained by the outer logic!
      expect(detailed_result).to match({
        ok: false,
        result:
        {
          error: :failed_to_acquire_lock_series,
          detailed_errors: { 'd' => { ok: false, result: :retry_limit_reached } },
          lock_series: %w[x y d],
          acquired_locks: [],
          missing_locks: %w[x y d],
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

      aggregate_failures 'the failed series obtains nothing without exceptions too' do
        holder = Thread.new { client.lock('ls.busy', ttl: 10_000) }
        holder.join
        %i[write read].each do |mode|
          result = client.lock_series(
            'ls.first', 'ls.busy', rw_mode: mode, fail_fast: true, ttl: 10_000
          ) { :never }
          expect(result).to match({
            ok: false,
            result: hash_including(
              acquired_locks: [], missing_locks: %w[ls.first ls.busy], failed_on_lock: 'ls.busy'
            )
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
            'ls.observed.a', 'ls.observed.b', rw_mode: mode, ttl: 10_000
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

    specify '#lock_series: lock names validation' do
      client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures 'an empty series' do
        expect { client.lock_series { :never } }.to raise_error(
          RedisQueuedLocks::ArgumentError,
          '`:lock_names` argument should contain at least one lock name, got [].'
        )
        expect { client.lock_series! { :never } }.to raise_error(
          RedisQueuedLocks::ArgumentError, /lock_names/
        )
        expect(client.keys).to be_empty
      end

      aggregate_failures 'a duplicated lock name is the same lock (no waiting for the own lock)' do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.lock_series(
          'dup.a', 'dup.b', 'dup.a', ttl: 2_000, retry_count: nil, detailed_result: true
        ) { :ok }
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 1.0
        expect(result).to include(
          yield_result: :ok,
          lock_series: %w[dup.a dup.b],
          rql_lock_series: ['rql:lock:dup.a', 'rql:lock:dup.b']
        )
        expect(client.keys).to be_empty
      end

      aggregate_failures 'a series of one lock' do
        expect(client.lock_series('dup.one', ttl: 5_000) { client.locked?('dup.one') }).to eq(true)
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: all locks are obtained at once with the same ttl' do
      client = RedisQueuedLocks::Client.new(redis)
      lock_names = %w[atom.a atom.b atom.c]
      lock_keys = lock_names.map { |lock_name| "rql:lock:#{lock_name}" }

      aggregate_failures 'write locks' do
        result = client.lock_series(*lock_names, ttl: 10_000, meta: { 'kek' => 'pek' })
        expect(result).to match({
          ok: true,
          result: {
            lock_series: lock_names,
            rql_lock_series: lock_keys,
            acq_id: client.current_acquirer_id,
            hst_id: client.current_host_id,
            ts: be_a(Float),
            ttl: 10_000
          }
        })
        lock_infos = lock_names.map { |lock_name| client.lock_info(lock_name) }
        expect(lock_infos).to all(
          include(
            'acq_id' => client.current_acquirer_id,
            'ts' => result[:result][:ts],
            'ini_ttl' => 10_000,
            'rem_ttl' => be_between(5_000, 10_000),
            'kek' => 'pek'
          )
        )
        lock_names.each { |lock_name| client.unlock(lock_name) }
      end

      aggregate_failures 'read locks' do
        result = client.lock_series(*lock_names, ttl: 10_000, rw_mode: :read)
        expect(result).to match({ ok: true, result: hash_including(ttl: 10_000) })
        lock_infos = lock_names.map { |lock_name| client.lock_info(lock_name) }
        expect(lock_infos).to all(
          include(
            'rw_mode' => 'read',
            'rem_ttl' => be_between(5_000, 10_000),
            'readers' => contain_exactly(
              include('acq_id' => client.current_acquirer_id, 'ini_ttl' => 10_000)
            )
          )
        )
        lock_names.each { |lock_name| client.unlock(lock_name) }
      end
      expect(client.keys).to be_empty
    end

    specify '#lock_series: the waiting series holds nothing and all locks are held in the block' do
      # NOTE: each thread is a separate acquirer (thread references are kept till the end)
      holder_client = RedisQueuedLocks::Client.new(redis)
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      %i[write read].each do |mode|
        holder = Thread.new { holder_client.lock('hold.b', ttl: 500) }
        holder.join
        locks_in_block = nil
        series = Thread.new do
          # NOTE: the waiting time is longer than the ttl of the series: the old sequential logic
          #   lost the first lock (it was obtained first and expired before the last one)
          client.lock_series(
            'hold.a', 'hold.b', ttl: 200, timeout: 10, rw_mode: mode
          ) do
            locks_in_block = [client.locked?('hold.a'), client.locked?('hold.b')]
          end
        end

        sleep(0.2) # NOTE: give a timespot to queue the lock requests of the series
        expect(client.locked?('hold.a')).to eq(false)
        series.join
        expect(locks_in_block).to eq([true, true])
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: any order of the lock names is deadlock-free' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      # NOTE: the old sequential logic held the first lock and waited for the second one in both
      #   threads: every pair of the opposite series failed with the timeout
      %i[write read].each do |mode|
        series = Array.new(5) do |index|
          lock_names = ["order.a.#{index}", "order.b.#{index}"]
          [lock_names, lock_names.reverse].map do |series_lock_names|
            Thread.new do
              client.lock_series(
                *series_lock_names, ttl: 10_000, timeout: 10, rw_mode: mode
              ) do
                sleep(0.05) # NOTE: both series of the pair are in progress
                :done
              end
            end
          end
        end.flatten

        expect(series.map(&:value)).to all(eq(:done))
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: mutual exclusion of the overlapping lock series' do
      resources = %w[mutex.a mutex.b mutex.c mutex.d]
      state = resources.to_h { |resource| [resource, { writers: 0, readers: 0 }] }
      state_lock = Mutex.new
      violations = []
      completed = []

      workers = Array.new(8) do |index|
        Thread.new do
          random = Random.new(index)
          client = RedisQueuedLocks::Client.new(redis)
          10.times do
            lock_names = resources.sample(random.rand(1..3), random:)
            rw_mode = random.rand(3).zero? ? :read : :write
            result = client.lock_series(
              *lock_names,
              rw_mode:,
              ttl: 30_000,
              timeout: 30,
              retry_count: nil,
              retry_delay: 5,
              retry_jitter: 5
            ) do
              state_lock.synchronize do
                lock_names.each do |lock_name|
                  counters = state[lock_name]
                  if rw_mode == :read
                    violations << [lock_name, counters.dup] if counters[:writers] > 0
                    counters[:readers] += 1
                  else
                    violations << [lock_name, counters.dup] if counters.values.sum > 0
                    counters[:writers] += 1
                  end
                end
              end
              sleep(0.002)
              state_lock.synchronize do
                lock_names.each do |lock_name|
                  state[lock_name][(rw_mode == :read) ? :readers : :writers] -= 1
                end
              end
              :done
            end
            state_lock.synchronize { completed << result }
          end
        end
      end
      workers.each(&:join)

      expect(violations).to eq([])
      expect(completed).to eq(Array.new(80, :done))
      expect(RedisQueuedLocks::Client.new(redis).keys).to be_empty
    end

    specify '#lock_series: the limits are the limits of the whole series' do
      holder_client = RedisQueuedLocks::Client.new(redis)
      holder = Thread.new do
        holder_client.lock('limit.a', ttl: 60_000)
        holder_client.lock('limit.b', ttl: 60_000)
      end
      holder.join
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
        config['retry_delay'] = 10
        config['retry_jitter'] = 1
        config['logger'] = test_logger
      end

      aggregate_failures '`:timeout`: one time period for all locks' do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.lock_series('limit.a', 'limit.b', timeout: 1, retry_count: nil)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 1.9
        expect(result).to match({
          ok: false,
          result: {
            error: :failed_to_acquire_lock_series,
            detailed_errors: { 'limit.a' => { ok: false, result: :timeout_reached } },
            lock_series: %w[limit.a limit.b],
            acquired_locks: [],
            missing_locks: %w[limit.a limit.b],
            failed_on_lock: 'limit.a'
          }
        })
      end

      aggregate_failures '`:retry_count`: all attempts of the series' do
        test_logger.logs.clear
        client.lock_series('limit.a', 'limit.b', retry_count: 3)
        expect(
          test_logger.logs.grep(/\[redis_queued_locks\.start_try_to_lock_series_cycle\]/).size
        ).to eq(3)
      end

      aggregate_failures 'raised errors' do
        expect do
          client.lock_series!('limit.a', 'limit.b', timeout: 1, retry_count: nil)
        end.to raise_error(
          RedisQueuedLocks::LockAcquirementTimeoutError,
          'Failed to acquire the lock series ["rql:lock:limit.a", "rql:lock:limit.b"] ' \
          '(blocked by "rql:lock:limit.a") for the given <1 seconds> timeout.'
        )
        expect do
          client.lock_series!(
            'limit.c', 'limit.a', timeout: 1, retry_count: nil, detailed_acq_timeout_error: true
          )
        end.to raise_error(
          RedisQueuedLocks::LockAcquirementTimeoutError,
          /\(blocked by "rql:lock:limit.a"\) for the given <1 seconds> timeout. Details: <Lock Data> => {.*"acq_id" => "rql:acq:.*<Readers Data> => \[\]; <Queue Data> => \[\]; <Read Queue Data> => \[\];/ # rubocop:disable Layout/LineLength
        )
      end

      holder_client.unlock('limit.a')
      holder_client.unlock('limit.b')
      expect(client.keys).to be_empty
    end

    specify '#lock_series: `timed` limits the block by the ttl of the series' do
      client = RedisQueuedLocks::Client.new(redis)

      %i[write read].each do |mode|
        expect do
          client.lock_series(
            'timed.a', 'timed.b', ttl: 100, timed: true, rw_mode: mode
          ) { sleep(2) }
        end.to raise_error(
          RedisQueuedLocks::TimedBlockExceedsLockTtlError,
          /exceeded the lock TTL \(lock: "rql:lock:timed.a, rql:lock:timed.b", ttl: 100/
        )
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: the failed series leaves no lock requests in the queues' do
      holder_client = RedisQueuedLocks::Client.new(redis)
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 1
      end
      other_request = 'rql:acq:1/2/3/4/other'
      queues = lambda do
        %w[clean.a clean.b clean.c].flat_map do |lock_name|
          [
            redis.call('ZRANGE', "rql:lock_queue:#{lock_name}", '0', '-1'),
            redis.call('ZRANGE', "rql:lock_read_queue:#{lock_name}", '0', '-1')
          ]
        end.flatten
      end

      %i[write read].each do |rw_mode|
        aggregate_failures "retry limit, timeout (#{rw_mode})" do
          holder = Thread.new { holder_client.lock('clean.b', ttl: 60_000) }
          holder.join

          client.lock_series('clean.a', 'clean.b', 'clean.c', rw_mode:, retry_count: 2)
          expect(queues.call).to eq([])

          client.lock_series(
            'clean.a', 'clean.b', 'clean.c', rw_mode:, retry_count: nil, timeout: 1
          )
          expect(queues.call).to eq([])

          holder_client.unlock('clean.b')
        end

        aggregate_failures "fail fast after the try (#{rw_mode})" do
          # NOTE: free locks, but an earlier lock request of the opposite mode should go first
          opposite_queue =
            (rw_mode == :read) ? 'rql:lock_queue:clean.c' : 'rql:lock_read_queue:clean.c'
          redis.call('ZADD', opposite_queue, Time.now.to_f - 1, other_request)

          expect(
            client.lock_series('clean.a', 'clean.c', rw_mode:, fail_fast: true) { :never }
          ).to match({
            ok: false,
            result: hash_including(
              detailed_errors: { 'clean.c' => { ok: false, result: :fail_fast_after_try } },
              failed_on_lock: 'clean.c'
            )
          })
          expect(queues.call).to eq([other_request])
          redis.call('ZREM', opposite_queue, other_request)
        end
      end
      client.reindex_locks if client.config['lock_index_enabled']
      expect(client.keys).to be_empty
    end

    specify '#lock_series: an interrupted acquirement leaves no locks and no lock requests' do
      holder_client = RedisQueuedLocks::Client.new(redis)
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 1
      end
      interrupted_error = Class.new(StandardError)

      %i[write read].each do |rw_mode|
        aggregate_failures "the waiting series (#{rw_mode})" do
          holder = Thread.new { holder_client.lock('intr.b', ttl: 60_000) }
          holder.join

          # NOTE: `Timeout.timeout` of the outer logic (with and without the exception class)
          [interrupted_error, nil].each do |error_class|
            expect do
              Timeout.timeout(0.2, error_class) do
                client.lock_series('intr.a', 'intr.b', rw_mode:, timeout: 10)
              end
            end.to raise_error(error_class || Timeout::Error)
            expect(client.locked?('intr.a')).to eq(false)
            expect(client.queued?('intr.a')).to eq(false)
            expect(client.queued?('intr.b')).to eq(false)
          end

          holder_client.unlock('intr.b')
        end

        aggregate_failures "an applied transaction without its reply (#{rw_mode})" do
          # NOTE: the connection is lost after the obtaining transaction is applied by Redis
          is_failure_required = true
          connection_failure = Module.new do
            define_method(:call_pipelined) do |commands, redis_config, &block|
              replies = super(commands, redis_config, &block)
              if is_failure_required && commands.first == ['MULTI'] && commands.assoc('HSET')
                is_failure_required = false
                raise(interrupted_error)
              end
              replies
            end
          end
          failing_redis =
            RedisClient.config(db: 0, middlewares: [connection_failure]).new_pool(timeout: 5)
          failing_client = RedisQueuedLocks::Client.new(failing_redis)

          expect do
            failing_client.lock_series('intr.a', 'intr.b', rw_mode:, ttl: 60_000)
          end.to raise_error(interrupted_error)
          expect(is_failure_required).to eq(false)
          expect(client.locked?('intr.a')).to eq(false)
          expect(client.locked?('intr.b')).to eq(false)
          expect(client.keys).to be_empty

          failing_redis.close
        end
      end
    end

    specify '#lock_series: an interrupted release is completed by the second release' do
      interrupted_error = Class.new(StandardError)
      interrupted_command = nil
      interrupter = Module.new do
        define_method(:call) do |command, redis_config, &block|
          if interrupted_command == command.first
            interrupted_command = nil
            raise(interrupted_error)
          end
          super(command, redis_config, &block)
        end
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if interrupted_command && interrupted_command == commands.first.first
            interrupted_command = nil
            raise(interrupted_error)
          end
          super(commands, redis_config, &block)
        end
      end
      interrupted_redis = RedisClient.config(db: 0, middlewares: [interrupter]).new_pool(timeout: 5)
      client = RedisQueuedLocks::Client.new(interrupted_redis)

      # NOTE: the first command of the release: WATCH (write locks) and MULTI (read locks)
      { write: 'WATCH', read: 'MULTI' }.each do |rw_mode, first_release_command|
        expect do
          client.lock_series('rel.a', 'rel.b', rw_mode:, ttl: 60_000) do
            interrupted_command = first_release_command
          end
        end.to raise_error(interrupted_error)
        expect(interrupted_command).to eq(nil)
        expect(client.locked?('rel.a')).to eq(false)
        expect(client.locked?('rel.b')).to eq(false)
        expect(client.keys).to be_empty
      end

      interrupted_redis.close
    end

    specify '#lock_series: reentrant locks' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 1
      end

      %i[write read].each do |rw_mode|
        aggregate_failures "extended locks get their ttl back (#{rw_mode})" do
          client.lock(
            're.outer', ttl: 10_000, rw_mode:, conflict_strategy: :extendable_work_through
          ) do
            client.lock_series(
              're.outer', 're.inner',
              ttl: 20_000, rw_mode:, conflict_strategy: :extendable_work_through
            ) do
              expect(client.lock_info('re.outer')['rem_ttl']).to be_between(20_000, 30_000)
            end
            expect(client.lock_info('re.outer')['rem_ttl']).to be_between(5_000, 10_500)
            expect(client.locked?('re.inner')).to eq(false)
          end
          expect(client.keys).to be_empty
        end

        aggregate_failures "work through locks are kept as is (#{rw_mode})" do
          client.lock(
            're.outer', ttl: 10_000, rw_mode:, conflict_strategy: :work_through
          ) do
            client.lock_series(
              're.outer', 're.inner', rw_mode:, conflict_strategy: :work_through
            ) do
              expect(client.locked?('re.inner')).to eq(true)
              expect(client.lock_info('re.outer')['rem_ttl']).to be <= 10_000
            end
            expect(client.locked?('re.outer')).to eq(true)
            expect(client.locked?('re.inner')).to eq(false)
          end
          expect(client.keys).to be_empty
        end

        aggregate_failures "the lock requests of the retries are dropped (#{rw_mode})" do
          # NOTE: the pre-check of a retry queues the lock requests of all locks (the lock state is
          #   not known before the queueing): the reentrant lock should not keep its request
          holder_client = RedisQueuedLocks::Client.new(redis)
          holder = Thread.new { holder_client.lock('re.busy', ttl: 300) }
          holder.join

          client.lock(
            're.outer', ttl: 10_000, rw_mode:, conflict_strategy: :work_through
          ) do
            client.lock_series(
              're.outer', 're.busy',
              rw_mode:, conflict_strategy: :work_through, retry_count: nil, timeout: 5
            ) { :ok }
            expect(client.queued?('re.outer')).to eq(false)
            expect(client.queued?('re.busy')).to eq(false)
          end
          expect(client.keys).to be_empty
        end
      end

      aggregate_failures 'a read lock series under the own write lock' do
        client.lock('re.outer', ttl: 10_000) do
          client.lock_series(
            're.outer', 're.inner', rw_mode: :read, conflict_strategy: :work_through
          ) { :ok }
          expect(client.lock_info('re.outer')['acq_id']).to eq(client.current_acquirer_id)
          expect(client.locked?('re.inner')).to eq(false)
        end
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: conflicts fail the whole series' do
      client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures ':dead_locking' do
        client.lock('conflict.a', ttl: 60_000)
        expect(
          client.lock_series('conflict.b', 'conflict.a', conflict_strategy: :dead_locking)
        ).to match({
          ok: false,
          result: hash_including(
            detailed_errors: { 'conflict.a' => { ok: false, result: :conflict_dead_lock } },
            acquired_locks: [],
            failed_on_lock: 'conflict.a'
          )
        })
        expect do
          client.lock_series!('conflict.b', 'conflict.a', conflict_strategy: :dead_locking)
        end.to raise_error(
          RedisQueuedLocks::ConflictLockObtainError,
          /trying to acquire the lock "rql:lock:conflict.a" that is already acquired/
        )
        expect(client.locked?('conflict.b')).to eq(false)
        expect(client.queued?('conflict.b')).to eq(false)
        client.unlock('conflict.a')
      end

      %i[work_through extendable_work_through dead_locking].each do |conflict_strategy|
        aggregate_failures "read-to-write lock upgrade (#{conflict_strategy})" do
          client.lock('conflict.r', rw_mode: :read, ttl: 60_000)
          result = client.lock_series('conflict.b', 'conflict.r', conflict_strategy:)
          expect(result[:result]).to include(failed_on_lock: 'conflict.r')
          expect(client.locked?('conflict.b')).to eq(false)
          client.unlock('conflict.r')
        end
      end

      aggregate_failures 'read-to-write lock upgrade: raised error' do
        client.lock('conflict.r', rw_mode: :read, ttl: 60_000)
        expect do
          client.lock_series!('conflict.b', 'conflict.r', conflict_strategy: :work_through)
        end.to raise_error(
          RedisQueuedLocks::ConflictLockObtainError,
          /write lock "rql:lock:conflict.r" while the current acquirer holds its read lock/
        )
        client.unlock('conflict.r')
      end

      aggregate_failures 'fail fast: the own lock of the series without the reentrant logic' do
        client.lock('conflict.own', ttl: 60_000)
        expect(client.lock_series('conflict.b', 'conflict.own', fail_fast: true)).to match({
          ok: false,
          result: hash_including(
            detailed_errors: { 'conflict.own' => { ok: false, result: :fail_fast_no_try } }
          )
        })
        expect(client.queued?('conflict.b')).to eq(false)
        client.unlock('conflict.own')
      end

      aggregate_failures 'fail fast: the first obtained lock' do
        holder_client = RedisQueuedLocks::Client.new(redis)
        holder = Thread.new { holder_client.lock('conflict.busy', ttl: 60_000) }
        holder.join
        expect do
          client.lock_series!('conflict.b', 'conflict.busy', fail_fast: true)
        end.to raise_error(
          RedisQueuedLocks::LockAlreadyObtainedError,
          'Lock "rql:lock:conflict.busy" is already obtained.'
        )
        expect(client.queued?('conflict.b')).to eq(false)
        holder_client.unlock('conflict.busy')
      end
      expect(client.keys).to be_empty
    end

    specify '#lock_series: a lock state changed during the attempt aborts the whole transaction' do
      # NOTE: a lock of another acquirer is obtained right before the obtaining transaction
      side_redis = RedisClient.config(db: 0).new_client
      is_change_required = true
      changer = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if is_change_required && commands.first == ['MULTI']
            is_change_required = false
            side_redis.call('HSET', 'rql:lock:race.b', 'acq_id', 'rql:acq:1/2/3/4/other')
            side_redis.call('PEXPIRE', 'rql:lock:race.b', 60_000)
          end
          super(commands, redis_config, &block)
        end
      end
      changing_redis = RedisClient.config(db: 0, middlewares: [changer]).new_pool(timeout: 5)
      test_notifier = Class.new do
        attr_reader :notifications

        def initialize
          @notifications = []
        end

        def notify(event, payload = {})
          notifications << event
        end
      end.new
      client = RedisQueuedLocks::Client.new(changing_redis) do |config|
        config['instrumenter'] = test_notifier
      end

      %i[write read].each do |rw_mode|
        is_change_required = true
        test_notifier.notifications.clear
        result = client.lock_series(
          'race.a', 'race.b', rw_mode:, ttl: 60_000, retry_count: 1
        ) { :never }

        expect(is_change_required).to eq(false)
        # NOTE: the transaction is aborted: no lock of the attempt blocks the series
        expect(result).to match({
          ok: false,
          result: {
            error: :failed_to_acquire_lock_series,
            detailed_errors: {},
            lock_series: %w[race.a race.b],
            acquired_locks: [],
            missing_locks: %w[race.a race.b],
            failed_on_lock: nil
          }
        })
        # NOTE: the locks passed the checks of the attempt and no lock blocks the series
        expect(test_notifier.notifications).to eq(%w[
          redis_queued_locks.lock_series_intermediate_lock_obtained
          redis_queued_locks.lock_series_intermediate_lock_obtained
          redis_queued_locks.lock_series_obtaining_failed
        ])
        expect(client.locked?('race.a')).to eq(false)
        expect(client.queued?('race.a')).to eq(false)
        expect(client.queued?('race.b')).to eq(false)
        side_redis.call('DEL', 'rql:lock:race.b')
      end

      expect(client.keys).to be_empty
      changing_redis.close
      side_redis.close
    end

    specify '#lock_series: a read lock expired during its extension fails the series' do
      # NOTE: the readers registry is not watched by read lock requests: the extension of an
      #   expired read lock fails inside the applied transaction (it can not be rolled back): other
      #   locks of the series are released, and the read lock data of the extension stays;
      side_redis = RedisClient.config(db: 0).new_client
      is_drop_required = true
      dropper = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if is_drop_required && commands.first == ['MULTI']
            extension = commands.find { |command| command[2..3] == %w[XX INCR] }
            if extension
              is_drop_required = false
              side_redis.call('ZREM', extension[1], extension[5])
            end
          end
          super(commands, redis_config, &block)
        end
      end
      dropping_redis = RedisClient.config(db: 0, middlewares: [dropper]).new_pool(timeout: 5)
      test_logger = Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << (block ? yield : progname)
        end
      end.new
      client = RedisQueuedLocks::Client.new(dropping_redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 1
        config['logger'] = test_logger
      end

      client.lock('expired.a', rw_mode: :read, ttl: 60_000)
      client.lock('expired.b', rw_mode: :read, ttl: 60_000)
      result = client.lock_series(
        'expired.a', 'expired.b', 'expired.c',
        rw_mode: :read,
        conflict_strategy: :extendable_work_through,
        ttl: 60_000,
        retry_count: 1
      )

      expect(is_drop_required).to eq(false)
      expect(result).to match({
        ok: false,
        result: hash_including(
          detailed_errors: { 'expired.a' => { ok: false, result: :retry_limit_reached } },
          failed_on_lock: 'expired.a'
        )
      })
      expect(client.locked?('expired.a')).to eq(false)
      # NOTE: the second read lock is extended by the transaction and its ttl is taken back
      expect(client.lock_info('expired.b')['rem_ttl']).to be_between(50_000, 61_000)
      expect(client.locked?('expired.c')).to eq(false)
      # NOTE: the locks of the applied transaction are released (and it is logged)
      expect(test_logger.logs).to include(
        a_string_including('[redis_queued_locks.expire_lock_series]', 'expired.c')
      )

      client.clear_locks
      dropping_redis.close
      side_redis.close
    end

    specify '#lock_series: one position of the lock request in all queues' do
      holder_client = RedisQueuedLocks::Client.new(redis)
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end

      lock_names = %w[pos.a pos.b pos.c]

      %i[write read].each do |rw_mode|
        queue_key = (rw_mode == :read) ? 'read_queue' : 'queue'
        holder = Thread.new { holder_client.lock('pos.a', ttl: 60_000) }
        holder.join
        series = Thread.new do
          client.lock_series(
            'pos.b', 'pos.a', 'pos.c', rw_mode:, priority: 7, timeout: 10
          ) { :done }
        end
        sleep(0.2) # NOTE: give a timespot to queue the lock requests

        requests = lock_names.map { |lock_name| client.queue_info(lock_name)[queue_key] }
        expect(requests.flatten.map { |request| request['score'] }.uniq.size).to eq(1)
        expect(requests.flatten).to all(include('priority' => 7))

        holder_client.unlock('pos.a')
        expect(series.value).to eq(:done)
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: the order of the lock series and single lock requests' do
      holder_client = RedisQueuedLocks::Client.new(redis)
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_count'] = nil
        config['retry_delay'] = 10
        config['retry_jitter'] = 5
      end
      timeline = []
      mark = -> (event) { timeline << event }
      holder = Thread.new { holder_client.lock('turn.a', ttl: 60_000) }
      holder.join

      low = Thread.new do
        client.lock_series('turn.a', 'turn.b', priority: -1, ttl: 5_000, timeout: 15) do
          mark.call(:low)
        end
      end
      sleep(0.15) # NOTE: give a timespot to queue the lock requests (one by one)
      fifo = Thread.new do
        client.lock_series('turn.b', 'turn.a', priority: -1, ttl: 5_000, timeout: 15) do
          mark.call(:fifo)
        end
      end
      sleep(0.15) # NOTE: give a timespot to queue the lock requests (one by one)
      # NOTE: a single lock request of the free lock waits for the requests of the series ahead
      single = Thread.new do
        client.lock('turn.b', priority: -1, ttl: 5_000, timeout: 15) { mark.call(:single) }
      end
      sleep(0.15) # NOTE: give a timespot to queue the lock requests (one by one)
      high = Thread.new do
        client.lock_series('turn.b', 'turn.a', priority: 1, ttl: 5_000, timeout: 15) do
          mark.call(:high)
        end
      end
      sleep(0.15) # NOTE: give a timespot to queue the lock requests (one by one)

      expect(timeline).to eq([])
      holder_client.unlock('turn.a')
      [low, fifo, single, high].each(&:join)

      expect(timeline).to eq(%i[high low fifo single])
      expect(client.keys).to be_empty
    end

    specify '#lock_series: dead lock requests of other priorities that block the series' do
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
      band = RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND
      dead_position = -> (priority) { Time.now.to_f - 100 - (priority * band) }
      client.lock('dead.warmup', ttl: 1_000) { :ok }

      aggregate_failures 'write lock requests: the queue heads of all locks in one round trip' do
        redis.call('ZADD', 'rql:lock_queue:dead.a', dead_position.call(5), 'rql:acq:dead/1')
        redis.call('ZADD', 'rql:lock_queue:dead.b', dead_position.call(3), 'rql:acq:dead/2')
        redis.call('ZADD', 'rql:lock_read_queue:dead.c', dead_position.call(2), 'rql:acq:dead/3')
        round_trips.clear

        expect(client.lock_series('dead.a', 'dead.b', 'dead.c', ttl: 5_000) { :ok }).to eq(:ok)
        # NOTE: (WATCH, the lock state), the removal, (MULTI/EXEC), (WATCH, owners, MULTI/EXEC)
        expect(round_trips.size).to eq(7)
        expect(round_trips[2].tally).to eq({ 'ZREMRANGEBYSCORE' => 6, 'ZRANGE' => 6 })
      end

      aggregate_failures 'log_lock_try: the dropped lock requests' do
        test_logger = Class.new do
          attr_reader :logs

          def initialize
            @logs = []
          end

          def debug(progname = nil, &block)
            logs << (block ? yield : progname)
          end
        end.new
        redis.call('ZADD', 'rql:lock_queue:dead.b', dead_position.call(3), 'rql:acq:dead/2')

        client.lock_series(
          'dead.a', 'dead.b', ttl: 5_000, logger: test_logger, log_lock_try: true
        ) { :ok }

        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.try_lock.dead_request_removed]',
            "lock_key => 'rql:lock:dead.b'",
            "dead_acq_id => 'rql:acq:dead/2' dead_priority => 3"
          )
        )
      end

      aggregate_failures 'log_lock_try: the requests dropped by a pre-check that does not fail' do
        test_logger = Class.new do
          attr_reader :logs

          def initialize
            @logs = []
          end

          def debug(progname = nil, &block)
            logs << (block ? yield : progname)
          end
        end.new
        holder_client = RedisQueuedLocks::Client.new(redis)
        holder = Thread.new { holder_client.lock('dead.b', ttl: 60_000) }
        holder.join
        series = Thread.new do
          client.lock_series(
            'dead.a', 'dead.b',
            ttl: 5_000, timeout: 10, retry_count: nil, retry_delay: 20, retry_jitter: 5,
            logger: test_logger, log_lock_try: true
          ) { :ok }
        end
        sleep(0.2) # NOTE: give a timespot to the first failed attempts of the series

        # NOTE: the next retry sees a free lock with a dead lock request ahead (one transaction)
        redis.multi do |transaction|
          transaction.call(
            'ZADD', 'rql:lock_queue:dead.b', dead_position.call(3), 'rql:acq:dead/2'
          )
          transaction.call('DEL', 'rql:lock:dead.b')
        end

        expect(series.value).to eq(:ok)
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.try_lock.dead_request_removed]',
            "lock_key => 'rql:lock:dead.b'",
            "dead_acq_id => 'rql:acq:dead/2' dead_priority => 3"
          )
        )
      end

      aggregate_failures 'read lock requests' do
        redis.call('ZADD', 'rql:lock_queue:dead.a', dead_position.call(5), 'rql:acq:dead/1')
        expect(
          client.lock_series('dead.a', 'dead.b', rw_mode: :read, ttl: 5_000) { :ok }
        ).to eq(:ok)
      end

      aggregate_failures 'dead requests at -inf (manual writes)' do
        redis.call('ZADD', 'rql:lock_queue:dead.a', '-inf', 'rql:acq:dead/1')
        expect(client.lock_series('dead.a', 'dead.b', ttl: 5_000) { :ok }).to eq(:ok)
      end

      aggregate_failures 'a live lock request stops the series' do
        redis.call('ZADD', 'rql:lock_queue:dead.b', Time.now.to_f - (5 * band), 'rql:acq:live/1')
        expect(
          client.lock_series('dead.a', 'dead.b', ttl: 5_000, retry_count: 2, retry_delay: 1)
        ).to match({ ok: false, result: hash_including(failed_on_lock: 'dead.b') })
        redis.call('ZREM', 'rql:lock_queue:dead.b', 'rql:acq:live/1')
      end

      aggregate_failures 'more dead requests than the removals of one attempt: the next attempts' do
        limit = RedisQueuedLocks::Acquirer::AcquireLock::TryToLock::MAX_DEAD_REQUEST_REMOVALS
        (limit + 1).times do |index|
          redis.call(
            'ZADD', 'rql:lock_queue:dead.a', dead_position.call(index + 1), "rql:acq:dead/#{index}"
          )
        end
        expect(client.lock_series('dead.a', 'dead.b', ttl: 5_000) { :ok }).to eq(:ok)
      end

      client.reindex_locks if client.config['lock_index_enabled']
      expect(client.keys).to be_empty
      recorded_redis.close
    end

    specify '#lock_series: a request that reached its queue ttl is queued again in all queues' do
      holder_client = RedisQueuedLocks::Client.new(redis)
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
        config['retry_count'] = nil
        config['retry_delay'] = 20
        config['retry_jitter'] = 5
        config['logger'] = test_logger
      end
      holder = Thread.new { holder_client.lock('requeue.b', ttl: 1_600) }
      holder.join

      result = client.lock_series(
        'requeue.a', 'requeue.b', queue_ttl: 1, ttl: 5_000, timeout: 10
      ) { :ok }

      expect(result).to eq(:ok)
      expect(test_logger.logs).to include(
        a_string_including(
          '[redis_queued_locks.dead_score_reached__reset_series_position]',
          "lock_keys => '[\"rql:lock:requeue.a\", \"rql:lock:requeue.b\"]' queue_ttl => 1"
        )
      )
      expect(client.keys).to be_empty
    end

    specify '#lock_series: round trips do not depend on the size of the series' do
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
      client = RedisQueuedLocks::Client.new(recorded_redis) do |config|
        config['retry_delay'] = 1
        config['retry_jitter'] = 1
      end
      holder_client = RedisQueuedLocks::Client.new(redis)
      client.lock('trips.warmup', ttl: 1_000) { :ok } # NOTE: the connection prelude

      [2, 10].each do |locks_count|
        lock_names = Array.new(locks_count) { |index| "trips.#{index}" }

        aggregate_failures "an obtained series (write, #{locks_count} locks)" do
          round_trips.clear
          client.lock_series(*lock_names, ttl: 5_000) { :ok }
          # NOTE: WATCH, the lock state with the queueing, MULTI/EXEC, compare-and-delete release
          expect(round_trips.size).to eq(6)
        end

        aggregate_failures "an obtained series (read, #{locks_count} locks)" do
          round_trips.clear
          client.lock_series(*lock_names, ttl: 5_000, rw_mode: :read) { :ok }
          # NOTE: WATCH, the lock state with the queueing, MULTI/EXEC, the release transaction
          expect(round_trips.size).to eq(4)
        end

        aggregate_failures "a failed series (#{locks_count} locks)" do
          holder = Thread.new { holder_client.lock(lock_names.last, ttl: 60_000) }
          holder.join

          round_trips.clear
          client.lock_series(*lock_names, ttl: 5_000, retry_count: 4)
          # NOTE: the failed attempt (WATCH, the lock state, UNWATCH), three failed pre-checks of
          #   the retries (one round trip each) and the dequeue of all lock requests
          expect(round_trips.size).to eq(7)

          round_trips.clear
          client.lock_series(*lock_names, ttl: 5_000, fail_fast: true)
          # NOTE: `fail_fast` on an obtained lock: the pre-check only
          expect(round_trips.size).to eq(1)

          holder_client.unlock(lock_names.last)
        end
      end
      expect(client.keys).to be_empty
      recorded_redis.close
    end

    specify 'lock series pipeline layout' do
      # NOTE: (see "pipeline layout" in `TryToLockSeries#pipeline_series_lock_state`)
      #   - the replies of each lock are read by the position constants of the single lock attempt:
      #     each lock has the same commands in the lock state pipeline;
      #   - the extensions of the read locks are the first commands of the obtaining transaction;
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
      lock_index_enabled = client.config['lock_index_enabled']
      lock_names = %w[series.pipeline.a series.pipeline.b series.pipeline.c]
      queue_replies =
        try_to_lock::QUEUE_REPLIES +
        (lock_index_enabled ? try_to_lock::QUEUE_LOCK_INDEX_REPLIES : 0)
      expect(queue_replies).to eq(lock_index_enabled ? 9 : 5)
      state_pipeline = -> { pipelines.find { |commands| commands.include?(['TIME']) } }

      aggregate_failures 'eager queueing: the commands of each lock in the lock state pipeline' do
        { write: 1, read: 0 }.each do |rw_mode, write_tail|
          pipelines.clear
          client.lock_series(*lock_names, ttl: 10_000, rw_mode:) { :ok }

          lock_commands = state_pipeline.call.each_slice(
            try_to_lock::LOCK_STATE_QUEUE_REPLIES_AT + queue_replies + write_tail
          ).to_a
          expect(lock_commands.size).to eq(lock_names.size)
          lock_commands.each_with_index do |commands, index|
            lock_name = lock_names[index]
            request_queue = (rw_mode == :read) ? 'lock_read_queue' : 'lock_queue'
            queueing_at = try_to_lock::LOCK_STATE_QUEUE_REPLIES_AT

            expect(commands[try_to_lock::LOCK_STATE_OBTAINER_REPLY]).to eq(
              ['HGET', "rql:lock:#{lock_name}", 'acq_id']
            )
            expect(commands[try_to_lock::LOCK_STATE_REDIS_TIME_REPLY]).to eq(['TIME'])
            expect(commands[try_to_lock::LOCK_STATE_OWN_READ_LOCK_REPLY]).to eq(
              ['ZSCORE', "rql:lock_readers:#{lock_name}", client.current_acquirer_id]
            )
            expect(commands[queueing_at + 2][0..2]).to eq(
              ['ZADD', "rql:#{request_queue}:#{lock_name}", 'NX']
            )
            expect(commands[queueing_at + try_to_lock::QUEUE_HEAD_REPLY]).to eq(
              ['ZRANGE', "rql:#{request_queue}:#{lock_name}", '0', '0', 'WITHSCORES']
            )
            next if write_tail.zero?

            expect(commands.last).to eq(
              ['ZRANGE', "rql:lock_readers:#{lock_name}", '-1', '-1', 'WITHSCORES']
            )
          end
        end
      end

      aggregate_failures 'without eager queueing: a separate pipeline (no reentrant locks)' do
        client.lock('series.pipeline.a', ttl: 10_000)
        pipelines.clear
        client.lock_series(
          *lock_names, ttl: 10_000, conflict_strategy: :work_through
        ) { :ok }

        queueing = pipelines.find do |commands|
          commands.any? { |command| command[0..2] in ['ZADD', _, 'NX'] }
        end
        expect(state_pipeline.call.size).to eq(
          lock_names.size * (try_to_lock::LOCK_STATE_QUEUE_REPLIES_AT + 1)
        )
        expect(queueing.size).to eq(2 * queue_replies)
        queued_keys = queueing.filter_map do |command|
          command[1] if command[0..2] in ['ZADD', _, 'NX']
        end
        expect(queued_keys).to eq(
          %w[rql:lock_queue:series.pipeline.b rql:lock_queue:series.pipeline.c]
        )
        client.unlock('series.pipeline.a')
      end

      aggregate_failures 'the extensions of the read locks are the first transaction commands' do
        client.lock('series.pipeline.a', ttl: 10_000, rw_mode: :read)
        client.lock('series.pipeline.c', ttl: 10_000, rw_mode: :read)
        pipelines.clear
        client.lock_series(
          *lock_names,
          ttl: 10_000, rw_mode: :read, conflict_strategy: :extendable_work_through
        ) { :ok }

        transaction = pipelines.find { |commands| commands.first == ['MULTI'] }
        extension_commands =
          try_to_lock::READ_LOCK_EXTENSION_COMMANDS + (lock_index_enabled ? 1 : 0)
        extensions = [transaction[1], transaction[1 + extension_commands]]
        expect(extensions.map { |command| command[0..3] }).to eq([
          ['ZADD', 'rql:lock_readers:series.pipeline.a', 'XX', 'INCR'],
          ['ZADD', 'rql:lock_readers:series.pipeline.c', 'XX', 'INCR']
        ])
      end

      client.clear_locks
      recorded_redis.close
    end

    specify 'lock series observability' do
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
      holder_client = RedisQueuedLocks::Client.new(redis)
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['retry_delay'] = 10
        config['retry_jitter'] = 1
        config['instrumenter'] = test_notifier
        config['logger'] = test_logger
      end
      lock_names = %w[series.obs.a series.obs.b]
      next_lock_names = %w[series.obs.c series.obs.d]
      lock_keys = ['rql:lock:series.obs.a', 'rql:lock:series.obs.b']
      keys_in_log = "lock_keys => '#{lock_keys.inspect}' queue_ttl => 15 " \
                    "acq_id => '#{client.current_acquirer_id}' " \
                    "hst_id => '#{client.current_host_id}' acs_strat => 'queued' " \
                    "rw_mode => 'write' priority => 3"
      events = -> { test_notifier.notifications.map { |notification| notification[:event] } }
      series_lock_event = lambda do |event, lock_key|
        {
          event: "redis_queued_locks.#{event}",
          payload: {
            lock_key:, lock_keys:, rw_mode: :write, priority: 3, ttl: 5_000,
            acq_id: client.current_acquirer_id, hst_id: client.current_host_id,
            ts: be_a(Float), acq_time: be_a(Numeric), instrument: :i
          }
        }
      end
      lock_log = lambda do |event, lock_key|
        a_string_starting_with(
          "[redis_queued_locks.#{event}] lock_key => '#{lock_key}' #{keys_in_log} acq_time => "
        ).and(ending_with(' (ms)'))
      end

      aggregate_failures 'the obtained series: the events of each lock and of the series' do
        client.lock_series(*lock_names, ttl: 5_000, priority: 3, instrument: :i) { :ok }
        expect(test_notifier.notifications).to match([
          series_lock_event.call('lock_series_intermediate_lock_obtained', lock_keys[0]),
          series_lock_event.call('lock_series_intermediate_lock_obtained', lock_keys[1]),
          series_lock_event.call('lock_series_lock_obtained', lock_keys[0]),
          series_lock_event.call('lock_series_lock_obtained', lock_keys[1]),
          {
            event: 'redis_queued_locks.lock_series_obtained',
            payload: {
              lock_keys:, rw_mode: :write, priority: 3, ttl: 5_000,
              acq_id: client.current_acquirer_id, hst_id: client.current_host_id,
              ts: be_a(Float), acq_time: be_a(Numeric), reentrant_lock_keys: [], instrument: :i
            }
          },
          {
            event: 'redis_queued_locks.lock_series_hold_and_release',
            payload: {
              lock_keys:, rw_mode: :write, priority: 3, hold_time: be_a(Numeric), ttl: 5_000,
              acq_id: client.current_acquirer_id, hst_id: client.current_host_id,
              ts: be_a(Float), acq_time: be_a(Numeric), reentrant_lock_keys: [], instrument: :i
            }
          }
        ])
        expect(test_logger.logs).to match([
          "[redis_queued_locks.start_lock_series_obtaining] #{keys_in_log}",
          "[redis_queued_locks.start_try_to_lock_series_cycle] #{keys_in_log}",
          lock_log.call('lock_series_intermediate_lock_obtained', lock_keys[0]),
          lock_log.call('lock_series_intermediate_lock_obtained', lock_keys[1]),
          lock_log.call('lock_series_lock_obtained', lock_keys[0]),
          lock_log.call('lock_series_lock_obtained', lock_keys[1]),
          a_string_starting_with(
            "[redis_queued_locks.lock_series_obtained] #{keys_in_log} acq_time => "
          ).and(ending_with("reentrant_lock_keys => '[]'")),
          "[redis_queued_locks.expire_lock_series] #{keys_in_log}"
        ])
      end

      aggregate_failures 'the reentrant locks of the series' do
        test_notifier.notifications.clear
        test_logger.logs.clear
        client.lock(
          'series.obs.a', ttl: 5_000, conflict_strategy: :extendable_work_through
        ) do
          test_notifier.notifications.clear
          client.lock_series(
            'series.obs.a', 'series.obs.b',
            ttl: 5_000, priority: 3, conflict_strategy: :extendable_work_through
          ) { :ok }
        end
        # NOTE: the events of the series follow the events of its locks (the outer lock is the last)
        expect(test_notifier.notifications[2, 2].map { |item| item[:payload] }).to all(
          include(reentrant_lock_keys: ['rql:lock:series.obs.a'])
        )
        # NOTE: a reentrant lock is not obtained by the series: no lock events
        expect(
          test_notifier.notifications.first(2).map do |notification|
            [notification[:event], notification[:payload][:lock_key]]
          end
        ).to eq([
          ['redis_queued_locks.lock_series_intermediate_lock_obtained', 'rql:lock:series.obs.b'],
          ['redis_queued_locks.lock_series_lock_obtained', 'rql:lock:series.obs.b']
        ])
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.lock_series_obtained]',
            "reentrant_lock_keys => '[\"rql:lock:series.obs.a\"]'"
          ),
          match(
            /\A\[redis_queued_locks\.decrease_lock_series\] lock_keys => '\["rql:lock:series\.obs\.a"\]' decreased_ttl => \d+ queue_ttl => 15 / # rubocop:disable Layout/LineLength
          )
        )
      end

      aggregate_failures 'the failed series: the blocking lock and the series' do
        holder = Thread.new { holder_client.lock('series.obs.b', ttl: 60_000) }
        holder.join
        test_notifier.notifications.clear
        test_logger.logs.clear

        client.lock_series(
          'series.obs.a', 'series.obs.b', ttl: 5_000, priority: 3, retry_count: 1, instrument: :i
        )
        expect(test_notifier.notifications).to match([
          # NOTE: the lock before the lock that blocks the series passed the checks of the attempt
          series_lock_event.call('lock_series_intermediate_lock_obtained', lock_keys[0]),
          {
            event: 'redis_queued_locks.lock_series_lock_obtaining_failed',
            payload: {
              lock_key: lock_keys[1], lock_keys:, rw_mode: :write, priority: 3, ttl: 5_000,
              acq_id: client.current_acquirer_id, hst_id: client.current_host_id,
              ts: be_a(Float), acq_time: be_a(Numeric), result: :retry_limit_reached,
              instrument: :i
            }
          },
          {
            event: 'redis_queued_locks.lock_series_obtaining_failed',
            payload: {
              lock_keys:, rw_mode: :write, priority: 3, ttl: 5_000,
              acq_id: client.current_acquirer_id, hst_id: client.current_host_id,
              ts: be_a(Float), acq_time: be_a(Numeric), result: :retry_limit_reached,
              failed_lock_key: 'rql:lock:series.obs.b', instrument: :i
            }
          }
        ])
        expect(test_logger.logs).to match([
          "[redis_queued_locks.start_lock_series_obtaining] #{keys_in_log}",
          "[redis_queued_locks.start_try_to_lock_series_cycle] #{keys_in_log}",
          lock_log.call('lock_series_intermediate_lock_obtained', lock_keys[0]),
          "[redis_queued_locks.dequeue_from_lock_series_queues] #{keys_in_log}",
          a_string_starting_with(
            "[redis_queued_locks.lock_series_lock_obtaining_failed] lock_key => " \
            "'#{lock_keys[1]}' #{keys_in_log} acq_time => "
          ).and(ending_with("(ms) result => 'retry_limit_reached'")),
          a_string_starting_with(
            "[redis_queued_locks.lock_series_obtaining_failed] #{keys_in_log} acq_time => "
          ).and(
            ending_with(
              "(ms) result => 'retry_limit_reached' failed_lock_key => 'rql:lock:series.obs.b'"
            )
          )
        ])
      end

      aggregate_failures 'raised errors: reported before the error is raised' do
        test_notifier.notifications.clear
        expect do
          client.lock_series!('series.obs.a', 'series.obs.b', ttl: 5_000, fail_fast: true)
        end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
        expect(test_notifier.notifications).to match([
          {
            event: 'redis_queued_locks.lock_series_lock_obtaining_failed',
            payload: hash_including(lock_key: 'rql:lock:series.obs.b', result: :fail_fast_no_try)
          },
          {
            event: 'redis_queued_locks.lock_series_obtaining_failed',
            payload: hash_including(
              result: :fail_fast_no_try, failed_lock_key: 'rql:lock:series.obs.b'
            )
          }
        ])
      end

      aggregate_failures 'the intermediate obtaining: once per lock, not per attempt' do
        test_notifier.notifications.clear
        client.lock_series('series.obs.a', 'series.obs.b', ttl: 5_000, retry_count: 5)
        expect(
          events.call.count('redis_queued_locks.lock_series_intermediate_lock_obtained')
        ).to eq(1)
        expect(events.call.count('redis_queued_locks.lock_series_lock_obtaining_failed')).to eq(1)
      end

      aggregate_failures 'errors of the block of code are not reported as failures' do
        test_notifier.notifications.clear
        expect do
          client.lock_series('series.obs.c') { raise(RedisQueuedLocks::LockAlreadyObtainedError) }
        end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
        expect(events.call).to eq(%w[
          redis_queued_locks.lock_series_intermediate_lock_obtained
          redis_queued_locks.lock_series_lock_obtained
          redis_queued_locks.lock_series_obtained
          redis_queued_locks.lock_series_hold_and_release
        ])
      end

      aggregate_failures 'log_lock_try: the try-lock logs of each lock' do
        test_logger.logs.clear
        client.lock_series(*next_lock_names, ttl: 5_000, log_lock_try: true) { :ok }
        %w[start rconn_fetched acq_added_to_queue get_first_from_queue].each do |event|
          next_lock_names.each do |lock_name|
            expect(test_logger.logs).to include(
              a_string_including(
                "[redis_queued_locks.try_lock.#{event}]", "lock_key => 'rql:lock:#{lock_name}'"
              )
            )
          end
        end
        expect(test_logger.logs.grep(/try_lock\.obtain__free_to_acquire/).size).to eq(2)

        test_logger.logs.clear
        client.lock_series(
          'series.obs.c', 'series.obs.b', ttl: 5_000, log_lock_try: true, retry_count: 2
        )
        expect(test_logger.logs.grep(/try_lock\.exit__lock_still_obtained/).size).to eq(2)
        expect(test_logger.logs.grep(/try_lock\.exit__lock_still_obtained/)).to all(
          include("lock_key => 'rql:lock:series.obs.b'")
        )
      end

      holder_client.unlock('series.obs.b')
      expect(client.keys).to be_empty
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

    # NOTE: 10 rounds: 100 rounds took ~3 minutes per example under the RBS runtime checks
    10.times do
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

    # NOTE: 10 rounds: 100 rounds took ~3 minutes per example under the RBS runtime checks
    10.times do
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
            client.lock('ttl.args', ttl:, rw_mode: mode)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
          expect do
            client.lock!('ttl.args', ttl:, rw_mode: mode)
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
          expect do
            client.lock('ttl.args', ttl:, rw_mode: mode) { 1 + 1 }
          end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
          expect do
            client.lock_series('ttl.args.a', 'ttl.args.b', ttl:, rw_mode: mode)
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
      client.lock('ttl.ext.read', ttl: 10_000, rw_mode: :read)

      [0, -20_000].each do |milliseconds|
        expect do
          client.extend_lock_ttl('ttl.ext.write', milliseconds)
        end.to raise_error(RedisQueuedLocks::ArgumentError, /milliseconds/)
        expect do
          client.extend_lock_ttl('ttl.ext.read', milliseconds, rw_mode: :read)
        end.to raise_error(RedisQueuedLocks::ArgumentError, /milliseconds/)
        expect do
          client.extend_lock_ttl(
            'ttl.ext.read', milliseconds, rw_mode: :read, all_read_locks: true
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
            'bum.bum.bam.bam', ttl: 5_000, rw_mode: mode, meta: { 'rw_mode' => 'kek' }
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
              'bum.bum.bam.bam', ttl: 5_000, rw_mode: mode, meta: { reserved_key => 'kek' }
            )
          end.to raise_error(RedisQueuedLocks::ArgumentError, /reserved lock data keys/)
          expect(client.locked?('bum.bum.bam.bam')).to eq(false)

          expect do
            client.lock_series(
              'bum.a', 'bum.b', ttl: 5_000, rw_mode: mode, meta: { reserved_key => 'kek' }
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
    client.lock('obs.read', ttl: 10_000, rw_mode: :read)

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
      client.lock('obs.busy', ttl: 5_000, retry_count: 2, rw_mode: :read)
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

    aggregate_failures 'lock series: the series events only (see "lock series observability")' do
      test_notifier.notifications.clear
      client.lock_series('obs.series', 'obs.busy', ttl: 5_000, fail_fast: true) { :never }
      expect(failures.call).to be_empty
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

  specify '`timed` budget: stays within the lock lifetime, no budget => the block is not invoked' do
    redis = RedisClient.config.new_pool(
      timeout: 5, size: 50, connect_timeout: 5, read_timeout: 5, write_timeout: 5
    )
    client = RedisQueuedLocks::Client.new(redis)
    margin = RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR

    budgets = []
    allow(Timeout).to receive(:timeout).and_wrap_original do |original, sec, klass = nil, &block|
      budgets << sec if klass == RedisQueuedLocks::TimedLockIntermediateTimeoutError
      original.call(sec, klass, &block)
    end

    %i[write read].each do |mode|
      budgets.clear

      client.lock('timed-budget', ttl: 1_000, timed: true, rw_mode: mode) { :done }
      client.lock_series(
        'timed-budget.a', 'timed-budget.b', ttl: 1_000, timed: true, rw_mode: mode
      ) { :done }

      expect(budgets.size).to eq(2)
      expect(budgets).to all(be <= (1_000 - margin) / 1_000.0)
      expect(budgets).to all(be > 0)

      invoked = false
      expect do
        client.lock('timed-budget', ttl: margin, timed: true, rw_mode: mode) { invoked = true }
      end.to raise_error(
        RedisQueuedLocks::LockTtlTimeBudgetIsSpentError,
        /was not invoked: the time budget of the lock TTL is spent \(lock: /
      )
      expect do
        client.lock_series(
          'timed-budget.a', 'timed-budget.b', ttl: margin, timed: true, rw_mode: mode
        ) { invoked = true }
      end.to raise_error(
        RedisQueuedLocks::LockTtlTimeBudgetIsSpentError,
        /was not invoked: the time budget of the lock TTL is spent \(lock: /
      )

      expect(invoked).to eq(false)
      expect(budgets.size).to eq(2)
      expect(client.keys).to be_empty
    end

    redis.close
  end

  specify '`timed` failures are `TimedLockTimeoutError`s' do
    expect(RedisQueuedLocks::LockTtlTimeBudgetIsSpentError.superclass).to eq(
      RedisQueuedLocks::TimedLockTimeoutError
    )
    expect(RedisQueuedLocks::TimedBlockExceedsLockTtlError.superclass).to eq(
      RedisQueuedLocks::TimedLockTimeoutError
    )
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
    end.to raise_error(RedisQueuedLocks::TimedBlockExceedsLockTtlError)

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
    waiters = %i[write read].to_h do |rw_mode|
      holder_client.lock("requeue.#{rw_mode}", ttl: 2_500)
      waiter = Thread.new do
        client.lock(
          "requeue.#{rw_mode}",
          rw_mode:, queue_ttl: 1, retry_count: nil, retry_delay: 100, retry_jitter: 0,
          timeout: 10
        )
      end
      [rw_mode, waiter]
    end
    logs = lambda do |event, rw_mode|
      test_logger.logs.grep(
        /\A\[redis_queued_locks\.#{event}\] lock_key => 'rql:lock:requeue\.#{rw_mode}' /
      )
    end

    aggregate_failures 'write and read lock requests' do
      waiters.each do |rw_mode, waiter|
        expect(waiter.value).to match({
          ok: true,
          result: hash_including(lock_key: "rql:lock:requeue.#{rw_mode}")
        })
        expect(
          logs.call('dead_score_reached__reset_acquirer_position', rw_mode)
        ).not_to be_empty
        # NOTE: the requeued lock request is never missing in its lock queue
        expect(logs.call('try_lock\.exit__queue_ttl_reached', rw_mode)).to be_empty
      end
    end

    waiters.each_key { |rw_mode| client.unlock("requeue.#{rw_mode}") }
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
        requests.map do |name, rw_mode, priority|
          queued_before = queued_requests.call(lock_name)
          requester = Thread.new do
            prio_client.lock(
              lock_name, ttl: 30_000, rw_mode:, priority:, retry_count: nil, timeout: 20
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

    specify ':random lock requests are queued at the position of their priority' do
      # NOTE: a `:random` lock request does not wait for its turn (it ignores the order of the
      #   queues and the priorities of other requests), but it is queued at the position of its
      #   priority like a `:queued` one: `:queued` lock requests wait for it;
      timeline = []
      timeline_lock = Mutex.new
      release = Thread::Queue.new
      holder = hold_lock.call('prio.random', release)
      random_requester = Thread.new do
        prio_client.lock(
          'prio.random',
          ttl: 30_000, access_strategy: :random, priority: 100, retry_count: nil, timeout: 20
        ) do
          timeline_lock.synchronize { timeline << :random_highest }
          sleep(0.05) # NOTE: the :queued lock request waits for the release of the lock
        end
      end
      wait_until.call { queued_requests.call('prio.random') == 1 }
      queued_requester = Thread.new do
        prio_client.lock('prio.random', ttl: 30_000, retry_count: nil, timeout: 20) do
          timeline_lock.synchronize { timeline << :queued_normal }
        end
      end
      wait_until.call { queued_requests.call('prio.random') == 2 }

      expect(prio_client.queue_info('prio.random')['queue'].map { |request| request['priority'] })
        .to eq([100, 0])

      release << true
      [holder, random_requester, queued_requester].each(&:join)
      # NOTE: the :queued lock request is not the first in the queue until the :random one obtains
      #   the lock (its request leaves the queue)
      expect(timeline).to eq(%i[random_highest queued_normal])
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
            'prio.dead', rw_mode: :read, priority: 0, queue_ttl: 5, retry_count: 1
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
      # NOTE: the try-lock log events of the last attempt (the same order in the attempt and in
      #   the pre-check: the dropped dead requests after the queueing events)
      last_attempt_events = lambda do
        events = test_logger.logs.filter_map do |log|
          log[/\[redis_queued_locks\.try_lock\.(\w+)\]/, 1]
        end
        events.drop(events.rindex('start'))
      end
      client.locked?('prio.trips') # NOTE: establish the recorded connection

      aggregate_failures 'the attempt: one round trip per dead band ahead' do
        test_logger.logs.clear
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
        expect(last_attempt_events.call).to eq(%w[
          start rconn_fetched acq_added_to_queue remove_expired_acqs
          dead_request_removed dead_request_removed get_first_from_queue obtain__free_to_acquire
        ])
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
        # NOTE: the failed pre-check logs the events of the failed attempt in the same order
        expect(last_attempt_events.call).to eq(%w[
          start rconn_fetched acq_added_to_queue remove_expired_acqs
          dead_request_removed get_first_from_queue exit__lock_still_obtained
        ])
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

      # NOTE: all lock requests are read (default) or the first request of each priority
      [false, true].each do |by_priority|
        aggregate_failures "by_priority: #{by_priority}" do
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
            'ZADD', 'rql:lock_read_queue:prio.clear',
            position.call(1, 60), 'rql:acq:1/2/3/4/dead_read'
          )
          prio_client.reindex_locks if prio_client.config['lock_index_enabled']

          expect(prio_client.clear_dead_requests(dead_ttl: 30_000, by_priority:)).to match({
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
      end
    end

    specify 'clear_dead_requests by priority: the first request of each priority is read' do
      # NOTE: the pipelines are observed via a separate pool (the same db) with a recording
      #   middleware (the lookup commands are single calls: SCAN, ZSCAN, the lock index prune;
      #   the connection prelude, `HELLO`, is not recorded)
      pipelines = []
      recorder = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          pipelines << commands.map(&:dup) unless commands.first.first == 'HELLO'
          super(commands, redis_config, &block)
        end
      end
      recorded_redis =
        RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5, size: 1)
      client = RedisQueuedLocks::Client.new(recorded_redis)
      position = lambda do |priority, age|
        RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority) - age
      end
      first_request_read = lambda do |command|
        command[0] == 'ZRANGE' && command[-5..] == %w[BYSCORE LIMIT 0 1 WITHSCORES]
      end
      # NOTE: three priorities of the write queue (`walk.a`): 100 (dead + alive), 0 (alive), -50
      #   (dead + alive); one priority of the read queue (`walk.b`): 0 (dead); requests at
      #   positions out of the float precision of the priority bands (manual writes) never stop
      #   the walk (`walk.c`)
      queue_data = lambda do
        redis.call(
          'ZADD', 'rql:lock_queue:walk.a',
          position.call(100, 60), 'rql:acq:1/2/3/4/dead_high',
          position.call(100, 1), 'rql:acq:1/2/3/4/alive_high',
          position.call(0, 2), 'rql:acq:1/2/3/4/alive_normal_first',
          position.call(0, 1), 'rql:acq:1/2/3/4/alive_normal_second',
          position.call(-50, 60), 'rql:acq:1/2/3/4/dead_low_first',
          position.call(-50, 50), 'rql:acq:1/2/3/4/dead_low_second',
          position.call(-50, 1), 'rql:acq:1/2/3/4/alive_low'
        )
        redis.call(
          'ZADD', 'rql:lock_read_queue:walk.b', position.call(0, 60), 'rql:acq:1/2/3/4/dead_read'
        )
        client.reindex_locks if client.config['lock_index_enabled']
      end
      remaining_requests = lambda do
        [
          redis.call('ZRANGE', 'rql:lock_queue:walk.a', '0', '-1'),
          redis.call('ZRANGE', 'rql:lock_read_queue:walk.b', '0', '-1')
        ]
      end
      alive_requests = [
        %w[
          rql:acq:1/2/3/4/alive_high rql:acq:1/2/3/4/alive_normal_first
          rql:acq:1/2/3/4/alive_normal_second rql:acq:1/2/3/4/alive_low
        ],
        []
      ]
      processed_queues = match({
        ok: true,
        result: {
          processed_queues: contain_exactly('rql:lock_queue:walk.a', 'rql:lock_read_queue:walk.b')
        }
      })

      aggregate_failures 'by_priority: false (default): all lock requests, two round trips' do
        queue_data.call
        pipelines.clear
        expect(client.clear_dead_requests(dead_ttl: 30_000)).to processed_queues
        expect(remaining_requests.call).to eq(alive_requests)
        expect(pipelines.size).to eq(2)
        expect(pipelines[0]).to all(match(['ZRANGE', be_a(String), '0', '-1', 'WITHSCORES']))
        expect(pipelines[1].map(&:first)).to eq(%w[ZREMRANGEBYSCORE] * 3)
      end

      aggregate_failures 'by_priority: true: one round trip per priority + 1' do
        queue_data.call
        pipelines.clear
        expect(client.clear_dead_requests(dead_ttl: 30_000, by_priority: true)).to processed_queues
        expect(remaining_requests.call).to eq(alive_requests)
        # NOTE: the most priorities of a queue (3) + 1 (the last read finds nothing); the dead
        #   requests of a priority are dropped by the next round trip (after its reads): 100 and the
        #   read queue by the 2nd one, -50 by the 4th one (no separate removal round trip)
        #   (the lock index lookup reads both queues of each lock: the missing ones too)
        expect(pipelines.map { |commands| commands.map(&:first) }).to eq(
          [
            %w[ZRANGE] * (client.config['lock_index_enabled'] ? 4 : 2),
            %w[ZRANGE ZRANGE ZREMRANGEBYSCORE ZREMRANGEBYSCORE],
            %w[ZRANGE],
            %w[ZRANGE ZREMRANGEBYSCORE]
          ]
        )
        expect(pipelines.flatten(1).select { |command| command[0] == 'ZRANGE' }).to all(
          satisfy(&first_request_read)
        )
      end

      aggregate_failures 'by_priority: true: positions out of the float precision of the bands' do
        # NOTE: the lower edge of the next band rounds to such a position: the walk goes on after
        #   it (an exclusive bound); both ways of reading drop the same requests
        garbage = ['-1e30', 'rql:acq:1/2/3/4/g1', '1e30', 'rql:acq:1/2/3/4/g2',
                   (2.0**85).to_s, 'rql:acq:1/2/3/4/g3', '+inf', 'rql:acq:1/2/3/4/last']
        remaining = [false, true].map do |by_priority|
          redis.call('ZADD', 'rql:lock_queue:walk.c', *garbage)
          redis.call(
            'ZADD', 'rql:lock_queue:walk.c',
            position.call(0, 60), 'rql:acq:1/2/3/4/dead',
            position.call(0, 1), 'rql:acq:1/2/3/4/alive'
          )
          client.reindex_locks if client.config['lock_index_enabled']
          client.clear_dead_requests(dead_ttl: 30_000, by_priority:)
          redis.call('ZRANGE', 'rql:lock_queue:walk.c', '0', '-1')
        end
        expect(remaining[1]).to eq(remaining[0])
        expect(remaining[1]).to include('rql:acq:1/2/3/4/alive', 'rql:acq:1/2/3/4/last')
        expect(remaining[1]).not_to include('rql:acq:1/2/3/4/dead')
      end

      aggregate_failures 'by_priority: a boolean' do
        # NOTE: (RBS) type-invalid values can't reach the runtime validation under the RBS runtime
        #   type checks (the hook raises first)
        unless RBS_RUNTIME_TEST
          [nil, 1, 'true'].each do |value|
            expect { client.clear_dead_requests(by_priority: value) }.to raise_error(
              RedisQueuedLocks::ArgumentError,
              "`:by_priority` argument should be a boolean, got #{value.inspect}."
            )
          end
        end
      end

      client.clear_locks
      recorded_redis.close
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
        # NOTE: all lock requests are read (default) or the first request of each priority (the
        #   requests at `-inf` are the first ones, the walk stops at `+inf`)
        [false, true].each do |by_priority|
          redis.call(
            'ZADD', 'rql:lock_queue:prio.inf',
            '-inf', 'rql:acq:1/2/3/4/first', '+inf', 'rql:acq:1/2/3/4/last'
          )
          redis.call('ZADD', 'rql:lock_read_queue:prio.inf', '-inf', 'rql:acq:1/2/3/4/reader')
          prio_client.reindex_locks if prio_client.config['lock_index_enabled']

          prio_client.clear_dead_requests(dead_ttl: 30_000, by_priority:)
          expect(redis.call('ZRANGE', 'rql:lock_queue:prio.inf', '0', '-1')).to eq(
            ['rql:acq:1/2/3/4/last']
          )
          expect(redis.call('EXISTS', 'rql:lock_read_queue:prio.inf')).to eq(0)
          prio_client.unlock('prio.inf')
        end
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
        expect(prio_client.lock('prio.inf', rw_mode: :read, retry_count: 1)).to obtained
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
          high_client.lock('prio.info', rw_mode: :read, retry_count: nil, timeout: 20) {}
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

    specify 'the priority name of the default priority is checked by the configuration' do
      # NOTE: a priority name of `config['default_lock_priority']` must be a key of
      #   `config['lock_priorities']`: checked once after a configuration block (the keys can be
      #   assigned in any order) and on a direct assignment (before the value is applied);
      default_names = { lowest: -100, low: -50, normal: 0, high: 50, highest: 100 }
      unknown_name = lambda do |name|
        "The priority name :#{name} of the 'default_lock_priority' config key is not a key of " \
          "the 'lock_priorities' config key"
      end
      high_client = lambda do
        RedisQueuedLocks::Client.new(redis) { |config| config['default_lock_priority'] = :high }
      end

      aggregate_failures 'a configuration block: any order of the keys' do
        client = RedisQueuedLocks::Client.new(redis) do |config|
          config['default_lock_priority'] = :payment
          config['lock_priorities'] = config['lock_priorities'].merge(payment: 90)
        end
        expect(client.config['default_lock_priority']).to eq(:payment)

        # NOTE: the priority names and the default priority name are replaced together
        client.configure do |config|
          config['lock_priorities'] = { urgent: 100 }
          config['default_lock_priority'] = :urgent
        end
        expect(client.config['lock_priorities']).to eq({ urgent: 100 })
        expect(client.config['default_lock_priority']).to eq(:urgent)

        expect do
          RedisQueuedLocks::Client.new(redis) { |config| config['default_lock_priority'] = :urgent }
        end.to raise_error(
          RedisQueuedLocks::ConfigValidationError,
          "#{unknown_name.call(:urgent)} (:lowest, :low, :normal, :high, :highest)."
        )
      end

      aggregate_failures 'a failed configuration block: the priority keys keep their values' do
        client = high_client.call
        expect do
          client.configure { |config| config['lock_priorities'] = { payment: 90 } }
        end.to raise_error(
          RedisQueuedLocks::ConfigValidationError, "#{unknown_name.call(:high)} (:payment)."
        )
        expect(client.config['lock_priorities']).to eq(default_names)
        expect(client.config['default_lock_priority']).to eq(:high)

        # NOTE: a failed block (its own error) never leaves an inconsistent pair either
        expect do
          client.configure do |config|
            config['lock_priorities'] = { payment: 90 }
            config['retry_count'] = -1
          end
        end.to raise_error(RedisQueuedLocks::ConfigValidationError, /'retry_count'/)
        expect(client.config['lock_priorities']).to eq(default_names)
        expect(client.config['default_lock_priority']).to eq(:high)
      end

      aggregate_failures 'a direct assignment: checked before the value is applied' do
        client = high_client.call
        expect { client.config['default_lock_priority'] = :urgent }.to raise_error(
          RedisQueuedLocks::ConfigValidationError, /\A#{unknown_name.call(:urgent)} /
        )
        expect(client.config['default_lock_priority']).to eq(:high)
        expect { client.config['lock_priorities'] = { payment: 90 } }.to raise_error(
          RedisQueuedLocks::ConfigValidationError, /\A#{unknown_name.call(:high)} /
        )
        expect(client.config['lock_priorities']).to eq(default_names)

        # NOTE: an Integer default priority does not depend on the priority names
        client.config['default_lock_priority'] = 10
        client.config['lock_priorities'] = { payment: 90 }
        expect(client.config['lock_priorities']).to eq({ payment: 90 })
      end
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
          event: 'redis_queued_locks.lock_series_intermediate_lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.a', priority: 1)
        }),
        match({
          event: 'redis_queued_locks.lock_series_lock_obtained',
          payload: hash_including(lock_key: 'rql:lock:prio.events.b', priority: 1)
        }),
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
          '[redis_queued_locks.lock_series_intermediate_lock_obtained]',
          "lock_key => 'rql:lock:prio.events.c'",
          "rw_mode => 'write' priority => -50 acq_time => "
        ),
        a_string_including(
          '[redis_queued_locks.lock_series_lock_obtained]',
          "lock_key => 'rql:lock:prio.events.c'",
          "rw_mode => 'write' priority => -50 acq_time => "
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
          client.lock('prio.trylog', rw_mode: :read, retry_count: 1)
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

        holder_client.lock('prio.trylog', ttl: 10_000, rw_mode: :read)
        expect(client.lock('prio.trylog', priority: 7, retry_count: 1)).to match(failed_attempt)
        expect(try_logs.call('exit__read_lock_still_obtained')).to include(
          a_string_including(
            "first_acq_id_in_queue => '#{client.current_acquirer_id}' first_priority_in_queue => 7"
          )
        )
        holder_client.unlock('prio.trylog')
      end

      aggregate_failures 'no first request: the missing priority is logged as nil' do
        # NOTE: the queue can be empty when the heads are read (the own request is dropped by
        #   `#unlock`/`#clear_locks` or the zombie flusher right after the queueing): the visitor
        #   is called directly (the race can not be reproduced by a lock acquirement)
        RedisQueuedLocks::Acquirer::AcquireLock::TryToLock::LogVisitor.get_first_from_queue(
          test_logger, true, true, 'rql:lock:prio.trylog', 15, 'rql:acq:1/2/3/4/empty',
          'rql:hst:1/2/4/empty', :queued, :write, nil, nil
        )
        expect(try_logs.call('get_first_from_queue').last).to end_with(
          "first_acq_id_in_queue => '' first_priority_in_queue => nil"
        )
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
          client.lock('rw.shared', rw_mode: :read, ttl: 10_000) do
            mark.call(:"reader#{index}_in")
            sleep(0.5)
            mark.call(:"reader#{index}_out")
          end
        end
      end
      sleep(0.2) # NOTE: give a timespot to readers to obtain the lock
      writer = Thread.new do
        client.lock('rw.shared', rw_mode: :write, ttl: 10_000) do
          mark.call(:writer_in)
          sleep(0.3)
          mark.call(:writer_out)
        end
      end
      sleep(0.1) # NOTE: give a timespot to the writer to take its place in the lock queue
      late_reader = Thread.new do
        client.lock('rw.shared', rw_mode: :read, ttl: 10_000) { mark.call(:late_reader_in) }
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
        client.lock('rw.random', rw_mode: :read, ttl: 10_000) do
          sleep(0.6)
          mark.call(:reader_out)
        end
      end
      sleep(0.2) # NOTE: give a timespot to the reader to obtain the lock
      writer = Thread.new do
        client.lock('rw.random', rw_mode: :write, ttl: 10_000) { mark.call(:writer_in) }
      end
      sleep(0.1) # NOTE: give a timespot to the writer to try to obtain the lock
      late_reader = Thread.new do
        client.lock('rw.random', rw_mode: :read, ttl: 10_000) { mark.call(:late_reader_in) }
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
            client.lock('rw.invariant', rw_mode: mode, ttl: 10_000, timeout: 30) do
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
        client.lock('rw.reentrant', rw_mode: :read, ttl: 10_000) do
          result = client.lock(
            'rw.reentrant', rw_mode: :read, ttl: 10_000, conflict_strategy: :work_through
          )
          expect(result).to match({
            ok: true, result: hash_including(process: :conflict_work_through)
          })
          client.lock(
            'rw.reentrant', rw_mode: :read, ttl: 10_000, conflict_strategy: :work_through
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
        client.lock('rw.reentrant', rw_mode: :read, ttl: 5_000) do
          client.lock(
            'rw.reentrant',
            rw_mode: :read,
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
        client.lock('rw.reentrant', rw_mode: :read, ttl: 10_000) do
          expect do
            client.lock!('rw.reentrant', rw_mode: :read, conflict_strategy: :dead_locking)
          end.to raise_error(RedisQueuedLocks::ConflictLockObtainError)
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'write -> read (:work_through): read lock under the obtained write lock' do
        client.lock('rw.reentrant', rw_mode: :write, ttl: 10_000) do
          client.lock(
            'rw.reentrant', rw_mode: :read, conflict_strategy: :work_through
          ) do
            expect(client.lock_info('rw.reentrant')['acq_id']).to eq(client.current_acquirer_id)
          end
          # NOTE: the inner block does not release the outer write lock
          expect(client.lock_info('rw.reentrant')['acq_id']).to eq(client.current_acquirer_id)
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'read -> write (lock upgrade) fails for non-waiting conflict strategies' do
        client.lock('rw.reentrant', rw_mode: :read, ttl: 10_000) do
          %i[work_through extendable_work_through].each do |strategy|
            expect(
              client.lock('rw.reentrant', rw_mode: :write, conflict_strategy: strategy)
            ).to match({ ok: false, result: :conflict_lock_upgrade })
            expect do
              client.lock!('rw.reentrant', rw_mode: :write, conflict_strategy: strategy)
            end.to raise_error(RedisQueuedLocks::ConflictLockObtainError, /upgrade/)
          end
          expect(
            client.lock('rw.reentrant', rw_mode: :write, conflict_strategy: :dead_locking)
          ).to match({ ok: false, result: :conflict_dead_lock })
          expect(client.queued?('rw.reentrant')).to eq(false)
        end
        expect(client.locked?('rw.reentrant')).to eq(false)
      end

      aggregate_failures 'read -> write (:wait_for_lock): waits for its own read lock expiration' do
        client.lock('rw.reentrant', rw_mode: :read, ttl: 400)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.lock(
          'rw.reentrant',
          rw_mode: :write,
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
        holder = Thread.new { client.lock('rw.ff', rw_mode: mode, ttl: 10_000) }
        holders << holder
        holder.value
      end

      take.call(:write)
      expect(client.lock('rw.ff', rw_mode: :read, fail_fast: true)).to match({
        ok: false, result: :fail_fast_no_try
      })
      expect do
        client.lock!('rw.ff', rw_mode: :read, fail_fast: true)
      end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
      client.unlock('rw.ff')

      take.call(:read)
      expect(client.lock('rw.ff', rw_mode: :write, fail_fast: true)).to match({
        ok: false, result: :fail_fast_no_try
      })
      expect do
        client.lock!('rw.ff', rw_mode: :write, fail_fast: true)
      end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
      expect(client.lock('rw.ff', rw_mode: :read, ttl: 10_000, fail_fast: true)).to match({
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
        Thread.new { client.lock('rw.expired', rw_mode: :read, ttl: [300, 1_000][index]) }
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
        result = client.lock('rw.expired', rw_mode: :write, ttl: 10_000, retry_count: nil)
        waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(waited).to be < 2
        client.unlock('rw.expired')
      end

      aggregate_failures 'dead write lock request does not block readers' do
        redis.call('ZADD', 'rql:lock_queue:rw.dead', Time.now.to_f - 60, 'rql:acq:1/2/3/4/dead')
        result = client.lock('rw.dead', rw_mode: :read, queue_ttl: 5, retry_count: 1)
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(redis.call('EXISTS', 'rql:lock_queue:rw.dead')).to eq(0)
        client.unlock('rw.dead')
      end

      aggregate_failures 'dead read lock request does not block writers' do
        redis.call(
          'ZADD', 'rql:lock_read_queue:rw.dead', Time.now.to_f - 60, 'rql:acq:1/2/3/4/dead'
        )
        result = client.lock('rw.dead', rw_mode: :write, queue_ttl: 5, retry_count: 1)
        expect(result).to match({ ok: true, result: hash_including(process: :lock_obtaining) })
        expect(redis.call('EXISTS', 'rql:lock_read_queue:rw.dead')).to eq(0)
        client.unlock('rw.dead')
      end
    end

    specify 'read lock request is dequeued on timeout' do
      client = RedisQueuedLocks::Client.new(redis)
      holder = Thread.new { client.lock('rw.timeout', rw_mode: :write, ttl: 10_000) }
      holder.join

      result = client.lock('rw.timeout', rw_mode: :read, timeout: 1, retry_count: nil)
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
      reader = Thread.new { client.lock('rw.info', rw_mode: :read, ttl: 10_000) }
      reader.join
      writer = Thread.new do
        client.lock('rw.info', rw_mode: :write, ttl: 10_000, timeout: 10) { :written }
      end
      sleep(0.2) # NOTE: give a timespot to the writer to take its place in the lock queue
      late_reader = Thread.new do
        client.lock('rw.info', rw_mode: :read, ttl: 10_000, timeout: 10) { :read }
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
        client.lock('rw.clear', rw_mode: :read, ttl: 10_000)
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
        client.lock('rw.clear', rw_mode: :read, ttl: 10_000)
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

      client.lock('rw.zombie', rw_mode: :read, ttl: 500_000)
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
        client.lock('rw.zombie.read', rw_mode: :read, ttl: 500_000)
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
      lock_pipelines = lambda do |rw_mode, conflict_strategy, priority = 0|
        pipelines.clear
        client.lock('rw.pipeline', rw_mode:, conflict_strategy:, priority:, ttl: 10_000) {}
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
            readers_client.lock('rw.unlock', rw_mode: :read, ttl: 10_000)
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
      read_locks.each { |lock_name| client.lock(lock_name, rw_mode: :read, ttl: 60_000) }
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
        #   the rest; all lock requests are read (default) or the first request of each priority
        [false, true].each do |by_priority|
          queues.each { |lock_queue| redis.call('ZADD', lock_queue, now - 60, dead_acquirer) }
          expect(
            client.clear_dead_requests(dead_ttl: 30_000, scan_size: 4, by_priority:)
          ).to match({
            ok: true,
            result: match({ processed_queues: contain_exactly(*queues) })
          })
          queues.each do |lock_queue|
            expect(redis.call('ZRANGE', lock_queue, '0', '-1')).to contain_exactly(
              live_acquirer, acquirer_id
            )
          end
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
        client.lock('scan.r.0', rw_mode: :read, ttl: 60_000)
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
          client.lock("zombie.batch.r.#{index}", rw_mode: :read, ttl: 500_000)
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
              rw_mode: :read,
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
        client.lock('rw.meta', rw_mode: :read, ttl: 10_000, meta: { 'kek' => 'pek' }) do
          client.lock('rw.meta', rw_mode: :read, conflict_strategy: :work_through) { 1 }
          client.lock(
            'rw.meta',
            rw_mode: :read,
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
              rw_mode: :read,
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
          client.lock('rw.series.b', rw_mode: :write, ttl: 10_000) { mark.call(:writer_in) }
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
        holder = Thread.new { client.lock('rw.series.c', rw_mode: :write, ttl: 10_000) }
        holder.join

        expect do
          client.lock_series!(
            'rw.series.a', 'rw.series.c', rw_mode: :read, fail_fast: true
          ) { :never }
        end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)
        expect(client.locked?('rw.series.a')).to eq(false)
        client.unlock('rw.series.c')
      end

      aggregate_failures 'reentrant read locks of the lock series are not released by the series' do
        client.lock('rw.series.a', rw_mode: :read, ttl: 10_000) do
          client.lock_series(
            'rw.series.a', 'rw.series.b',
            rw_mode: :read,
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
      other_reader = Thread.new { client.lock('rw.own', rw_mode: :read, ttl: 10_000) }
      other_reader.join
      other_acquirer_id = other_reader.value[:result][:acq_id]
      client.lock('rw.own', rw_mode: :read, ttl: 3_000, meta: { 'kek' => 'pek' })
      own_acquirer_id = client.current_acquirer_id
      read_lock_key = RedisQueuedLocks::Resource.prepare_read_lock_key('rw.own', own_acquirer_id)
      reader_info = lambda do |acquirer_id|
        client.lock_info('rw.own')['readers'].find { |reader| reader['acq_id'] == acquirer_id }
      end

      aggregate_failures 'extend_lock_ttl extends the read lock of the current acquirer only' do
        expect(client.extend_lock_ttl('rw.own', 20_000, rw_mode: :read)).to eq({
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
        expect(client.extend_lock_ttl('rw.own', 1_000, rw_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
      end

      aggregate_failures 'unlock_read releases the read lock of the custom acquirer only' do
        custom_reader = Thread.new { client.lock('rw.custom', rw_mode: :read, ttl: 10_000) }
        custom_reader.join
        custom_acquirer_id = custom_reader.value[:result][:acq_id]
        custom_read_lock_key =
          RedisQueuedLocks::Resource.prepare_read_lock_key('rw.custom', custom_acquirer_id)
        client.lock('rw.custom', rw_mode: :read, ttl: 10_000)

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
        client.lock('rw.expiring', rw_mode: :read, ttl: 100)
        sleep(0.2) # NOTE: the read lock is expired
        expect(client.extend_lock_ttl('rw.expiring', 10_000, rw_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
        expect(client.locked?('rw.expiring')).to eq(false)
      end

      aggregate_failures 'read lock is not extended while the write lock is held' do
        writer = Thread.new { client.lock('rw.written', ttl: 10_000) }
        writer.join
        expect(client.extend_lock_ttl('rw.written', 10_000, rw_mode: :read)).to eq({
          ok: false, result: :async_expire_or_no_lock
        })
        client.unlock('rw.written')
      end

      client.unlock('rw.own')
    end

    specify '#extend_lock_ttl with all_read_locks: true' do
      client = RedisQueuedLocks::Client.new(redis)
      reader_threads = [5_000, 8_000, 100].map do |ttl|
        Thread.new { client.lock('rw.all', rw_mode: :read, ttl:) }
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
          client.extend_lock_ttl('rw.all', 20_000, rw_mode: :read, all_read_locks: true)
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
        expect(client.extend_lock_ttl('rw.all', 1_000, rw_mode: :read)).to eq({
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
          client.extend_lock_ttl('rw.all.none', 1_000, rw_mode: :read, all_read_locks: true)
        ).to eq({ ok: false, result: :async_expire_or_no_lock })

        writer = Thread.new { client.lock('rw.all.written', ttl: 10_000) }
        writer.join
        expect(
          client.extend_lock_ttl(
            'rw.all.written', 1_000, rw_mode: :read, all_read_locks: true
          )
        ).to eq({ ok: false, result: :async_expire_or_no_lock })
      end

      client.unlock('rw.all')
      client.unlock('rw.all.written')
      expect(client.keys).to be_empty
    end

    specify 'read/write lock arguments validation' do
      client = RedisQueuedLocks::Client.new(redis)

      # NOTE: (RBS) invalid values are checked via untyped entry points
      expect do
        RedisQueuedLocks::Acquirer::ExtendLockTTL.extend_lock_ttl(
          redis, 'rw.args', 1_000, :reed, false, client.current_acquirer_id,
          client.config['lock_index_enabled'],
          client.config['logger'], client.config['instrumenter'], nil,
          false, 15, RedisQueuedLocks::Logging::Sampler, false,
          false, 15, RedisQueuedLocks::Instrument::Sampler, false
        )
      end.to raise_error(RedisQueuedLocks::ArgumentError, /rw_mode/)
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
        client.lock('rw.args', rw_mode: :read, meta: { 'acq_id' => 'pek' })
      end.to raise_error(RedisQueuedLocks::ArgumentError, /meta/)
      expect do
        client.lock('rw.args', rw_mode: :read, ttl: 0)
      end.to raise_error(RedisQueuedLocks::ArgumentError, /ttl/)
      # NOTE: (RBS) a type-invalid value (`Client#lock_series` types the mode) can't reach the
      #   runtime validation under the RBS runtime type checks (the hook raises first)
      unless RBS_RUNTIME_TEST
        expect do
          client.lock_series('rw.args.a', 'rw.args.b', rw_mode: :reed)
        end.to raise_error(RedisQueuedLocks::ArgumentError, /rw_mode/)
      end
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

      client.lock('rw.logs', rw_mode: :read) { :ok }

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

      holder = Thread.new { client.lock('rw.logs', rw_mode: :read, ttl: 10_000) }
      holder.join
      test_logger.logs.clear
      client.lock('rw.logs', rw_mode: :write, retry_count: 1)

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
        'rw.logs.series.a', 'rw.logs.series.b', rw_mode: :read, ttl: 5_000
      ) { :ok }

      aggregate_failures 'lock series logs and instrumentation (rw_mode of the series)' do
        expect(test_logger.logs).to include(
          a_string_including(
            '[redis_queued_locks.start_lock_series_obtaining]',
            "lock_keys => '#{series_lock_keys.inspect}' queue_ttl =>",
            "rw_mode => 'read'"
          ),
          a_string_including('[redis_queued_locks.lock_series_obtained]', "rw_mode => 'read'"),
          a_string_including(
            '[redis_queued_locks.lock_series_intermediate_lock_obtained]', "rw_mode => 'read'"
          ),
          a_string_including('[redis_queued_locks.lock_series_lock_obtained]', "rw_mode => 'read'"),
          a_string_including('[redis_queued_locks.expire_lock_series]', "rw_mode => 'read'")
        )
        expect(test_notifier.notifications).to include(
          match({
            event: 'redis_queued_locks.lock_series_intermediate_lock_obtained',
            payload: hash_including(
              lock_key: series_lock_keys.first, lock_keys: series_lock_keys, rw_mode: :read
            )
          }),
          match({
            event: 'redis_queued_locks.lock_series_lock_obtained',
            payload: hash_including(
              lock_key: series_lock_keys.last, lock_keys: series_lock_keys, rw_mode: :read
            )
          }),
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

  describe 'lock auto extension' do
    # NOTE: all locks of these examples have a short ttl and the blocks of code are longer than it:
    #   a lock without the auto extension is expired in the middle of the block;
    let(:notifier) do
      Class.new do
        attr_reader :notifications

        def initialize
          @notifications = []
        end

        def notify(event, payload = {})
          notifications << [event, payload]
        end

        def events(name)
          notifications.filter_map do |event, payload|
            payload if event == "redis_queued_locks.#{name}"
          end
        end
      end.new
    end
    let(:logger) do
      Class.new do
        attr_reader :logs

        def initialize
          @logs = []
        end

        def debug(progname = nil, &block)
          logs << (block ? yield : progname)
        end
      end.new
    end
    let(:wait_until) do
      lambda do |timeout = 5, &condition|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until condition.call
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep(0.005)
        end
        condition.call
      end
    end
    let(:pttl) { -> (lock_name) { redis.call('PTTL', "rql:lock:#{lock_name}") } }

    specify 'write lock: the block of code longer than the ttl keeps the lock' do
      client = RedisQueuedLocks::Client.new(redis)
      other_client = RedisQueuedLocks::Client.new(redis)
      lock_pttls = []
      other_results = []

      result = client.lock('auto.write', ttl: 600, auto_extend: true) do
        15.times do
          sleep(0.1)
          lock_pttls << pttl.call('auto.write')
          other_results << other_client.lock('auto.write', ttl: 100, fail_fast: true)[:ok]
        end
        :block_result
      end

      aggregate_failures do
        expect(result).to eq(:block_result)
        expect(lock_pttls).to all(be_positive)
        expect(lock_pttls).to all(be <= 600)
        expect(other_results).to all(eq(false))
        # NOTE: the lock is released right after the block
        expect(client.locked?('auto.write')).to eq(false)
        expect(client.keys).to be_empty
      end
    end

    specify 'read lock: the block of code longer than the ttl keeps the lock' do
      client = RedisQueuedLocks::Client.new(redis)
      other_client = RedisQueuedLocks::Client.new(redis)
      readers_key = 'rql:lock_readers:auto.read'
      reader_key = "rql:lock_reader:auto.read:#{client.current_acquirer_id}"
      other_results = []
      lock_states = []

      # NOTE: another reader is not affected by the extension and has its own (shorter) lifetime
      other_reader = other_client.lock('auto.read', ttl: 200, rw_mode: :read)

      client.lock('auto.read', ttl: 600, rw_mode: :read, auto_extend: true) do
        15.times do
          sleep(0.1)
          lock_states << [redis.call('PTTL', readers_key), redis.call('PTTL', reader_key)]
          other_results << other_client.lock(
            'auto.read', ttl: 100, fail_fast: true, identity: 'writer'
          )[:ok]
        end
      end

      aggregate_failures do
        expect(other_reader[:ok]).to eq(true)
        expect(lock_states.flatten).to all(be_positive)
        expect(other_results).to all(eq(false))
        expect(client.locked?('auto.read')).to eq(false)
        # NOTE: the expired member of another reader lives till the end of the registry ttl: the
        #   last extension is not a reason to keep the registry longer than the extension ttl;
        expect(wait_until.call(2) { client.keys.empty? }).to eq(true)
      end
    end

    specify 'the block of code shorter than the extension interval: no extensions' do
      commands = []
      recorder = Module.new do
        define_method(:call_pipelined) do |pipeline_commands, redis_config, &block|
          commands.concat(pipeline_commands.map { |command| command.first(2).map(&:to_s) })
          super(pipeline_commands, redis_config, &block)
        end
      end
      client = RedisQueuedLocks::Client.new(
        RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      )

      client.lock('auto.short', ttl: 5_000, auto_extend: true) { sleep(0.05) }

      expect(commands).not_to include(['EVAL', RedisQueuedLocks::LockKeeper::EXTEND_WRITE_LOCK])
    end

    specify 'auto_extend_ttl: the lock lives this time after each extension (not a sum)' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.ext', ttl: 300, auto_extend: true, auto_extend_ttl: 1_500) do
        expect(wait_until.call { pttl.call('auto.ext') > 300 }).to eq(true)
        expect(pttl.call('auto.ext')).to be_between(800, 1_500)
        # NOTE: several extensions (each 500 ms): they do not sum up
        sleep(1.2)
        expect(pttl.call('auto.ext')).to be_between(500, 1_500)
      end

      expect(client.locked?('auto.ext')).to eq(false)
    end

    specify 'auto_extend_ttl shorter than the ttl: the lock is not shortened and is kept' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock(
        'auto.short_ext',
        ttl: 1_000,
        auto_extend: true,
        auto_extend_ttl: 300,
        instrumenter: notifier
      ) do
        # NOTE: nothing to extend while the remaining ttl is greater than the extension
        sleep(0.4)
        expect(notifier.events('lock_auto_extended')).to be_empty
        expect(pttl.call('auto.short_ext')).to be_between(300, 1_000)
        sleep(1.1)
        expect(pttl.call('auto.short_ext')).to be_between(1, 300)
      end

      expect(notifier.events('lock_auto_extended')).not_to be_empty
    end

    specify 'max_hold_time: the lock expires by the limit, the next owner keeps its lock' do
      client = RedisQueuedLocks::Client.new(redis)
      other_client = RedisQueuedLocks::Client.new(redis)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # @type var waiter_time: Float
      waiter_time = nil
      block_time = nil

      waiter = Thread.new do
        result = other_client.lock(
          'auto.hold', ttl: 10_000, timeout: 5, retry_count: nil, retry_delay: 5, retry_jitter: 1
        )
        waiter_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        result
      end

      result = client.lock(
        'auto.hold',
        ttl: 300,
        auto_extend: true,
        auto_extend_ttl: 500,
        max_hold_time: 900,
        instrumenter: notifier,
        logger:,
        log_sample_this: true
      ) do
        sleep(1.5)
        block_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        :completed
      end
      released = !client.locked?('auto.hold')

      aggregate_failures do
        # NOTE: the block of code continues to work
        expect(result).to eq(:completed)
        expect(waiter.value).to match(
          { ok: true, result: hash_including(process: :lock_obtaining) }
        )
        # NOTE: an extension does not exceed the limit: the lock lives exactly `max_hold_time`
        expect(waiter_time).to be > 0.8
        expect(waiter_time).to be < block_time
        # NOTE: the release of the lost lock does not touch the lock of the next owner
        expect(released).to eq(false)
        expect(pttl.call('auto.hold')).to be > 8_000
        expect(notifier.events('lock_hold_limit_reached').size).to eq(1)
        expect(notifier.events('lock_hold_limit_reached').first).to match(
          {
            lock_key: 'rql:lock:auto.hold',
            rw_mode: :write,
            max_hold_time: 900,
            acq_id: client.current_acquirer_id,
            hst_id: client.current_host_id,
            at: be_a(Float),
            instrument: nil
          }
        )
        expect(logger.logs).to include(
          a_string_starting_with(
            "[redis_queued_locks.lock_hold_limit_reached] lock_key => 'rql:lock:auto.hold' " \
            "rw_mode => 'write' max_hold_time => 900 "
          )
        )
      end

      client.clear_locks
    end

    specify 'max_hold_time: nil means no limit' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.nolimit', ttl: 300, auto_extend: true, max_hold_time: nil) do
        sleep(0.7)
        expect(client.locked?('auto.nolimit')).to eq(true)
      end

      expect(client.locked?('auto.nolimit')).to eq(false)
    end

    specify 'read lock: max_hold_time' do
      client = RedisQueuedLocks::Client.new(redis)
      other_client = RedisQueuedLocks::Client.new(redis)

      client.lock(
        'auto.read_hold', ttl: 300, rw_mode: :read, auto_extend: true, max_hold_time: 600,
        instrumenter: notifier
      ) do
        # NOTE: a writer waits for the expired read lock
        result = other_client.lock(
          'auto.read_hold', ttl: 100, timeout: 3, retry_count: nil, retry_delay: 5, retry_jitter: 1
        )
        expect(result[:ok]).to eq(true)
        # NOTE: the expired lock can be obtained right before the tick of the keeper
        expect(wait_until.call { notifier.events('lock_hold_limit_reached').any? }).to eq(true)
      end

      expect(notifier.events('lock_hold_limit_reached').map { _1[:rw_mode] }).to eq([:read])
      client.clear_locks
    end

    specify 'a lost lock is reported, the block of code continues, the lock is not revived' do
      client = RedisQueuedLocks::Client.new(redis)

      result = client.lock(
        'auto.lost', ttl: 300, auto_extend: true, instrumenter: notifier, logger:,
        log_sample_this: true, instrument: { custom: :data }
      ) do
        client.unlock('auto.lost')
        expect(wait_until.call { notifier.events('auto_extended_lock_lost').any? }).to eq(true)
        expect(client.locked?('auto.lost')).to eq(false)
        :completed
      end

      aggregate_failures do
        expect(result).to eq(:completed)
        expect(notifier.events('auto_extended_lock_lost')).to contain_exactly(
          {
            lock_key: 'rql:lock:auto.lost',
            rw_mode: :write,
            acq_id: client.current_acquirer_id,
            hst_id: client.current_host_id,
            hold_time: be_a(Integer),
            at: be_a(Float),
            instrument: { custom: :data }
          }
        )
        expect(logger.logs).to include(
          a_string_starting_with(
            "[redis_queued_locks.auto_extended_lock_lost] lock_key => 'rql:lock:auto.lost' " \
            "rw_mode => 'write' acq_id => "
          )
        )
      end
    end

    specify 'a lost read lock is reported, an expired read lock is not revived' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock(
        'auto.read_lost', ttl: 300, rw_mode: :read, auto_extend: true, instrumenter: notifier
      ) do
        redis.call('ZREM', 'rql:lock_readers:auto.read_lost', client.current_acquirer_id)
        expect(wait_until.call { notifier.events('auto_extended_lock_lost').any? }).to eq(true)
        expect(redis.call('ZCARD', 'rql:lock_readers:auto.read_lost')).to eq(0)
      end

      expect(notifier.events('auto_extended_lock_lost').map { _1[:rw_mode] }).to eq([:read])
    end

    specify 'the extensions are reported' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock(
        'auto.report', ttl: 300, auto_extend: true, instrumenter: notifier, logger:,
        log_sample_this: true, instr_sample_this: true, instrument: { custom: :data }
      ) do
        expect(wait_until.call { notifier.events('lock_auto_extended').size >= 2 }).to eq(true)
      end

      aggregate_failures do
        expect(notifier.events('lock_auto_extended').first).to match(
          {
            lock_key: 'rql:lock:auto.report',
            rw_mode: :write,
            ext_ttl: 300,
            rem_ttl: be_between(1, 300),
            acq_id: client.current_acquirer_id,
            hst_id: client.current_host_id,
            at: be_a(Float),
            instrument: { custom: :data }
          }
        )
        expect(logger.logs).to include(
          a_string_starting_with(
            "[redis_queued_locks.lock_auto_extended] lock_key => 'rql:lock:auto.report' " \
            "rw_mode => 'write' ext_ttl => 300 rem_ttl => "
          )
        )
      end
    end

    specify 'timed: the block of code is interrupted when the lock is lost' do
      client = RedisQueuedLocks::Client.new(redis)
      swallowed = false

      aggregate_failures do
        expect do
          client.lock('auto.timed', ttl: 300, auto_extend: true, timed: true) do
            client.unlock('auto.timed')
            # NOTE: `rescue => e` of the block can not swallow the interruption
            begin
              sleep(5)
            rescue StandardError
              swallowed = true
            end
          end
        end.to raise_error(RedisQueuedLocks::TimedBlockLostLockError, /is lost.*auto\.timed/)
        expect(swallowed).to eq(false)
        expect(client.locked?('auto.timed')).to eq(false)
      end
    end

    specify 'timed: the block of code is limited by max_hold_time instead of the ttl' do
      client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures do
        # NOTE: longer than the ttl, shorter than the limit
        expect(
          client.lock(
            'auto.timed_hold', ttl: 300, auto_extend: true, timed: true, max_hold_time: 3_000
          ) do
            sleep(0.5)
            :completed
          end
        ).to eq(:completed)

        expect do
          client.lock(
            'auto.timed_hold', ttl: 300, auto_extend: true, timed: true, max_hold_time: 600
          ) { sleep(5) }
        end.to raise_error(
          RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError,
          /max hold time.*\(600\).*auto\.timed_hold/
        )
        expect(client.locked?('auto.timed_hold')).to eq(false)
      end
    end

    specify 'timed: max_hold_time: nil means no time limit' do
      client = RedisQueuedLocks::Client.new(redis)

      expect(
        client.lock(
          'auto.timed_nolimit', ttl: 300, auto_extend: true, timed: true, max_hold_time: nil
        ) do
          sleep(0.5)
          :completed
        end
      ).to eq(:completed)
    end

    specify 'timed: the block of code without the budget of the hold limit is not invoked' do
      client = RedisQueuedLocks::Client.new(redis)
      invoked = false

      expect do
        client.lock('auto.no_budget', ttl: 1, auto_extend: true, timed: true, max_hold_time: 1) do
          invoked = true
        end
      end.to raise_error(RedisQueuedLocks::LockTtlTimeBudgetIsSpentError)
      expect(invoked).to eq(false)
    end

    specify 'timed: the lock is lost before the block of code: the block is not invoked' do
      client = RedisQueuedLocks::Client.new(redis)
      invoked = false

      # NOTE: the lock is found as a lost one between the obtaining and the block of code: an
      #   interruption at this moment is out of the `rescue` scope of the block;
      allow(client.lock_keeper).to receive(:interrupt_timed_block).and_wrap_original do |arm, lease|
        redis.call('DEL', 'rql:lock:auto.before')
        expect(wait_until.call { lease.lost? }).to eq(true)
        arm.call(lease)
      end

      expect do
        client.lock('auto.before', ttl: 300, auto_extend: true, timed: true) { invoked = true }
      end.to raise_error(RedisQueuedLocks::TimedBlockLostLockError)
      expect(invoked).to eq(false)
    end

    specify 'a lock without the expiration is not a lost lock' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.persist', ttl: 300, auto_extend: true, instrumenter: notifier) do
        redis.call('PERSIST', 'rql:lock:auto.persist')
        notifier.notifications.clear
        expect(wait_until.call { notifier.events('lock_auto_extended').any? }).to eq(true)
      end

      aggregate_failures do
        expect(notifier.events('lock_auto_extended').first[:rem_ttl]).to eq(-1)
        expect(notifier.events('auto_extended_lock_lost')).to be_empty
      end
    end

    specify 'timed: the blocks of a non-blocking fiber without a scheduler are not interrupted' do
      client = RedisQueuedLocks::Client.new(redis)
      result = nil

      Fiber.new(blocking: false) do
        result = client.lock(
          'auto.fiber', ttl: 300, auto_extend: true, timed: true, instrumenter: notifier,
          max_hold_time: nil
        ) do
          client.unlock('auto.fiber')
          wait_until.call { notifier.events('auto_extended_lock_lost').any? }
          :completed
        end
      end.resume

      expect(result).to eq(:completed)
      expect(notifier.events('auto_extended_lock_lost').size).to eq(1)
    end

    specify 'timed: a fiber scheduler task is interrupted through its scheduler (a lost lock)' do
      client = RedisQueuedLocks::Client.new(redis)
      continued = false
      other_ticks = 0
      raised_error = nil

      Sync do |task|
        # NOTE: another task of the same thread is not interrupted
        other_task = task.async do
          20.times do
            sleep(0.01)
            other_ticks += 1
          end
        end

        begin
          # NOTE: no hold limit (no `Timeout`): the lost lock interrupts the block
          client.lock(
            'auto.fiber_scheduler', ttl: 300, auto_extend: true, timed: true, max_hold_time: nil,
            instrumenter: notifier
          ) do
            client.unlock('auto.fiber_scheduler')
            sleep(3)
            continued = true
          end
        rescue RedisQueuedLocks::TimedLockTimeoutError => error
          raised_error = error
        end

        other_task.wait
      end

      aggregate_failures do
        expect(raised_error).to be_a(RedisQueuedLocks::TimedBlockLostLockError)
        expect(continued).to eq(false)
        expect(other_ticks).to eq(20)
        expect(notifier.events('auto_extended_lock_lost').size).to eq(1)
      end
    end

    specify 'timed: an interruption at the end of a block of a fiber scheduler task stays in it' do
      client = RedisQueuedLocks::Client.new(redis)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      raised_error = nil
      waited = nil
      after_lock = false

      Sync do
        block_end = clock.call

        begin
          client.lock('auto.fiber_end', ttl: 300, auto_extend: true, timed: true) do |lease|
            redis.call('DEL', 'rql:lock:auto.fiber_end')
            # NOTE: the keeper finds the lost lock while the block does not suspend (`Thread.pass`
            #   gives the GVL, not the control to the scheduler): the interruption is sent right
            #   before the end of the block and has to come in `#forget`, not after the block
            deadline = clock.call + 3
            Thread.pass until lease.lost? || clock.call > deadline
            block_end = clock.call
            :completed
          end
        rescue RedisQueuedLocks::TimedLockTimeoutError => error
          raised_error = error
          waited = clock.call - block_end
        end

        # NOTE: nothing comes after the block of code
        sleep(0.3)
        after_lock = true
      end

      aggregate_failures do
        expect(raised_error).to be_a(RedisQueuedLocks::TimedBlockLostLockError)
        # NOTE: the interruption has come before the timeout of the wait
        expect(waited).to be < 0.5
        expect(after_lock).to eq(true)
      end
    end

    specify 'timed: a failed interruption of the fiber scheduler: the loss is reported only' do
      client = RedisQueuedLocks::Client.new(redis)
      result = nil
      elapsed = nil

      Sync do
        allow(Fiber.scheduler).to receive(:fiber_interrupt).and_raise(IOError, 'closed scheduler')
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        result = client.lock(
          'auto.fiber_failed', ttl: 300, auto_extend: true, timed: true, max_hold_time: nil,
          instrumenter: notifier
        ) do
          client.unlock('auto.fiber_failed')
          wait_until.call { notifier.events('auto_extended_lock_lost').any? }
          :completed
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      aggregate_failures do
        expect(result).to eq(:completed)
        expect(notifier.events('auto_extended_lock_lost').size).to eq(1)
        # NOTE: nothing is pending: the end of the block does not wait for an interruption
        expect(elapsed).to be < 0.9
        expect(client.lock_keeper.thread&.alive?).to eq(true)
      end
    end

    specify 'timed: an interruption that the scheduler never raises is not waited for forever' do
      client = RedisQueuedLocks::Client.new(redis)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      result = nil
      waited = nil

      Sync do
        # NOTE: the scheduler takes the interruption and never raises it
        allow(Fiber.scheduler).to receive(:fiber_interrupt).and_return(nil)
        block_end = clock.call

        result = client.lock(
          'auto.fiber_lost_interruption', ttl: 300, auto_extend: true, timed: true
        ) do |lease|
          redis.call('DEL', 'rql:lock:auto.fiber_lost_interruption')
          deadline = clock.call + 3
          Thread.pass until lease.lost? || clock.call > deadline
          block_end = clock.call
          :completed
        end
        waited = clock.call - block_end
      end

      aggregate_failures do
        expect(result).to eq(:completed)
        # NOTE: `LockKeeper::FIBER_INTERRUPTION_TIMEOUT`
        expect(waited).to be_between(0.9, 2.0)
      end
    end

    specify 'reentrant locks: the lease of the block does not depend on the nested locks' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock(
        'auto.reentrant', ttl: 600, auto_extend: true, conflict_strategy: :extendable_work_through
      ) do
        # NOTE: the nested extension is taken back after the nested block
        client.lock(
          'auto.reentrant', ttl: 5_000, conflict_strategy: :extendable_work_through
        ) do
          expect(pttl.call('auto.reentrant')).to be > 5_000
          sleep(0.05)
        end
        expect(pttl.call('auto.reentrant')).to be <= 700

        # NOTE: the nested block does not release the lock
        client.lock('auto.reentrant', ttl: 600, conflict_strategy: :work_through) { sleep(0.05) }

        # NOTE: the next extensions do not wait for the taken back ttl
        sleep(1.0)
        expect(pttl.call('auto.reentrant')).to be_between(1, 600)
      end

      expect(client.locked?('auto.reentrant')).to eq(false)
    end

    specify 'reentrant locks: a nested block keeps the lock of the outer logic alive' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.nested', ttl: 400, conflict_strategy: :work_through) do
        client.lock('auto.nested', ttl: 400, conflict_strategy: :work_through, auto_extend: true) do
          sleep(0.8)
          expect(client.locked?('auto.nested')).to eq(true)
        end

        # NOTE: the lock of the outer logic is not released by the nested block
        expect(client.locked?('auto.nested')).to eq(true)
      end

      expect(client.locked?('auto.nested')).to eq(false)
    end

    specify 'reentrant locks: a read request under the own write lock extends the write lock' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.held', ttl: 400, conflict_strategy: :work_through) do
        client.lock(
          'auto.held', ttl: 400, rw_mode: :read, conflict_strategy: :work_through, auto_extend: true
        ) do
          sleep(0.8)
          expect(pttl.call('auto.held')).to be_positive
          expect(redis.call('EXISTS', 'rql:lock_readers:auto.held')).to eq(0)
        end
      end

      expect(client.locked?('auto.held')).to eq(false)
    end

    specify 'reentrant locks: the ttl of the next owner is not decreased by a lost lock' do
      client = RedisQueuedLocks::Client.new(redis)
      other_client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.next', ttl: 600, conflict_strategy: :extendable_work_through) do
        client.lock(
          'auto.next', ttl: 600, conflict_strategy: :extendable_work_through, auto_extend: true
        ) do
          client.unlock('auto.next')
          other_client.lock('auto.next', ttl: 10_000)
        end

        expect(pttl.call('auto.next')).to be > 9_000
        redis.call('DEL', 'rql:lock:auto.next')
      end
    end

    specify '#lock_series: all locks of the series are kept' do
      %i[write read].each do |rw_mode|
        client = RedisQueuedLocks::Client.new(redis)
        other_client = RedisQueuedLocks::Client.new(redis)
        lock_names = ["auto.series.#{rw_mode}.1", "auto.series.#{rw_mode}.2"]
        other_results = []

        result = client.lock_series(*lock_names, ttl: 600, rw_mode:, auto_extend: true) do
          10.times do
            sleep(0.1)
            lock_names.each do |lock_name|
              other_results << other_client.lock(
                lock_name, ttl: 100, fail_fast: true, identity: 'other'
              )[:ok]
            end
          end
          :block_result
        end

        aggregate_failures do
          expect(result).to eq(:block_result)
          expect(other_results).to all(eq(false))
          expect(lock_names.map { client.locked?(_1) }).to all(eq(false))
          expect(client.keys).to be_empty
        end
      end
    end

    specify '#lock_series: a lost lock does not stop the extension of other locks' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock_series(
        'auto.partial.1', 'auto.partial.2', ttl: 600, auto_extend: true, instrumenter: notifier
      ) do
        client.unlock('auto.partial.2')
        expect(wait_until.call { notifier.events('auto_extended_lock_lost').any? }).to eq(true)
        sleep(0.8)
        expect(client.locked?('auto.partial.1')).to eq(true)
        expect(client.locked?('auto.partial.2')).to eq(false)
      end

      aggregate_failures do
        expect(notifier.events('auto_extended_lock_lost').map { _1[:lock_key] }).to eq(
          ['rql:lock:auto.partial.2']
        )
        expect(client.keys).to be_empty
      end
    end

    specify '#lock_series: the lost lock is not reported again' do
      failing = { enabled: false }
      failing_middleware = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if failing[:enabled] && commands.first[0].to_s == 'EVAL'
            raise(RedisClient::ConnectionError, 'failed extension')
          end

          super(commands, redis_config, &block)
        end
      end
      client = RedisQueuedLocks::Client.new(
        RedisClient.config(db: 0, middlewares: [failing_middleware]).new_pool(timeout: 5)
      )

      client.lock_series(
        'auto.again.1', 'auto.again.2',
        ttl: 300, auto_extend: true, max_hold_time: 900, instrumenter: notifier
      ) do
        client.unlock('auto.again.2')
        expect(wait_until.call { notifier.events('auto_extended_lock_lost').any? }).to eq(true)
        failing[:enabled] = true
        expect(wait_until.call { notifier.events('lock_auto_extension_failed').any? }).to eq(true)
        failing[:enabled] = false
        expect(wait_until.call { notifier.events('lock_hold_limit_reached').any? }).to eq(true)
      end

      aggregate_failures do
        expect(notifier.events('lock_auto_extension_failed').map { _1[:lock_key] }.uniq).to eq(
          ['rql:lock:auto.again.1']
        )
        expect(notifier.events('lock_hold_limit_reached').map { _1[:lock_key] }).to eq(
          ['rql:lock:auto.again.1']
        )
      end
    end

    specify '#lock_series: timed: the block of code is interrupted once' do
      client = RedisQueuedLocks::Client.new(redis)

      # NOTE: both locks are lost by the same tick of the keeper
      expect do
        client.lock_series(
          'auto.once.1', 'auto.once.2', ttl: 300, auto_extend: true, timed: true
        ) do
          client.unlock('auto.once.1')
          client.unlock('auto.once.2')
          sleep(5)
        end
      end.to raise_error(RedisQueuedLocks::TimedBlockLostLockError)
    end

    specify '#lock_series: max_hold_time' do
      client = RedisQueuedLocks::Client.new(redis)

      expect do
        client.lock_series(
          'auto.series_hold.1', 'auto.series_hold.2',
          ttl: 300, auto_extend: true, timed: true, max_hold_time: 600
        ) { sleep(5) }
      end.to raise_error(RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError)
    end

    specify '#lock_series: a reentrant lock of the series keeps working' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.series_reentrant', ttl: 400) do
        client.lock_series(
          'auto.series_reentrant', 'auto.series_new',
          ttl: 400, auto_extend: true, conflict_strategy: :work_through
        ) do
          sleep(0.8)
          expect(client.locked?('auto.series_reentrant')).to eq(true)
          expect(client.locked?('auto.series_new')).to eq(true)
        end

        # NOTE: the reentrant lock is not released by the series
        expect(client.locked?('auto.series_reentrant')).to eq(true)
        expect(client.locked?('auto.series_new')).to eq(false)
      end
    end

    specify 'the bang methods support the auto extension' do
      client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures do
        expect(
          client.lock!(
            'auto.bang', ttl: 300, auto_extend: true, auto_extend_ttl: 300, max_hold_time: 5_000
          ) do
            sleep(0.5)
            client.locked?('auto.bang')
          end
        ).to eq(true)
        expect(
          client.lock_series!(
            'auto.bang', ttl: 300, auto_extend: true, auto_extend_ttl: 300, max_hold_time: 5_000
          ) do
            sleep(0.5)
            client.locked?('auto.bang')
          end
        ).to eq(true)
      end
    end

    describe 'the lease of the block of code (LockLease)' do
      let(:observer) { RedisQueuedLocks::Client.new(redis) }

      specify 'the block of code gets its lease only when it takes an argument' do
        client = RedisQueuedLocks::Client.new(redis)
        arguments = []

        client.lock('lease.args', ttl: 300, auto_extend: true) do |*args|
          arguments << args.map(&:class)
        end
        client.lock('lease.args', ttl: 300, auto_extend: true) { arguments << :no_arguments }
        # NOTE: rbs/test wraps the blocks of the checked methods (the arity of a lambda is lost)
        unless RBS_RUNTIME_TEST
          client.lock('lease.args', ttl: 300, auto_extend: true, &-> { arguments << :lambda })
        end
        client.lock('lease.args', ttl: 300) { |*args| arguments << args }
        client.lock_series('lease.args', 'lease.args2', ttl: 300, auto_extend: true) do |*args|
          arguments << args.map(&:class)
        end

        expect(arguments).to eq(
          [
            [RedisQueuedLocks::LockKeeper::LockLease], :no_arguments,
            *(RBS_RUNTIME_TEST ? [] : [:lambda]), [],
            [RedisQueuedLocks::LockKeeper::LockLease]
          ]
        )
      end

      specify 'hold_for: the lock is kept beyond max_hold_time while the limit is moved' do
        client = RedisQueuedLocks::Client.new(redis)
        results = []
        locked = []

        client.lock('lease.hold', ttl: 300, auto_extend: true, max_hold_time: 400) do |lease|
          6.times do
            sleep(0.2)
            results << lease.hold_for(500)
            locked << observer.locked?('lease.hold')
          end
        end

        aggregate_failures do
          expect(results).to all(eq({ ok: true, result: :extended }))
          expect(locked).to all(eq(true))
          expect(client.locked?('lease.hold')).to eq(false)
        end
      end

      specify 'hold_for: the lock expires at the moved limit when it is not moved anymore' do
        client = RedisQueuedLocks::Client.new(redis)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        client.lock(
          'lease.dead', ttl: 300, auto_extend: true, max_hold_time: 300, instrumenter: notifier
        ) do |lease|
          aggregate_failures do
            expect(lease.hold_for(900)).to eq({ ok: true, result: :extended })
            # NOTE: the old limit is passed, the lock is kept by the moved one
            sleep(0.6)
            expect(observer.locked?('lease.dead')).to eq(true)
            # NOTE: a stuck block of code: the lock expires at the moved limit
            expect(wait_until.call(3) { !observer.locked?('lease.dead') }).to eq(true)
            expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
              .to be_between(0.85, 3.0)
            expect(wait_until.call { notifier.events('lock_hold_limit_reached').any? }).to eq(true)
            expect(lease.hold_for(1_000)).to eq({ ok: false, result: :hold_limit_reached })
            expect(lease.hold_time_left).to eq(0)
          end
        end
      end

      specify 'hold_for: the time is counted from now, the limit never moves back' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock('lease.from_now', ttl: 300, auto_extend: true, max_hold_time: 300) do |lease|
          aggregate_failures do
            lease.hold_for(5_000)
            expect(lease.hold_time_left).to be_between(4_500, 5_000)
            # NOTE: a shorter time does not move the limit back
            lease.hold_for(1_000)
            expect(lease.hold_time_left).to be_between(4_500, 5_000)
            # NOTE: the calls are not summed up
            3.times { lease.hold_for(6_000) }
            expect(lease.hold_time_left).to be_between(5_500, 6_000)
          end
        end
      end

      specify 'hold_for: a tick that found the old limit reached does not stop the moved one' do
        client = RedisQueuedLocks::Client.new(redis)
        moved = false

        # NOTE: the first tick finds the limit reached while the lock is alive (at the real limit
        #   the lock expires: the last extensions are shortened to it)...
        allow(client.lock_keeper).to receive(:keep).and_wrap_original do |keep, *arguments|
          keep.call(*arguments).tap do |lease|
            forced = false
            allow(lease).to receive(:hold_limit_reached?).and_wrap_original do |check, time|
              next check.call(time) if forced

              forced = true
            end
          end
        end
        # NOTE: ...and the limit is moved between this check and the stop of the lease
        allow(client.lock_keeper).to receive(:stop_hold).and_wrap_original do |stop, lease, time|
          unless moved
            client.lock_keeper.hold_for(redis, lease, 600)
            moved = true
          end
          stop.call(lease, time)
        end

        client.lock(
          'lease.race', ttl: 300, auto_extend: true, max_hold_time: 300, instrumenter: notifier
        ) do
          aggregate_failures do
            expect(wait_until.call { moved }).to eq(true)
            # NOTE: the old limit is passed: the moved one keeps the lock
            sleep(0.4)
            expect(observer.locked?('lease.race')).to eq(true)
            expect(notifier.events('lock_hold_limit_reached')).to be_empty
            expect(wait_until.call(3) { notifier.events('lock_hold_limit_reached').any? })
              .to eq(true)
          end
        end
      end

      specify 'hold_for: a lost lock is reported once and is not revived' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock('lease.lost', ttl: 300, auto_extend: true, instrumenter: notifier) do |lease|
          redis.call('DEL', 'rql:lock:lease.lost')

          aggregate_failures do
            # NOTE: the keeper can find the lost lock first: the same result
            expect(lease.hold_for(1_000)).to eq({ ok: false, result: :lock_lost })
            expect(lease.lost?).to eq(true)
            expect(lease.hold_for(1_000)).to eq({ ok: false, result: :lock_lost })
            sleep(0.3)
            expect(notifier.events('auto_extended_lock_lost').size).to eq(1)
            expect(observer.locked?('lease.lost')).to eq(false)
          end
        end
      end

      specify 'hold_for: the lease of a completed block of code' do
        client = RedisQueuedLocks::Client.new(redis)
        kept_lease = nil

        client.lock('lease.done', ttl: 300, auto_extend: true) { |lease| kept_lease = lease }

        aggregate_failures do
          expect(kept_lease.hold_for(1_000)).to eq({ ok: false, result: :released })
          expect(client.locked?('lease.done')).to eq(false)
        end
      end

      specify 'hold_for: max_hold_time: nil (no limit)' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock('lease.no_limit', ttl: 300, auto_extend: true, max_hold_time: nil) do |lease|
          aggregate_failures do
            expect(lease.hold_time_left).to eq(nil)
            expect(lease.hold_for(1_000)).to eq({ ok: true, result: :extended })
            expect(lease.hold_time_left).to eq(nil)
          end
        end
      end

      specify 'hold_for: invalid values' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock('lease.invalid', ttl: 300, auto_extend: true) do |lease|
          aggregate_failures do
            expect { lease.hold_for(0) }.to raise_error(
              RedisQueuedLocks::ArgumentError, /`hold_time`.*positive Integer.*got 0/
            )
            expect { lease.hold_for(-1) }.to raise_error(RedisQueuedLocks::ArgumentError)
            unless RBS_RUNTIME_TEST
              expect { lease.hold_for(1.5) }.to raise_error(RedisQueuedLocks::ArgumentError)
              expect { lease.hold_for(nil) }.to raise_error(RedisQueuedLocks::ArgumentError)
            end
          end
        end
      end

      specify 'hold_for: the extension is reported' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock(
          'lease.report', ttl: 300, auto_extend: true, auto_extend_ttl: 600, max_hold_time: 300,
          instrumenter: notifier, logger:, log_sample_this: true, instr_sample_this: true,
          instrument: { custom: :data }
        ) { |lease| lease.hold_for(2_000) }

        aggregate_failures do
          expect(notifier.events('lock_hold_limit_extended')).to contain_exactly(
            {
              lock_key: 'rql:lock:lease.report',
              rw_mode: :write,
              hold_time: 2_000,
              rem_hold_time: be_between(1_900, 2_000),
              ext_ttl: 600,
              rem_ttl: be_between(500, 600),
              acq_id: client.current_acquirer_id,
              hst_id: client.current_host_id,
              at: be_a(Float),
              instrument: { custom: :data }
            }
          )
          expect(logger.logs).to include(
            a_string_starting_with(
              "[redis_queued_locks.lock_hold_limit_extended] " \
              "lock_key => 'rql:lock:lease.report' rw_mode => 'write' hold_time => 2000 " \
              "rem_hold_time => "
            )
          )
        end
      end

      specify 'timed: the block of code is interrupted at the moved limit' do
        client = RedisQueuedLocks::Client.new(redis)
        alive_after_old_limit = false

        aggregate_failures do
          expect do
            client.lock(
              'lease.timed', ttl: 300, auto_extend: true, timed: true, max_hold_time: 300
            ) do |lease|
              lease.hold_for(800)
              sleep(0.5)
              alive_after_old_limit = true
              sleep(5)
            end
          end.to raise_error(
            RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError,
            /max hold time.*\(300, moved by the block of code\).*lease\.timed/
          )
          expect(alive_after_old_limit).to eq(true)
          expect(client.locked?('lease.timed')).to eq(false)
        end
      end

      specify 'timed: the hold limit of a fiber without a scheduler is a Timeout (not moved)' do
        client = RedisQueuedLocks::Client.new(redis)
        results = []
        raised_error = nil

        Fiber.new(blocking: false) do
          client.lock(
            'lease.fiber', ttl: 300, auto_extend: true, timed: true, max_hold_time: 600
          ) do |lease|
            results << lease.class << lease.hold_for(2_000)
            sleep(5)
          end
        rescue RedisQueuedLocks::TimedLockTimeoutError => error
          raised_error = error
        end.resume

        aggregate_failures do
          expect(results).to eq(
            [RedisQueuedLocks::LockKeeper::LockLease, { ok: true, result: :extended }]
          )
          # NOTE: the `Timeout` of `max_hold_time`: the moved limit of the keeper does not move it
          expect(raised_error).to be_a(RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError)
          expect(client.locked?('lease.fiber')).to eq(false)
        end
      end

      specify 'timed: a fiber scheduler task is interrupted at the moved limit' do
        client = RedisQueuedLocks::Client.new(redis)
        alive_after_old_limit = false
        raised_error = nil

        Sync do
          client.lock(
            'lease.fiber_scheduler', ttl: 300, auto_extend: true, timed: true, max_hold_time: 300
          ) do |lease|
            lease.hold_for(800)
            sleep(0.5)
            alive_after_old_limit = true
            sleep(5)
          end
        rescue RedisQueuedLocks::TimedLockTimeoutError => error
          raised_error = error
        end

        aggregate_failures do
          expect(raised_error).to be_a(RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError)
          expect(raised_error&.message).to match(/\(300, moved by the block of code\)/)
          expect(alive_after_old_limit).to eq(true)
          expect(client.locked?('lease.fiber_scheduler')).to eq(false)
        end
      end

      specify 'timed: a fiber scheduler without fiber_interrupt keeps the Timeout of the limit' do
        client = RedisQueuedLocks::Client.new(redis)
        results = []
        raised_error = nil

        Sync do
          # NOTE: a scheduler that can not be asked to interrupt a fiber
          Fiber.scheduler.singleton_class.send(:undef_method, :fiber_interrupt)

          client.lock(
            'lease.no_hook', ttl: 300, auto_extend: true, timed: true, max_hold_time: 600
          ) do |lease|
            results << lease.hold_for(2_000)
            sleep(5)
          end
        rescue RedisQueuedLocks::TimedLockTimeoutError => error
          raised_error = error
        end

        aggregate_failures do
          expect(results).to eq([{ ok: true, result: :extended }])
          # NOTE: the `Timeout` of `max_hold_time` (the scheduler implements it) is not moved
          expect(raised_error).to be_a(RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError)
          expect(client.locked?('lease.no_hook')).to eq(false)
        end
      end

      specify 'timed: a lost lock found by hold_for interrupts the block of any fiber' do
        client = RedisQueuedLocks::Client.new(redis)

        # NOTE: no fiber scheduler: the keeper can not interrupt the block; `hold_for` finds the
        #   lost lock by itself (no delay) or after the keeper (the delay is longer than a tick)
        [0, 0.2].each do |delay|
          continued = false
          raised_error = nil

          Fiber.new(blocking: false) do
            client.lock('lease.fiber_lost', ttl: 300, auto_extend: true, timed: true) do |lease|
              redis.call('DEL', 'rql:lock:lease.fiber_lost')
              sleep(delay)
              lease.hold_for(1_000)
              continued = true
            end
          rescue RedisQueuedLocks::TimedLockTimeoutError => error
            raised_error = error
          end.resume

          aggregate_failures do
            expect(raised_error).to be_a(RedisQueuedLocks::TimedBlockLostLockError)
            expect(continued).to eq(false)
          end
        end
      end

      specify 'timed: hold_for of a kept lease after the block of a fiber interrupts nothing' do
        client = RedisQueuedLocks::Client.new(redis)
        kept_lease = nil
        result = nil

        Fiber.new(blocking: false) do
          client.lock('lease.fiber_kept', ttl: 300, auto_extend: true, timed: true) do |lease|
            kept_lease = lease
            redis.call('DEL', 'rql:lock:lease.fiber_kept')
            # NOTE: the keeper can not interrupt the block of code: it only finds the lost lock
            wait_until.call { lease.lost? }
          end
          result = kept_lease.hold_for(1_000)
        end.resume

        expect(result).to eq({ ok: false, result: :lock_lost })
      end

      specify 'timed: a lost lock found by hold_for interrupts the block of code' do
        client = RedisQueuedLocks::Client.new(redis)
        continued = false

        aggregate_failures do
          expect do
            client.lock('lease.timed_lost', ttl: 300, auto_extend: true, timed: true) do |lease|
              redis.call('DEL', 'rql:lock:lease.timed_lost')
              lease.hold_for(1_000)
              continued = true
            end
          end.to raise_error(RedisQueuedLocks::TimedBlockLostLockError)
          expect(continued).to eq(false)
        end
      end

      specify '#lock_series: hold_for keeps all locks of the series' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock_series(
          'lease.series.a', 'lease.series.b', ttl: 300, auto_extend: true, max_hold_time: 300
        ) do |lease|
          aggregate_failures do
            expect(lease.hold_for(900)).to eq({ ok: true, result: :extended })
            sleep(0.6)
            expect(observer.locked?('lease.series.a')).to eq(true)
            expect(observer.locked?('lease.series.b')).to eq(true)
          end
        end

        expect(client.locked?('lease.series.a') || client.locked?('lease.series.b')).to eq(false)
      end

      specify 'read lock: hold_for' do
        client = RedisQueuedLocks::Client.new(redis)

        client.lock(
          'lease.read', ttl: 300, rw_mode: :read, auto_extend: true, max_hold_time: 300
        ) do |lease|
          aggregate_failures do
            expect(lease.hold_for(900)).to eq({ ok: true, result: :extended })
            sleep(0.6)
            # NOTE: the read lock is alive: a writer can not obtain the lock
            expect(observer.lock('lease.read', ttl: 100, fail_fast: true)[:ok]).to eq(false)
          end
        end
      end
    end

    specify 'config: default values of the options' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['is_auto_extended_by_default'] = true
        config['default_auto_extend_ttl'] = 900
        config['default_max_hold_time'] = 600
        config['instrumenter'] = notifier
      end

      expect(RedisQueuedLocks::Config.new['is_auto_extended_by_default']).to eq(false)
      expect(RedisQueuedLocks::Config.new['default_auto_extend_ttl']).to eq(nil)
      expect(RedisQueuedLocks::Config.new['default_max_hold_time']).to eq(3_600_000)

      client.lock('auto.config', ttl: 300) do
        expect(wait_until.call { notifier.events('lock_auto_extended').any? }).to eq(true)
        expect(notifier.events('lock_auto_extended').first[:ext_ttl]).to be_between(1, 900)
        expect(wait_until.call { notifier.events('lock_hold_limit_reached').any? }).to eq(true)
      end
    end

    specify 'config: validations of the values' do
      aggregate_failures do
        [
          ['is_auto_extended_by_default', 1],
          ['default_auto_extend_ttl', 0],
          ['default_auto_extend_ttl', 1.5],
          ['default_max_hold_time', 0],
          ['default_max_hold_time', -1]
        ].each do |config_key, config_value|
          expect do
            RedisQueuedLocks::Client.new(redis) { |config| config[config_key] = config_value }
          end.to raise_error(RedisQueuedLocks::ConfigValidationError)
        end
      end
    end

    specify 'invalid values of the options' do
      client = RedisQueuedLocks::Client.new(redis)

      aggregate_failures do
        [
          -> (kwargs, &block) { client.lock('auto.args', **kwargs, &block) },
          -> (kwargs, &block) { client.lock_series('auto.args', **kwargs, &block) }
        ].each do |lock_method|
          expect { lock_method.call({ auto_extend_ttl: 0 }) }.to raise_error(
            RedisQueuedLocks::ArgumentError, /:auto_extend_ttl/
          )
          expect { lock_method.call({ max_hold_time: 0 }) }.to raise_error(
            RedisQueuedLocks::ArgumentError, /:max_hold_time/
          )
          expect do
            lock_method.call({ ttl: 1_000, auto_extend: true, max_hold_time: 999 }) { :block }
          end.to raise_error(RedisQueuedLocks::ArgumentError, /should not be less than `:ttl`/)
          # NOTE: the hold limit is used by the auto extension of a block of code only
          expect(lock_method.call({ ttl: 1_000, max_hold_time: 999 })).to include(ok: true)
          client.clear_locks
          expect(
            lock_method.call({ ttl: 1_000, auto_extend: true, max_hold_time: 999 })
          ).to include(ok: true)
          client.clear_locks
        end
      end
    end

    specify 'no keeper without the auto extension' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.none', ttl: 100) {}
      # NOTE: the option has no effect without a block of code: there is nothing to wait for
      client.lock('auto.none', ttl: 100, auto_extend: true)
      client.lock_series('auto.none.series', ttl: 100, auto_extend: true)

      expect(client.lock_keeper.thread).to eq(nil)
      client.clear_locks
    end

    specify 'the keeper does not share the connection of a plain RedisClient' do
      plain_redis = RedisClient.config(db: 0).new_client
      client = RedisQueuedLocks::Client.new(plain_redis)
      statuses = []

      client.lock('auto.plain', ttl: 300, auto_extend: true, instrumenter: notifier) do
        # NOTE: a busy connection of the application next to the ticks of the keeper
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.7
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          statuses << plain_redis.call('PING')
        end
      end

      aggregate_failures do
        expect(statuses).to all(eq('PONG'))
        expect(notifier.events('lock_auto_extended')).not_to be_empty
        expect(notifier.events('lock_auto_extension_failed')).to be_empty
      end

      plain_redis.close
    end

    specify 'the keeper is revived after its death' do
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.dead', ttl: 300, auto_extend: true) {}
      keeper_thread = client.lock_keeper.thread
      keeper_thread.kill.join

      client.lock('auto.dead', ttl: 300, auto_extend: true) do
        sleep(0.6)
        expect(client.locked?('auto.dead')).to eq(true)
      end

      aggregate_failures do
        expect(client.lock_keeper.thread).not_to eq(keeper_thread)
        expect(client.lock_keeper.thread).to be_alive
      end
    end

    specify 'a new keeper thread takes over the leases of the dead one' do
      client = RedisQueuedLocks::Client.new(redis)
      observer = RedisQueuedLocks::Client.new(redis)
      started = Thread::Queue.new

      holder = Thread.new do
        client.lock('auto.takeover', ttl: 300, auto_extend: true) do
          started << true
          sleep(1.2)
        end
      end
      started.pop
      sleep(0.2)
      # NOTE: the thread dies with the lease in its schedule; the next lease revives it
      client.lock_keeper.thread.kill.join
      client.lock('auto.takeover.other', ttl: 300, auto_extend: true) {}
      sleep(0.6)

      aggregate_failures do
        expect(observer.locked?('auto.takeover')).to eq(true)
        holder.join
        expect(client.locked?('auto.takeover')).to eq(false)
      end
    end

    specify 'the schedule: blocks of different ttls and many blocks at once are kept' do
      client = RedisQueuedLocks::Client.new(redis)
      observer = RedisQueuedLocks::Client.new(redis)
      ttls = [300, 900, 2_700] + Array.new(20, 300)
      started = Thread::Queue.new

      holders = ttls.each_with_index.map do |ttl, index|
        Thread.new do
          client.lock("auto.schedule.#{index}", ttl:, auto_extend: true) do
            started << index
            sleep(1.5)
          end
        end
      end
      ttls.size.times { started.pop }
      # NOTE: longer than the shortest ttls: each lock is kept by its own schedule
      sleep(1.2)
      alive = ttls.each_index.count { |index| observer.locked?("auto.schedule.#{index}") }
      holders.each(&:join)

      aggregate_failures do
        expect(alive).to eq(ttls.size)
        expect(wait_until.call(2) { client.keys.empty? }).to eq(true)
      end
    end

    specify 'the keeper stops without leases and starts again on demand' do
      stub_const('RedisQueuedLocks::LockKeeper::IDLE_TIMEOUT', 100)
      client = RedisQueuedLocks::Client.new(redis)

      client.lock('auto.idle', ttl: 300, auto_extend: true) {}
      keeper_thread = client.lock_keeper.thread
      expect(wait_until.call { !keeper_thread.alive? }).to eq(true)
      expect(client.lock_keeper.thread).to eq(nil)

      client.lock('auto.idle', ttl: 300, auto_extend: true) do
        sleep(0.5)
        expect(client.locked?('auto.idle')).to eq(true)
      end
    end

    specify 'blocks that end before the keeper sees them are not an idle keeper' do
      stub_const('RedisQueuedLocks::LockKeeper::IDLE_TIMEOUT', 300)
      client = RedisQueuedLocks::Client.new(redis)
      keeper_threads = []

      # NOTE: a block without I/O ends before the keeper thread gets the GVL
      30.times do
        client.lock('auto.unseen', ttl: 5_000, auto_extend: true) {}
        keeper_threads << client.lock_keeper.thread
        sleep(0.05)
      end

      expect(keeper_threads.uniq.size).to eq(1)
    end

    specify 'a block of the same ttl needs no wake-up of the keeper' do
      wake_ups = Class.new(Thread::Queue) do
        attr_reader :count

        def <<(value)
          @count = @count.to_i + 1
          super
        end
      end.new
      client = RedisQueuedLocks::Client.new(redis)
      client.lock_keeper.instance_variable_set(:@wakeups, wake_ups)

      client.lock('auto.wakeup', ttl: 5_000, auto_extend: true) {}
      # NOTE: give a timespot to the keeper thread: it plans its next wake-up
      sleep(0.1)
      before = wake_ups.count.to_i
      20.times { client.lock('auto.wakeup', ttl: 5_000, auto_extend: true) {} }

      expect(wake_ups.count.to_i).to eq(before)
    end

    specify 'a lease with a shorter ttl wakes the keeper up' do
      client = RedisQueuedLocks::Client.new(redis)

      # NOTE: the keeper sleeps for the interval of the long ttl (~3 seconds)
      client.lock('auto.long_ttl', ttl: 9_000, auto_extend: true) {}
      sleep(0.1)

      client.lock('auto.short_ttl', ttl: 300, auto_extend: true) do
        sleep(0.8)
        expect(client.locked?('auto.short_ttl')).to eq(true)
      end
    end

    describe 'an extension during a reentrant lock attempt' do
      # NOTE: the transaction of the attempt is aborted the same way as by a tick of the lock keeper
      #   between `WATCH` and `EXEC`: the deterministic form of the race;
      let(:touches) { { left: 0, lock_key: nil, sent: 0 } }
      let(:raced_client) do
        state = touches
        toucher = redis
        middleware = Module.new do
          define_method(:call_pipelined) do |commands, redis_config, &block|
            if state[:left] > 0 && commands.first[0].to_s == 'MULTI'
              state[:left] -= 1
              state[:sent] += 1
              toucher.call('PEXPIRE', state[:lock_key], 60_000)
            end

            super(commands, redis_config, &block)
          end
        end
        RedisQueuedLocks::Client.new(
          RedisClient.config(db: 0, middlewares: [middleware]).new_pool(timeout: 5)
        ) do |config|
          config['logger'] = logger
          config['log_lock_try'] = true
        end
      end

      specify 'the attempt is repeated at once: no fail_fast failure, no spent retry' do
        client = raced_client
        touches[:lock_key] = 'rql:lock:auto.race'

        client.lock('auto.race', ttl: 5_000, conflict_strategy: :extendable_work_through) do
          [{ fail_fast: true }, { retry_count: 1 }].each do |options|
            touches[:left] = 1
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = client.lock(
              'auto.race', ttl: 1_000, conflict_strategy: :extendable_work_through, **options
            ) { :nested }

            expect(result).to eq(:nested)
            # NOTE: without the delay of the retries
            expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.15
          end
        end

        expect(touches[:sent]).to eq(2)
        expect(logger.logs).to include(
          a_string_starting_with(
            "[redis_queued_locks.try_lock.exit__reentrant_lock_is_changed] " \
            "lock_key => 'rql:lock:auto.race' "
          )
        )
      end

      specify 'the repeats are limited' do
        client = raced_client
        limit = RedisQueuedLocks::Acquirer::AcquireLock::TryToLock::MAX_REENTRANT_EXTENSION_RETRIES
        touches[:lock_key] = 'rql:lock:auto.race_limit'

        client.lock('auto.race_limit', ttl: 5_000, conflict_strategy: :extendable_work_through) do
          touches[:left] = 1_000
          result = client.lock(
            'auto.race_limit', ttl: 1_000, conflict_strategy: :extendable_work_through,
            fail_fast: true
          ) { :nested }

          expect(result).to eq({ ok: false, result: :fail_fast_after_try })
        end

        expect(touches[:sent]).to eq(limit + 1)
      end

      specify '#lock_series: the attempt is repeated at once' do
        client = raced_client
        touches[:lock_key] = 'rql:lock:auto.race_series.1'

        client.lock(
          'auto.race_series.1', ttl: 5_000, conflict_strategy: :extendable_work_through
        ) do
          touches[:left] = 1
          result = client.lock_series(
            'auto.race_series.1', 'auto.race_series.2',
            ttl: 1_000, conflict_strategy: :extendable_work_through, fail_fast: true
          ) { :nested }

          expect(result).to eq(:nested)
        end

        expect(touches[:sent]).to eq(1)
        expect(logger.logs).to include(
          a_string_starting_with(
            "[redis_queued_locks.try_lock.exit__reentrant_lock_is_changed] " \
            "lock_key => 'rql:lock:auto.race_series.1' "
          )
        )
      end

      specify 'a lock that is really lost is obtained by the repeated attempt' do
        client = raced_client
        touches[:lock_key] = 'rql:lock:auto.race_lost'

        client.lock('auto.race_lost', ttl: 5_000, conflict_strategy: :extendable_work_through) do
          redis.call('DEL', 'rql:lock:auto.race_lost')
          expect(
            client.lock(
              'auto.race_lost', ttl: 1_000, conflict_strategy: :extendable_work_through
            ) { client.locked?('auto.race_lost') }
          ).to eq(true)
        end
      end
    end

    specify 'an idle keeper does not wake up more often than the limit' do
      wake_ups = Class.new(Thread::Queue) do
        attr_reader :count

        def pop(*, **)
          @count = @count.to_i + 1
          super
        end
      end.new
      client = RedisQueuedLocks::Client.new(redis)
      client.lock_keeper.instance_variable_set(:@wakeups, wake_ups)

      # NOTE: the interval of this extension is 1 ms
      client.lock('auto.tiny_ttl', ttl: 3, auto_extend: true) {}
      sleep(0.05)
      before = wake_ups.count.to_i
      sleep(0.5)

      expect(wake_ups.count.to_i - before).to be <= 7
    end

    specify 'a failed extension of a completed block of code is not reported' do
      failed = { enabled: false, hit: false }
      keeper = nil
      failing_middleware = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if failed[:enabled] && commands.first[0].to_s == 'EVAL'
            # NOTE: the block of code is completed during the tick
            keeper.instance_variable_get(:@leases).each_key { |lease| keeper.forget(lease) }
            failed[:hit] = true
            raise(RedisClient::ConnectionError, 'failed extension')
          end

          super(commands, redis_config, &block)
        end
      end
      client = RedisQueuedLocks::Client.new(
        RedisClient.config(db: 0, middlewares: [failing_middleware]).new_pool(timeout: 5)
      )
      keeper = client.lock_keeper

      client.lock('auto.completed', ttl: 300, auto_extend: true, instrumenter: notifier) do
        failed[:enabled] = true
        expect(wait_until.call { failed[:hit] }).to eq(true)
        sleep(0.05)
      end

      expect(notifier.events('lock_auto_extension_failed')).to be_empty
    end

    specify 'a failed extension is reported and retried' do
      failing = { enabled: false }
      failing_middleware = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if failing[:enabled] && commands.first[0].to_s == 'EVAL'
            raise(RedisClient::ConnectionError, 'failed extension')
          end

          super(commands, redis_config, &block)
        end
      end
      client = RedisQueuedLocks::Client.new(
        RedisClient.config(db: 0, middlewares: [failing_middleware]).new_pool(timeout: 5)
      )

      client.lock(
        'auto.failed', ttl: 600, auto_extend: true, instrumenter: notifier, logger:,
        log_sample_this: true, instrument: { custom: :data }
      ) do
        failing[:enabled] = true
        expect(wait_until.call { notifier.events('lock_auto_extension_failed').any? }).to eq(true)
        failing[:enabled] = false
        notifier.notifications.clear
        expect(wait_until.call { notifier.events('lock_auto_extended').any? }).to eq(true)
        sleep(0.7)
        expect(client.locked?('auto.failed')).to eq(true)
      end

      expect(logger.logs).to include(
        a_string_matching(
          /\A\[redis_queued_locks\.lock_auto_extension_failed\] .*error => 'RedisClient::ConnectionError'/
        )
      )
    end

    specify 'the reported failed extension: instrumentation payload' do
      failing_middleware = Module.new do
        define_method(:call_pipelined) do |commands, redis_config, &block|
          if commands.first[0].to_s == 'EVAL'
            raise(RedisClient::ConnectionError, 'failed extension')
          end

          super(commands, redis_config, &block)
        end
      end
      client = RedisQueuedLocks::Client.new(
        RedisClient.config(db: 0, middlewares: [failing_middleware]).new_pool(timeout: 5)
      )

      client.lock('auto.failed_event', ttl: 300, auto_extend: true, instrumenter: notifier) do
        expect(wait_until.call { notifier.events('lock_auto_extension_failed').any? }).to eq(true)
      end

      expect(notifier.events('lock_auto_extension_failed').first).to match(
        {
          lock_key: 'rql:lock:auto.failed_event',
          rw_mode: :write,
          ext_ttl: 300,
          acq_id: client.current_acquirer_id,
          hst_id: client.current_host_id,
          error: 'RedisClient::ConnectionError',
          at: be_a(Float),
          instrument: nil
        }
      )
    end

    specify 'fork: the leases of the parent process are not extended by the child process' do
      client = RedisQueuedLocks::Client.new(redis)
      reader, writer = IO.pipe

      client.lock('auto.fork', ttl: 400, auto_extend: true) do
        child = fork do
          reader.close
          child_lease = client.lock_keeper.keep(
            %w[rql:lock:auto.fork.child], %w[rql:lock_readers:auto.fork.child], [nil], [:write],
            ['auto.fork.child'], 'child_acquirer', 'child_host',
            Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond), 100, 100, nil,
            false, 0, RedisQueuedLocks::Logging::VoidLogger, false,
            RedisQueuedLocks::Instrument::VoidNotifier, false, nil
          )
          leases = client.lock_keeper.instance_variable_get(:@leases).keys
          writer.write(Marshal.dump([leases.size, leases.first.equal?(child_lease)]))
          writer.close
          exit!(0)
        end
        writer.close
        Process.wait(child)

        expect(Marshal.load(reader.read)).to eq([1, true])
        sleep(0.5)
        expect(client.locked?('auto.fork')).to eq(true)
      end
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
    # NOTE: bounded polling: a lock lost on a starved CPU fails the example, never hangs it
    let(:wait_until) do
      lambda do |timeout = 5, &condition|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until condition.call
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep(0.005)
        end
        condition.call
      end
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
        client.lock('idx.read', rw_mode: :read, ttl: 100_000, queue_ttl: 5)
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
        # NOTE: the same ttl for all locks of the series
        expect(index_score_ahead.call('idx.series.a')).to upper_bound.call(100_000)
        expect(index_score_ahead.call('idx.series.b')).to upper_bound.call(100_000)
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
        client.lock('idx.ext.read', rw_mode: :read, ttl: 100_000, queue_ttl: 5)
        initial_score = score.call('idx.ext.read')
        expect(client.extend_lock_ttl('idx.ext.read', 30_000, rw_mode: :read)).to match({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(score.call('idx.ext.read')).to eq(initial_score + 30_000)
        expect(
          client.extend_lock_ttl(
            'idx.ext.read', 20_000, rw_mode: :read, all_read_locks: true
          )
        ).to match({ ok: true, result: { extended_locks_count: 1 } })
        expect(score.call('idx.ext.read')).to eq(initial_score + 50_000)
      end

      aggregate_failures 'reentrant locks (:extendable_work_through)' do
        %i[write read].each do |rw_mode|
          lock_name = "idx.ext.reentrant.#{rw_mode}"
          client.lock(lock_name, rw_mode:, ttl: 100_000, queue_ttl: 5) do
            initial_score = score.call(lock_name)
            client.lock(
              lock_name,
              rw_mode:, ttl: 40_000, conflict_strategy: :extendable_work_through
            ) do
              expect(score.call(lock_name)).to eq(initial_score + 40_000)
            end
          end
        end
      end

      aggregate_failures 'reentrant locks of the lock series (:extendable_work_through)' do
        %i[write read].each do |rw_mode|
          lock_name = "idx.ext.series.#{rw_mode}"
          client.lock(lock_name, rw_mode:, ttl: 100_000, queue_ttl: 5)
          initial_score = score.call(lock_name)
          client.lock_series(
            lock_name, "#{lock_name}.next",
            rw_mode:, ttl: 40_000, conflict_strategy: :extendable_work_through
          ) do
            expect(score.call(lock_name)).to eq(initial_score + 40_000)
          end
          # NOTE: ttl decreases never touch the lock index (the upper bound stays the upper bound)
          expect(score.call(lock_name)).to eq(initial_score + 40_000)
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
      client.lock('idx.zombie.read', rw_mode: :read, ttl: 500_000)
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
      client.lock('idx.race.read', rw_mode: :read, ttl: 100_000, queue_ttl: 5)

      expect(index_score_ahead.call('idx.race.write')).to upper_bound.call(100_000)
      expect(index_score_ahead.call('idx.race.read')).to upper_bound.call(100_000)

      client.clear_locks

      # NOTE: the obtaining transaction of the lock series indexes each lock of the series
      race_lock_names.replace(%w[idx.race.series.write idx.race.series.read])
      client.lock_series('idx.race.series.write', 'idx.race.series.a', ttl: 100_000, queue_ttl: 5)
      client.lock_series(
        'idx.race.series.read', 'idx.race.series.b',
        rw_mode: :read, ttl: 100_000, queue_ttl: 5
      )

      %w[
        idx.race.series.write idx.race.series.a idx.race.series.read idx.race.series.b
      ].each do |lock_name|
        expect(index_score_ahead.call(lock_name)).to upper_bound.call(100_000)
      end

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
        client.lock('idx.unlock.read', rw_mode: :read, ttl: 100_000)
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
        client.lock('idx.clear.1', rw_mode: :read, ttl: 100_000)
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
      client.lock('idx.ops.read', rw_mode: :read, ttl: 100_000)
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

    specify 'lock auto extension: the lock index score stays the upper bound of the lifetime' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
      end
      lock_pttl = -> (lock_key) { redis.call('PTTL', lock_key) }

      aggregate_failures do
        {
          write: 'rql:lock:idx.auto.write',
          read: 'rql:lock_readers:idx.auto.read'
        }.each do |mode, key|
          client.lock(
            "idx.auto.#{mode}", ttl: 300, rw_mode: mode, auto_extend: true, auto_extend_ttl: 90_000
          ) do
            expect(wait_until.call { lock_pttl.call(key) > 300 }).to eq(true)
            expect(index_score_ahead.call("idx.auto.#{mode}")).to upper_bound.call(90_000)
          end
        end

        # NOTE: `XX`: the removed name is not added to the lock index again
        client.lock('idx.auto.removed', ttl: 300, auto_extend: true) do
          redis.call('ZREM', lock_index, 'idx.auto.removed')
          sleep(0.5)
          expect(redis.call('ZSCORE', lock_index, 'idx.auto.removed')).to eq(nil)
        end

        # NOTE: `GT`: the score is never decreased
        client.lock('idx.auto.score', ttl: 300, auto_extend: true) do
          redis.call(
            'ZADD',
            lock_index,
            'XX',
            RedisQueuedLocks::Resource.lock_index_time * 2,
            'idx.auto.score'
          )
          sleep(0.5)
          expect(index_score_ahead.call('idx.auto.score')).to be > 1_000_000
        end
      end
    end

    specify 'lock auto extension: hold_for moves the lock index score with the lock' do
      client = RedisQueuedLocks::Client.new(redis) do |config|
        config['lock_index_enabled'] = true
      end

      client.lock(
        'idx.lease', ttl: 300, auto_extend: true, auto_extend_ttl: 90_000, max_hold_time: 300
      ) do |lease|
        aggregate_failures do
          expect(lease.hold_for(120_000)).to eq({ ok: true, result: :extended })
          expect(redis.call('PTTL', 'rql:lock:idx.lease')).to be > 80_000
          expect(index_score_ahead.call('idx.lease')).to upper_bound.call(90_000)
        end
      end
    end

    specify 'lock auto extension of the disabled lock index: no lock index commands' do
      commands = []
      recorder = Module.new do
        define_method(:call_pipelined) do |pipeline_commands, redis_config, &block|
          commands.concat(pipeline_commands.map { |command| command.map(&:to_s) })
          super(pipeline_commands, redis_config, &block)
        end
      end
      client = RedisQueuedLocks::Client.new(
        RedisClient.config(db: 0, middlewares: [recorder]).new_pool(timeout: 5)
      )

      # NOTE: the extensions of the keeper and of `LockLease#hold_for`
      client.lock('noidx.auto.write', ttl: 300, auto_extend: true) do |lease|
        lease.hold_for(1_000)
        sleep(0.5)
      end
      client.lock('noidx.auto.read', ttl: 300, rw_mode: :read, auto_extend: true) { sleep(0.5) }

      extensions = commands.select { |command| command[0] == 'EVAL' }
      aggregate_failures do
        expect(extensions.map { |command| command[2] }.uniq).to contain_exactly('1', '3')
        expect(commands.flatten).not_to include(lock_index)
      end
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
        client.lock('noidx.read', rw_mode: :read, ttl: 100_000)
        # NOTE: reentrant lock extensions (write: four extension commands without the lock index)
        %i[write read].each do |rw_mode|
          expect(
            client.lock(
              "noidx.#{rw_mode}",
              rw_mode:, ttl: 1_000, conflict_strategy: :extendable_work_through
            )
          ).to match(
            { ok: true, result: hash_including(process: :extendable_conflict_work_through) }
          )
        end
        # NOTE: lock series: obtaining, reentrant extensions and the release of both modes
        %i[write read].each do |rw_mode|
          expect(
            client.lock_series(
              "noidx.#{rw_mode}", "noidx.series.#{rw_mode}",
              rw_mode:, ttl: 1_000, conflict_strategy: :extendable_work_through
            ) { :ok }
          ).to eq(:ok)
        end
        expect(client.extend_lock_ttl('noidx.write', 10_000)).to match({
          ok: true, result: { extended_locks_count: 1 }
        })
        expect(
          client.extend_lock_ttl('noidx.read', 10_000, rw_mode: :read)
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

    specify 'names of keys without TTL (the +inf lock index score) are found by every lookup' do
      # NOTE: `#reindex_locks` indexes a key without TTL (a manual write) with the `+inf` score:
      #   ZSCAN replies have String scores (`"inf"`), such a name is never expired (every lock
      #   index lookup visits it: info, cleanups, zombies)
      client = RedisQueuedLocks::Client.new(redis) { |config| config['lock_index_enabled'] = true }
      host_id = 'rql:hst:1/2/4/manual'
      acquirer_id = 'rql:acq:1/2/3/4/manual'
      write_lock = lambda do
        redis.call(
          'HSET', 'rql:lock:idx.inf',
          'acq_id', acquirer_id, 'hst_id', host_id, 'ts', Time.now.to_f.to_s, 'ini_ttl', '1000'
        )
      end
      write_lock.call
      # NOTE: a dead lock request (an hour ago)
      redis.call('ZADD', 'rql:lock_queue:idx.inf', (Time.now.to_f - 3_600).to_s, acquirer_id)
      client.reindex_locks
      expect(redis.call('ZSCORE', 'rql:index:locks', 'idx.inf')).to eq(Float::INFINITY)

      aggregate_failures 'info lookups' do
        expect(client.locks).to contain_exactly('rql:lock:idx.inf')
        expect(client.queues).to contain_exactly('rql:lock_queue:idx.inf')
        expect(client.keys).to contain_exactly('rql:lock:idx.inf', 'rql:lock_queue:idx.inf')
        # NOTE: the host of the lock is a zombie (its last probe is an hour old)
        redis.call(
          'HSET', RedisQueuedLocks::Resource::SWARM_KEY, host_id, (Time.now.to_f - 3_600).to_s
        )
        expect(client.zombie_locks).to contain_exactly('rql:lock:idx.inf')
      end

      aggregate_failures 'cleanups' do
        expect(client.clear_dead_requests(dead_ttl: 60_000)).to match({
          ok: true, result: { processed_queues: contain_exactly('rql:lock_queue:idx.inf') }
        })
        expect(redis.call('EXISTS', 'rql:lock_queue:idx.inf')).to eq(0)
        expect(client.clear_locks_of(host_id:, acquirer_id:)).to match({
          ok: true, result: hash_including(rel_key_cnt: 1)
        })
        expect(redis.call('EXISTS', 'rql:lock:idx.inf')).to eq(0)
        write_lock.call
        expect(client.clear_locks).to match({ ok: true, result: hash_including(rel_key_cnt: 1) })
        expect(redis.call('EXISTS', 'rql:lock:idx.inf')).to eq(0)
      end
      redis.call('DEL', RedisQueuedLocks::Resource::SWARM_KEY)
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
