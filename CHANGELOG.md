## [Unreleased]

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
