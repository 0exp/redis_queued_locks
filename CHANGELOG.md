## [Unreleased]

## [0.0.39] - 2024-03-31
### Added
- Logging: added new log `[redis_queued_locks.fail_fast_or_limits_reached__dequeue]`;
### Changed
- Removed `RadisQueuedLocks::Debugger.debug(...)` injections;
- Instrumentation events: `:at` payload field of `"redis_queued_locks.explicit_lock_release"` and
  `"redis_queued_locks.explicit_all_locks_release"` events changed from `Integer` to `Float` (see `Time#.to_f` in Ruby docs);
- Lock information: the lock infrmation extracting now uses `RedisClient#pipelined` instead of `RedisClient#mutli` cuz
  it is more reasonable for information-oriented logic (queue information is extracteed via `pipelined` invocations already);
- Logging: log message is used as a `message` according to `Logger#debug` signature;

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
  that will have the same procjet id / thread id identifiers (cuz it is an object_id integers) that can lead
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
