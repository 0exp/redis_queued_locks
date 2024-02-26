# RedisQueuedLocks

Distributed lock implementation with "lock acquisition queue" capabilities based on the Redis Database.

## Instrumentation events

- `"redis_queued_locks.lock_obtained"`
  - a moment when the lock was obtained;
  - payload:
    - `ttl` - `integer`/`milliseconds` - lock ttl;
    - `acq_id` - `string` - lock acquier identifier;
    - `lock_key` - `string` - lock name;
    - `ts` - `integer`/`epoch` - the time when the lock was obtaiend;
    - `acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
- `"redis_queued_locks.lock_hold_and_release"`
  - an event signalizes about the "hold+and+release" process
    when the lock obtained and hold by the block of logic;
  - payload:
    - `hold_time` - `float`/`milliseconds` - lock hold time;
    - `ttl` - `integer`/`milliseconds` - lock ttl;
    - `acq_id` - `string` - lock acquier identifier;
    - `lock_key` - `string` - lock name;
    - `ts` - `integer`/`epoch` - the time when lock was obtained;
    - `acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
- `"redis_queued_locks.explicit_lock_release"`
  - an event signalizes about the explicit lock release (invoked via `RedisQueuedLock#unlock`);
  - payload:
    - `at` - `integer`/`epoch` - the time when the lock was released;
    - `rel_time` - `float`/`milliseconds` - time spent on lock releasing;
    - `lock_key` - `string` - released lock (lock name);
    - `lock_key_queue` - `string` - released lock queue (lock queue name);
- `"redis_queued_locks.explicit_all_locks_release"`
  - an event signalizes about the explicit all locks release (invoked via `RedisQueuedLock#clear_locks`);
  - payload:
    - `rel_time` - `float`/`milliseconds` - time spent on the lock release;
    - `at` - `integer`/`epoch` - the time when the operation has ended;
    - `rel_keys` - `integer` - released redis keys count (`released queu keys` + `released lock keys`);
