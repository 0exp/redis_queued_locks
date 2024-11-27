## [Unreleased]

## Changed
- Updated development dependencies (`armitage-rubocop`);
- Constant renaming: all constants and constant parts were renamed from `Acquier` to `Acquirer`;
## Added
- Type signatures (`RBS`, see the `sig` directory) + `Steep` integration (see `Steepfile` for details);

## [1.12.1]
### Changed
- Internal Private API: an internal Reentrant's Lock utility (`RedisQueuedLocks::Utilities::Lock`) basis
  is changed from `::Mutex` to `::Monitor` in order to use Ruby's Core C-based
  implementation (prevent some Ruby-runtime based GVL-oriented locking) of re-entrant locks
  instead of the custom Ruby-based implementation;
### Fixed
- `redis_queued_locks.lock_hold_and_release` instrumentation event has incorrect `acq_time` payload value
  (it incorrectly stores `lock_key` payload value);

## [1.12.0] - 2024-08-11
### Changed
- Timed blocks of code and their timeout errors: reduced error message object allocations;

## [1.11.0] - 2024-08-11
### Changed
- Lock Acquirement Timeout (`acq_timeout`/`queue_ttl`): more correct timeout error interception
  inside the `RedisQueuedLocks::Acquier::AcquireLock::WithAcqTimeout` logic that now raises and
  intercepts an internal timeout error class in order to prevent interceptions of
  other timeouts that can be raised from the wrapped block of code;

## [1.10.0] - 2024-08-11
### Changed
- Timed invocations (`"timeed blocks of code"` / `timed: true`):
  - the way of timeout error interception has been changed:
    - instead of the `rescue Timeout::Error` around the block of code the timeout interception
      now uses `Timeout#timeout`'s custom exception class/message replacement API;
    - `rescue Timeout::Error` can lead to incorrect exception interception: intercept block's-related
      Timeout::Error that is not RQL-related error;
- Updated development dependencies;
- Some minor readme updates;
### Added
- `RedisQueuedLocks::Swarm`: missing YARDocs;
- Separated `Logging Configuration` readme section (that is placed inside the main configuration section already);
- Separated `Instrumentation Configuration` readme section (that is placed inside the main configuration section already);
### Removed
- `RedisQueudLocks::Swarm`: some useless YARDocs;

## [1.9.0] - 2024-07-15
### Added
- Brand New Extremely Major Feature: **Swarm Mode** - eliminate zombie locks with a swarm:
  - works by `supervisor` + `actor model` abstractions;
  - all your ruby workers can become an element of the processs swarm;
  - each ruby worker of the swarm probes himself that he is alive;
  - worker that does not probes himselfs treats as a zombie;
  - worekr becomes dead when your ruby process is dead, or thread is dead or your ractor is dead;
  - each zombie's lock, acquier and position in queue are flushed in background via `flush_zombies` swarm element;
  - the supervisor module keeps up and running each swarm melement (`probe_hosts` and `flush_zombies`):
    - cuz each element works in background and can fail by any unexpected exception the supervisor guarantees that your elements will ressurect after that;
  - each element can be deeply configured (and enabled/disabled);
  - abilities:
    - configurable swarming and deswarming (`#swarmize!`, `#deswarmize!`);
    - encapsulated swarm interface;
    - two fully isolated swarm elements: `probe_hosts` and `flush_zombies`;
    - supervisor that keeps all elements running and wokring;
    - an ability to check the swarm status (`#swarm_status`): who is working, who is dead, running status, internal main loop states, etc;
    - an abiltiy to check the swarm information (`#swarm_info`): showing the current swarm hosts and their last probes and current zombie status;
    - an ability to find zombie locks, zombie acquiers and zombie hosts (`#zombie_locks`, `#zombie_acquiers`, `#zombie_hosts`);
    - an ability to extract the full zombie information (`#zombies_info`/`#zombies`);
    - each zombie lock will be flushed in background by appropriated swarm element (`flush_zombies`);
    - deeply configurable zombie factors: zombie ttl, host probing period, supervisor check period;
    - an ability to manually probe hosts;
    - an ability to flush zombies manually;
    - you can made `swarm`-based logic by yourself (by manually runnable `#flush_zombies` and `#probe_hosts`);
  - summarized interface:
    - `#swarmize!`, `#deswarmize!`;
    - `#swarm_status`/`#swarm_state`, `#swarm_info`
    - `#zombie_locks`, `#zmobie_acquiers`, `#zombie_hosts`, `#zombies_info`/`#zombies`;
    - manual abilities: `#probe_hosts`, `#flush_zombies`;
  - **general note**: each swarm element should have their own `RedisClient` instance so each have their own redis-client configuration
    and each of the can be configured separately (**RedisClient** multithreading limitation and **Ractor** limitations);
- Added the `lock host` abstraction (`hst_id`):
  - each lock is hosted by some ruby workers so this fact is abstracted into the host identifier represended as a combination of `process_id`/`thread_id`/`ractor_id`/`uniq_identity`;
  - the ruby worker is a combination of `process_id`/`thread_id`/`ractor_id`/`uniq_identity`);
  - each lock stores the host id (`hst_id` field) indisde their data (for debugging purposes and zombie identification purposes);
  - every lock information method now includes `hst_id` field: `#lock_info`, `#lock_data`, `#locks_info`;
  - an ability to fetch the current host id (your ruby worker host id): `#current_host_id`;
  - an ability to fetch all possible host ids in the current Ractor (all possible and reachable ruby workers from the current ractor): `#possible_host_ids`;
  - extended `RedisQueuedLocks::TimedLocktimeoutError` message: added `hst_id` field data from the lock data;
- **Instrumentation** updates:
  - added the `hst_id` field to each locking-process-related instrumentation event;
- **Logging** updates:
  - added `hst_id` field to each locking-process-related log;
- **Logging/Instrumentation Sampling** updates:
  - an ability to mark any loggable/instrumentable method as sampled for instrumentation/logging despite of the enabled instrumentation/log sampling
    by providing the `log_sample_this: true` attribute and `instr_sample_this: true` attribute respectively;
- an alias for `#clear_locks`: `#release_locks`;
- an alias for `#unlock`: `#release_lock`;

## [1.8.0] - 2024-06-13
### Added
- A configurable option that enables the adding additional lock/queue data to "Acquirement Timeout"-related error messages for better debugging;
  - Configurable option is used beacuse of the extra error data requires some additional Redis requests that can be costly for memory/cpu/etc resources;
- An ability to get the current acquirer id (`RedisQueuedLocks::Client#current_acquirer_id`);
### Changed
- Added additional lock information to some exceptions that does not require extra Redis requests;

## [1.7.0] - 2024-06-12
### Added
- New feature: **Lock Access Strategy**: you can obtain a lock in different ways: `queued` (classic queued FIFO), `random` (get the lock immideatly if lock is free):
  - `:queued` is used by default (classic `redis_queued_locks` behavior);
  - `:random`: obtain a lock without checking the positions in the queue => if lock is free to obtain - it will be obtained;
### Changed
- Some logging refactorings, some instrumentation refactorings: the code that uses them is more readable and supportable;

## [1.6.0] - 2024-05-25
### Added
- New Feature: **Instrumentation Sampling**: configurable instrumentation sampling based on `weight` algorithm (where the weight is a percentage of RQL cases that should be logged);
- Missing instrumenter customization in public `RedisQueuedLocks::Client` methods;
- Documentation updates;

## [1.5.0] - 2024-05-23
### Added
- New Feature: **Log sampling** - configurable log sampling based on `weight` algorithm (where the weight is a percentage of RQL cases that should be logged);

## [1.4.0] - 2024-05-13
### Added
- `#lock`/`#lock!`: reduced memory allocaiton during `:meta` attribute type checking;
### Changed
- More accurate time analyzis operations;

## [1.3.1] - 2024-05-10
### Fixed
- `:meta` attribute type validation of `#lock`/`#lock!` was incorrect;
### Added
- documentation updates and clarifications;

## [1.3.0] - 2024-05-08
### Added
- **Major Feature**: support for **Reentrant Locks**;
- The result of lock obtaining now includes `:process` key that shows the type of logical process that obtains the lock
  (`:lock_obtaining`, `:extendable_conflict_work_through`, `:conflict_work_through`, `:dead_locking`);
- Added reentrant lock details to `RedisQueuedLocks::Client#lock_info` and `RedisQueuedLocks::Client#locks` method results;
- Documentation updates;
### Changed
- Logging: `redis_queued_locks.fail_fast_or_limits_reached__dequeue` log is renamed to `redis_queued_locks.fail_fast_or_limits_reached_or_deadlock__dequeue`
  in order to reflect the lock conflict failures too;

## [1.2.0] - 2024-04-27
### Added
- Documentation updates;
- Logging: support for `semantic_logger` loggers (see: https://logger.rocketjob.io/) (https://github.com/reidmorrison/semantic_logger)

## [1.1.0] - 2024-04-01
### Added
- Documentation updates:
  - more `#lock` examples;
  - added missing docs for `config.dead_request_ttl`;
  - some minor updates;
### Changed
- `#clear_dead_requests`: `:scan_size` is equal to `config[:lock_release_batch_size]` now (instead of to `config[:key_extraction_batch_size]`), cuz `#clear_dead_requests` works with lock releasing;

## [1.0.0] - 2024-04-01
- First Major Release;

## [0.0.40] - 2024-04-01
### Added
- `RedisQueuedLocks::Client#clear_dead_requests` implementation;
- Logger and instrumentation are passed everywhere where any changes in Redis (with locks and queus)
  are expected;
- New config `is_timed_by_default` (boolean, `false` by default) that reflects the `timed` option of `#lock` and `#lock!` methods;
- Ther result of `#unlock` is changed: added `:lock_res` and `:queue_res` result data in order to reflect
  what happened inside (`:released` or `:nothing_to_release`) and to adopt to the case when you trying
  to unlock the non-existent lock;
- A lot of documentation updates;
- Github CI Workflow;
### Changed
- `:rel_key_cnt` result of `#clear_locks` is more accurate now;

## [0.0.39] - 2024-03-31
### Added
- Logging:
  - added new log `[redis_queued_locks.fail_fast_or_limits_reached__dequeue]`;
- Client:
  - `#extend_lock_ttl` implementation;
### Changed
- Removed `RadisQueuedLocks::Debugger.debug(...)` injections;
- Instrumentation:
  - the `:at` payload field of `"redis_queued_locks.explicit_lock_release"` event and
  `"redis_queued_locks.explicit_all_locks_release"` event is changed from `Integer` to `Float`
  in order to reflect micro/nano seconds too for more accurate time value;
- Lock information:
  - the lock infrmation extracting now uses `RedisClient#pipelined` instead of `RedisClient#mutli` cuz
    it is more reasonable for information-oriented logic (the queue information extraction works via `pipelined` invocations for example);
- Logging:
  - log message is used as a `message` (not `pragma`) according to `Logger#debug` signature;

## [0.0.38] - 2024-03-28
### Changed
- Minor update (dropped useless constant);

## [0.0.37] - 2024-03-28
### Changed
- `#queues_info`: `:contains` is renamed to `:reqeusts` in order to reflect it's domain area;

## [0.0.36] - 2024-03-28
### Added
- Requirements:
  - redis version: `>= 7.x`;
  - redis protocol: `RESP3`;
- Additional debugging methods:
  - `#locks_info` (or `#locks(with_info: true)`) - get obtained locks with their info;
  - `#queus_info` (or `#queues(with_info: true`) - get active lock queues with their info;

## [0.0.35] - 2024-03-26
### Changed
- The random unique client instance identifier now uses 16-byte strings instead of 10-bytes in order to prevent potential collisions;

## [0.0.34] - 2024-03-26
### Changed
- Removing the acquirer from the request queue during the lock obtaining logic is using more proper and accurate `ZREM` now instead of `ZPOPMIN`;

## [0.0.33] - 2024-03-26
### Added
- Logging: added current lock data info to the detailed `#try_to_lock` log to the cases when lock is still obtained. It is suitable
  when you pass a custom metadata with lock obtainer (for example: the current string of code) and want to see this information
  in logs when you can not acquire the concrete lock long time;

## [0.0.32] - 2024-03-26
### Added
- Support for custom metadata that merged to the lock data. This data also returned from `RedisQueudLocks::Client#lock_info` method;
  - Custom metadata should be represented as a `key => value` `Hash` (`nil` by default);
  - Custom metadata values is returned as raw data from Redis (commonly as strings);
  - Custom metadata can not contain reserved lock data keys;
- Reduced some memory consuption;
### Changed
- `RedisQueuedLocks::Client#lock_info`: hash key types of method result is changed from `Symbol` type to `String` type;
- `RedisQueuedLocks::Client#queue_info`: hash key types of method result is changed from `Symbol` type to `String` type;

## [0.0.31] - 2024-03-25
### Changed
- `:metadata` renamed to `:instrument` in order to reflect it's domain area;
- `:metadata` is renamed to `:meta` and reserved for future updates;

## [0.0.30] - 2024-03-23
### Fixed
- Re-enqueue problem: fixed a problem when the expired lock requests were infinitly re-added to the lock queue
  and immediately removed from the lock queue rather than being re-positioned. It happens when the lock request
  ttl reached the queue ttl, and the new request now had the dead score forever (fix: it's score now will be correctly
  recalculated from the current time at the dead score time moment);
### Added
- Logging: more detailed logs to the `RedisQueuedLocks::Acquier::AcquierLock` logic and it's sub-modules:
  - added new logs;
  - added `queue_ttl` to each log;

## [0.0.29] - 2024-03-23
### Added
- Logging: added more detailed logs to `RedisQueuedLocks::Acquier::AcquireLock::TryToLock`;

## [0.0.28] - 2024-03-21
### Added
- Logging: added `acq_id` to every log message;
- Logging: updated documentation;

## [0.0.27] - 2024-03-21
### Changed
- Better acquier position accuracy: acquier position in lock queue
  should be represented as EPOCH in seconds+microseconds (previously: simply in seconds);

## [0.0.26] - 2024-03-21
### Added
- Logging: add `acquier_id`;

## [0.0.25] - 2024-03-21
### Changed
- Minor logs stylization;

## [0.0.24] - 2024-03-21
### Added
- An optional ability to log each try of lock obtaining (see `RedisQueuedLocks::Acquier::AcquireLock::TryToLock.try_to_lock`);

## [0.0.23] - 2024-03-21
### Changed
- Composed redis commands are invoked from the same *one* conenction
  (instead of mutiple connection fetching from redis connection pool on each redis command);

## [0.0.22] - 2024-03-21
### Added
- Logging infrastructure. Initial implementation includes the only debugging features.

## [0.0.21] - 2024-03-19
### Changed
- Refactored `RedisQueuedLocks::Acquier`;

## [0.0.20] - 2024-03-14
### Added
- An ability to provide custom metadata to `lock` and `lock!` methods that will be passed
  to the instrumentation level inside the `payload` parameter with `:meta` key;

## [0.0.19] - 2024-03-12
### Added
- An ability to set the invocation time period to the block of code invoked under
  the obtained lock;

## [0.0.18] - 2024-03-04
### Changed
- Semantic results for methods returning `{ ok: true/false, result: Any }` hash objects.
  Now these objects are represented as `RedisQueuedLocks::Data` objects inherited from `Hash`;

## [0.0.17] - 2024-02-29
### Added
- `RedisQueuedLocks::Client#locks` - list of obtained locks;
- `RedisQueuedLocks::Client#queues` - list of existing lock request queus;
- `RedisQueuedLocks::Client#keys` - get list of taken locks and queues;

## [0.0.16] - 2024-02-29
### Fixed
- Execution delay formula returns the value "in seconds" (should be "in milliseconds");

## [0.0.15] - 2024-02-28
### Added
- An ability to fail fast if the required lock is already obtained;

## [0.0.14] - 2024-02-28
### Changed
- Minor documentation updates;

## [0.0.13] - 2024-02-27
### Changed
- Minor development updates;

## [0.0.12] - 2024-02-27
### Changed
- Deleted `redis expiration error` (1 millisecond time drift) from lock ttl calculation;

## [0.0.11] - 2024-02-27
### Changed
- Minor documentation updates;

## [0.0.10] - 2024-02-27
### Changed
- Minor documentation updates;

## [0.0.9] - 2024-02-27
### Changed
- The lock acquier identifier (`acq_id`) now includes the fiber id, the ractor id and an unique per-process
  10 byte string. It is added in order to prevent collisions between different processes/pods
  that will have the same process id / thread id identifiers (cuz it is an object_id integers) that can lead
  to the same position with the same `acq_id` for different processes/pods in the lock request queue.

## [0.0.8] - 2024-02-27
### Added
- `RedisQueuedLock::Client#locked?`
- `RedisQueuedLock::Client#queued?`
- `RedisQueuedLock::Client#lock_info`
- `RedisQueuedLock::Client#queue_info`

## [0.0.7] - 2024-02-27
### Changed
- Minor documentation updates;

## [0.0.6] - 2024-02-27
### Changed
- Major documentation updates;
- `RedisQueuedLock#release_lock!` now returns detaield semantic result;
- `RediSQueuedLock#release_all_locks!` now returns detailed semantic result;

## [0.0.5] - 2024-02-26
### Changed
- Minor gem update with documentation and configuration updates inside.

## [0.0.4] - 2024-02-26
### Changed
- changed default configuration values of `RedisQueuedLocks::Client` config;

## [0.0.3] - 2024-02-26
### Changed
- Instrumentation events:
  - `"redis_queued_locks.explicit_all_locks_release"`
    - re-factored with fully pipelined invocation;
    - removed `rel_queue_cnt` and `rel_lock_cnt` because of the pipelined invocation
      misses the concrete results and now we can receive only "released redis keys count";
    - adde `rel_keys` payload data (released redis keys);

## [0.0.2] - 2024-02-26
### Added
- Instrumentation events:
  - `"redis_queued_locks.lock_obtained"`;
  - `"redis_queued_locks.lock_hold_and_release"`;
  - `"redis_queued_locks.explicit_lock_release"`;
  - `"redis_queued_locks.explicit_all_locks_release"`;

## [0.0.1] - 2024-02-26

- Still the initial release version;
- Downgrade the minimal Ruby version requirement from 3.2 to 3.1;

## [0.0.0] - 2024-02-25

- Initial release
