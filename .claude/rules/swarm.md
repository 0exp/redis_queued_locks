---
paths:
  - "lib/redis_queued_locks/swarm.rb"
  - "lib/redis_queued_locks/swarm/**/*.rb"
  - "sig/redis_queued_locks/swarm.rbs"
  - "sig/redis_queued_locks/swarm/**/*.rbs"
---

# Swarm rules (`lib/redis_queued_locks/swarm/**`)

## Purpose
The swarm removes **zombie locks**: locks and queue entries left by dead workers.
- **Host**: a `process/thread/ractor/identity` worker, with the id `rql:hst:<pid>/<thread_id>/<ractor_id>/<identity>` (`Resource.host_identifier`). Fibers are not included because `ObjectSpace` can't see Fibers or Threads once a Ractor exists. Hosts are enumerated with `Thread.list` (`Resource.possible_host_identifiers`).
- **Liveness**: `ProbeHosts` runs `HSET rql:swarm:hsts <host_id> <Time.now.to_f>` for every possible host of the client's ractor (`Resource::SWARM_KEY`).
- **Zombie**: a host whose last probe score is `< Resource.calc_zombie_score(zombie_ttl / 1_000.0)` (`now - ttl`). `zombie_ttl` is in milliseconds. Zombie locks are `rql:lock:*` whose `hst_id` field is a zombie host. Zombie acquirers are their `acq_id`s.
- **Flush** (`FlushZombies.flush_zombies`) runs these steps: `HGETALL` hosts → zombie hosts (return early if none) → `SCAN MATCH rql:lock:*` + `HMGET acq_id hst_id` → `DEL` zombie locks → `SCAN MATCH rql:lock_queue:*` + `ZREM` zombie acquirers → `HDEL` zombie hosts. It is best-effort and non-transactional, with full keyspace scans (`TODO: indexing`).

## Components
| Object | File | Kind | Role |
|---|---|---|---|
| `Swarm` | `swarm.rb` | facade (one per `Client`, `client.swarm`) | owns the supervisor and elements. Public API: `swarm!`/`deswarm!`, `swarm_status`, `swarm_info`, `probe_hosts`, `flush_zombies`, `zombie_*`/`zombies_info`. Guards everything with its own `sync` |
| `Swarm::Supervisor` | `swarm/supervisor.rb` | plain `Thread` (`visor`) | every `swarm.supervisor.liveness_probing_period` seconds it runs the `observable` block, which calls `reswarm_if_dead!` on every element |
| `SwarmElement::Threaded` | `swarm/swarm_element/threaded.rb` | abstract base | control `Thread` plus a main-loop `Thread` |
| `SwarmElement::Isolated` | `swarm/swarm_element/isolated.rb` | abstract base | control `Ractor` plus a main-loop `Thread` inside it |
| `ProbeHosts` | `swarm/probe_hosts.rb` | `< Threaded` | periodic host liveness probes |
| `FlushZombies` | `swarm/flush_zombies.rb` | `< Isolated` | periodic zombie flushing |
| `Acquirers`, `ZombieInfo` | `swarm/acquirers.rb`, `swarm/zombie_info.rb` | stateless `class << self` modules | read-only queries (`HGETALL` swarm hash, lock `SCAN`s) |
| `RedisClientBuilder` | `swarm/redis_client_builder.rb` | stateless module | `build(pooled:, sentinel:, config:, pool_config:)` returns a fresh `RedisClient` or `RedisClient::Pooled` |

`Client` methods `swarmize!`, `deswarmize!`, `swarm_status`/`swarm_state`, `swarm_info`, `probe_hosts`, `flush_zombies`, `zombie_locks`, `zombie_acquirers`, `zombie_hosts`, `zombies_info`/`zombies` only fill defaults from `config['swarm.*']` and delegate to `Swarm`. `Client#initialize` calls `swarm.swarm!` when `swarm.auto_swarm` is set.

## Why Threaded vs Isolated
- `ProbeHosts` **must** be Threaded. Host ids come from `Thread.list` and `Ractor.current` of the client's ractor, so a probe from another Ractor would announce the wrong hosts. It may read `rql_client` (same ractor).
- `FlushZombies` is Isolated. The heavy `SCAN`/`DEL` work runs in its own Ractor with its own Redis connection, isolated from the app's ractor and objects. Everything it needs is passed into `Ractor.new(...)` as copied plain values (`config.slice('swarm.flush_zombies.redis_config')`, which `dup`s values, plus Integers). It never touches `rql_client` inside the ractor.

## Element lifecycle (both bases)
Each element has two layers, with different code for each base:
1. **Control unit** (`swarm_element`). Threaded: a `Thread` reading `swarm_element_commands` (`Thread::SizedQueue.new(1)`) and replying on `swarm_element_results` (`SizedQueue(1)`). Isolated: a `Ractor` running `self.swarm_loop`, which reads `Ractor.receive`; the host side sends with `swarm_element.send(cmd)` and gets replies via `.take`/`Ractor.yield`.
2. **Main loop**: a `Thread` that does the actual periodic work (`loop { op(redis_client, ...); sleep(period) }`), with a Redis client built inside the thread by `RedisClientBuilder` from `swarm.<element>.redis_config.*`.

Phases: **init** `swarm!` (create control unit, loop not started) → **start** `swarm_loop__start` (kill old main loop, spawn new) → **stop** `swarm_loop__stop` (Threaded) / `swarm_loop__pause` (Isolated) kills only the main loop → **kill** `swarm_element__termiante` (Threaded: kill both threads, close and clear queues, nil them) / `swarm_loop__kill` (Isolated: `:kill` makes the ractor kill its loop and `exit`).

Command protocol:
| Command | Threaded reply (`results.push`) | Isolated reply (`Ractor.yield`) |
|---|---|---|
| `:status` | `{ ok: true, result: { main_loop: { alive:, state: } } }` | `{ main_loop: { alive:, state: } }` |
| `:is_active` | `{ ok: true, result: { is_active: } }` | `Boolean` |
| `:start` | `{ ok: true, result: nil }` | none (fire-and-forget) |
| `:stop` | `{ ok: true, result: nil }` | none |
| `:kill` | n/a (termination is done from outside) | none, the ractor exits |

Every request/reply pair is wrapped in `sync.synchronize` so concurrent callers can't interleave on the single-slot channel.

State predicates (private, same names in both bases): `idle?` (no control unit), `swarmed?`, `swarmed__alive?`, `swarmed__dead?`, `swarmed__running?` (alive and main loop active), `swarmed__stopped?` (alive, loop inactive). Threaded also has `terminating?` (queues nil/closed). Liveness: Threaded uses `Thread#alive?`; Isolated uses `Utilities.ractor_alive?`/`ractor_status`, which parse `Ractor#to_s` because Ractor has no status API. Thread state uses `Utilities.thread_state` (`'dead'`/`'failed'`/`Thread#status`).

Public element API (called by `Swarm`/`Supervisor` only):
- `try_swarm!`: no-op unless `enabled?`; terminate, then `swarm!`, then start.
- `reswarm_if_dead!`: no-op unless `enabled?`; `swarmed__stopped?` → restart the loop; `swarmed__dead? || idle?` → `swarm!` and start. This is how a crashed main loop (`abort_on_exception = false`) or a killed element recovers.
- `try_kill!`: terminate regardless of `enabled?`.
- `status`: Threaded `{ enabled:, thread: { running:, state: }, main_loop: { running:, state: } }`; Isolated is the same with `ractor:` instead of `thread:`. Unborn parts report `'non_initialized'`. Isolated rescues `Ractor::ClosedError` (racing with `deswarm!`).

## Swarm orchestration (`Swarm#swarm!` / `#deswarm!`)
- `swarm!` (under `sync`): `supervisor.stop!` → each `element.try_swarm!` → `supervisor.observe! { each element.reswarm_if_dead! }` unless running → `sleep(0.1)` → `{ ok: true, result: :swarming }`. It can be called again; it re-creates everything.
- `deswarm!`: `supervisor.stop!` first, so it doesn't resurrect elements, then each `element.try_kill!` → `sleep(0.1)` → `{ ok: true, result: :terminating }`.
- `swarm_status`: `{ auto_swarm:, supervisor: { running:, state:, observable: }, probe_hosts: <status>, flush_zombies: <status> }`.
- The supervisor block swallows errors (`yield rescue nil`), so a failing element never kills the visor.

## Config (`config.rb`)
`swarm.auto_swarm`, `swarm.supervisor.liveness_probing_period` (s). Per element: `swarm.<el>.enabled_for_swarm`, a period (`probe_hosts.probe_period` s, `flush_zombies.zombie_flush_period` s), and the 4-key `swarm.<el>.redis_config.{sentinel,pooled,config,pool_config}` group. Flush extras: `zombie_ttl` (ms), `zombie_lock_scan_size`, `zombie_queue_scan_size`.

## Claude rules
1. Swarm operations are stateless class-level functions (`ProbeHosts.probe_hosts`, `FlushZombies.flush_zombies`, `ZombieInfo.*`, `Acquirers.acquirers`) that take `redis_client` plus plain values. The manual public API and the main loop call the same function. Don't put Redis logic in instance methods.
2. New element: subclass `Threaded` (it needs the client's ractor: threads, `rql_client`, or non-shareable objects) or `Isolated` (self-contained work on copied values). Implement `enabled?` plus `spawn_main_loop!` (Threaded, returns the `Thread`) or `swarm!` (Isolated: `@swarm_element = Ractor.new(<plain args>) { |...| <Klass>.swarm_loop { Thread.new { ... } } }`).
3. Register a new element everywhere: `attr_reader` + `initialize`, `swarm!` (`try_swarm!`), the supervisor block (`reswarm_if_dead!`), `deswarm!` (`try_kill!`), `swarm_status`. Add the config group (`enabled_for_swarm`, period, `redis_config.*`) with `validate`s, and add `Client` delegators with config defaults.
4. Main loops build their own Redis client with `RedisClientBuilder` inside the loop thread. Never reuse `rql_client.redis_client` in a loop, and never pass a client, logger or other non-shareable object into a Ractor. Pass `config.slice(...)` and scalars instead.
5. Inside a Ractor, reference only shareable constants and module functions (`RedisQueuedLocks::Swarm::X.op`, `RedisQueuedLocks::Resource`, `RedisQueuedLocks::Utilities`). No instance state, no captured locals.
6. Change element state only inside `sync.synchronize`. `Utilities::Lock` is a reentrant `Monitor`, so the public→private nesting is intended. Keep the single-slot request/reply pairing atomic.
7. Keep the lifecycle API names and semantics (`try_swarm!`, `reswarm_if_dead!`, `try_kill!`, `status`, the `swarmed__*` predicates, the `:status`/`:is_active`/`:start`/`:stop`/`:kill` commands) the same across both bases. The supervisor and `Swarm` rely on that duck typing.
8. Main loop threads must have `abort_on_exception = false` (the control unit sets this for Threaded) and let errors kill only the loop. Recovery belongs to the supervisor, so don't add retry loops inside elements.
9. Stop the supervisor before killing or re-creating elements, or it will race and resurrect them.
10. Report element status as the nested `{ running:, state: }` hashes with `'non_initialized'` for missing parts. Update `swarm_status` RBS types when the shape changes.
11. Zombie detection compares probe scores (`Time.now.to_f`) with `Resource.calc_zombie_score`. Keep `zombie_ttl` in ms at the API and convert with `/ 1_000.0`. Use `Resource::SWARM_KEY`/`*_PATTERN` and never hardcode keys.
12. Mirror every change in `sig/redis_queued_locks/swarm/**` and keep the existing `# steep:ignore` on nil-narrowed `Thread?`/`Ractor?` calls (Steep doesn't narrow `attr_reader` results).
13. Swarm specs (in `describe 'swarm'`) deal with real timing: set short periods via config, kill elements with `try_kill!`, wait longer than `liveness_probing_period`, and match states loosely (`eq('running').or(eq('blocking'))`, `'sleep'`/`'run'`).

## Known quirks (don't copy; fix only in a dedicated change)
- `Client#zombies_info` uses `config['swarm.flush_zombies.zombie_ttl']` as the default `lock_scan_size` (it should be `zombie_lock_scan_size`).
- Typos: `swarm_element__termiante`, `@since 19.0.0` on `Threaded#reswarm_if_dead!`, `@api ppublic` on `Swarm#zombie_acquirers`, "lopp"/"teh" in comments.
- Stop is named `swarm_loop__stop` in Threaded and `swarm_loop__pause` in Isolated, and neither is used.
- `sleep(0.1)` "give a timespot" waits in `swarm!`/`deswarm!`/`observe!` instead of real readiness signalling.
- Swarm has no logging or instrumentation, and supervisor errors are silently dropped (`TODO: (CHECK)`).
- `FlushZombies` scans the whole keyspace on every run and runs `ZREM` for every zombie acquirer on every queue.
