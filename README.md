# RedisQueuedLocks

Distributed lock implementation with "lock acquisition queue" capabilities based on the Redis Database.

## Instrumentation events

- `"redis_queued_locks.lock_obtained"`
  - the moment when the lock was obtained;
  - payload:
    - `ttl` - `integer`/`milliseconds` - lock ttl;
    - `acq_id` - `string` - lock acquier identifier;
    - `lock_key` - `string` - lock name ;
    - `ts` - `integer`/`epoch` - the time when the lock was obtaiend;
    - `acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
