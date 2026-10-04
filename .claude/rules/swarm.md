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
| `SwarmElement::Isolated` | `swarm/swarm_element/isolated.rb` | abstract base | control `Ractor` plus a main-loop `Thread` inside it, driven through a per-element pair of `Ractor::Port`s |
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
1. **Control unit** (`swarm_element`). Threaded: a `Thread` reading `swarm_element_commands` (`Thread::SizedQueue.new(1)`) and replying on `swarm_element_results` (`SizedQueue(1)`). Isolated: a `Ractor` running `self.swarm_loop(swarm_element_results_port)` that reads `swarm_element_commands_port` and replies on `swarm_element_results_port`, both `Ractor::Port`s (see "Isolated ports" below).
2. **Main loop**: a `Thread` that does the actual periodic work (`loop { op(redis_client, ...); sleep(period) }`), with a Redis client built inside the thread by `RedisClientBuilder` from `swarm.<element>.redis_config.*`.

Phases: **init** `swarm!` (create control unit, loop not started) → **start** `swarm_loop__start` (kill old main loop, spawn new) → **stop** `swarm_loop__stop` kills only the main loop → **kill** `swarm_element__termiante` (Threaded: kill both threads, close and clear queues, nil them) / `swarm_loop__kill` (Isolated: `:kill` makes the ractor kill and join all its threads, ack, and leave its loop; the host then `join`s the ractor).

Command protocol: the same bare-value replies in both bases (see "Internal API: scalars and primitives" below).
| Command | Reply |
|---|---|
| `:status` | `{ alive: Boolean, state: String }` |
| `:is_active` | `true` / `false` |
| `:start` / `:stop` | `true` (ack) |
| `:kill` | Isolated only: `true` (ack), then the ractor finishes. Threaded is terminated from outside. |

Every request/reply pair is wrapped in `sync.synchronize` so concurrent callers can't interleave on the channel, and each reply belongs to the command just sent. Isolated sends every command through one helper, `swarm_loop__request(command)`, which returns the reply, or `nil` when the element is dead.

## Internal API: scalars and primitives
`{ ok:, result: }` is the **public API** contract only: `Client` methods, `Acquirer::*` operations, and the `Swarm` facade's public methods (`swarm!`/`deswarm!`, plus the stateless operations behind `client.probe_hosts` / `client.flush_zombies`). Status reports (`swarm_status`, element `#status`, `Supervisor#status`) are plain nested Hashes with no wrapper.

Everything inside swarm elements is internal API and uses bare scalars and primitives, with no `{ ok:, result: }` wrapper. That covers control-unit commands and replies, the Isolated handshake, port and queue messages, `swarm_loop__*` helpers, `swarmed__*` predicates and main-loop plumbing.
- **Commands**: Symbols (`:status`, `:is_active`, `:start`, `:stop`, `:kill`).
- **Replies**: the value itself. Use `true`/`false` for questions and `true` as the ack for actions. Use a String/Symbol/Integer/Float for a single datum, and a flat Hash of scalars (`{ alive:, state: }`) only when a reply carries several related values. Don't nest.
- **Handshake**: the commands port itself, sent as the first message.
- **"No answer" / dead element**: `nil`. On the results port, a Symbol (`:exited`/`:aborted`) is reserved for the `Ractor#monitor` death notice, so never reply with a Symbol there. If a datum is a Symbol, send it as a String.
- **Errors**: don't wrap them in replies. A failing main loop just dies, and a dead control unit is detected through liveness, the monitor notice or `nil`.

## Isolated ports (`Ractor::Port`)
Only the Ractor that created a port can `receive` from it; any Ractor can send to it. So each Isolated element owns two ports:
- **`swarm_element_results_port`**: created in the **main Ractor** by `swarm!`. The Swarm and its Supervisor live there, and so do all callers of the element API. It receives command replies and also the Ractor's termination notice: `swarm!` calls `swarm_element.monitor(results)`, which sends `:exited`/`:aborted`, immediately if the Ractor has already finished.
- **`swarm_element_commands_port`**: created **inside the element Ractor** by `.swarm_loop`. It's handed to the main Ractor as the first message on the results port (the handshake: the port itself; any other first message means the Ractor died during startup), which `swarm!` waits for.

Ports belong to the element instance, so any number of Isolated elements work side by side without sharing channels. A new `swarm!` creates a fresh pair, and stale messages left in an old results port are dropped with it.

Failure handling in `swarm_loop__request`:
- A non-Hash reply (`:exited`/`:aborted`) means the Ractor died, so the request returns `nil`.
- Sending to a finished Ractor's port raises `Ractor::ClosedError`, which is also rescued to `nil`.
- No request can block forever, because the monitor notice always arrives.

Thread hygiene inside the Ractor: a Ractor stays `running` until **all** its threads have finished. Killed but un-joined threads count, and so do helper threads that `Socket.tcp` leaves behind when the loop is killed mid-connect. `.terminate_thread` therefore kills and joins. `:kill` terminates every thread of the Ractor (`Thread.list - [Thread.current]`) before acking, and `swarm_loop__kill` joins the Ractor, so the status is `terminated` as soon as `try_kill!` returns.

State predicates (private, same names in both bases): `idle?` (no control unit), `swarmed?`, `swarmed__alive?`, `swarmed__dead?`, `swarmed__running?` (alive and main loop active), `swarmed__stopped?` (alive, loop inactive). Threaded also has `terminating?` (queues nil/closed). In Isolated, `swarmed__running?`/`swarmed__stopped?` return `false` when the request returned `nil` (the element died mid-request). Liveness: Threaded uses `Thread#alive?`; Isolated uses `Utilities.ractor_alive?`/`ractor_status`, which parse `Ractor#to_s` because Ractor has no status API. Thread state uses `Utilities.thread_state` (`'dead'`/`'failed'`/`Thread#status`).

Public element API (called by `Swarm`/`Supervisor` only):
- `try_swarm!`: no-op unless `enabled?`; terminate, then `swarm!`, then start.
- `reswarm_if_dead!`: no-op unless `enabled?`; `swarmed__stopped?` → restart the loop; `swarmed__dead? || idle?` → `swarm!` and start. This is how a crashed main loop (`abort_on_exception = false`) or a killed element recovers.
- `try_kill!`: terminate regardless of `enabled?`.
- `status`: Threaded `{ enabled:, thread: { running:, state: }, main_loop: { running:, state: } }`; Isolated is the same with `ractor:` instead of `thread:`. Unborn parts report `'non_initialized'`. Isolated gets the main loop part from a single `:status` request, and a dead element reports `'non_initialized'`.

## Swarm orchestration (`Swarm#swarm!` / `#deswarm!`)
- `swarm!` (under `sync`): `supervisor.stop!` → each `element.try_swarm!` → `supervisor.observe! { each element.reswarm_if_dead! }` unless running → `sleep(0.1)` → `{ ok: true, result: :swarming }`. It can be called again; it re-creates everything.
- `deswarm!`: `supervisor.stop!` first, so it doesn't resurrect elements, then each `element.try_kill!` → `sleep(0.1)` → `{ ok: true, result: :terminating }`.
- `swarm_status`: `{ auto_swarm:, supervisor: { running:, state:, observable: }, probe_hosts: <status>, flush_zombies: <status> }`.
- The supervisor block swallows errors (`yield rescue nil`), so a failing element never kills the visor.

## Config (`config.rb`)
`swarm.auto_swarm`, `swarm.supervisor.liveness_probing_period` (s). Per element: `swarm.<el>.enabled_for_swarm`, a period (`probe_hosts.probe_period` s, `flush_zombies.zombie_flush_period` s), and the 4-key `swarm.<el>.redis_config.{sentinel,pooled,config,pool_config}` group. Flush extras: `zombie_ttl` (ms), `zombie_lock_scan_size`, `zombie_queue_scan_size`.

## Claude rules
1. Swarm operations are stateless class-level functions (`ProbeHosts.probe_hosts`, `FlushZombies.flush_zombies`, `ZombieInfo.*`, `Acquirers.acquirers`) that take `redis_client` plus plain values. The manual public API and the main loop call the same function. Don't put Redis logic in instance methods.
2. New element: subclass `Threaded` (it needs the client's ractor: threads, `rql_client`, or non-shareable objects) or `Isolated` (self-contained work on copied values). Implement `enabled?` plus `spawn_main_loop!` (Threaded, returns the `Thread`) or `spawn_swarm_element!(swarm_element_results_port)` (Isolated: return `Ractor.new(swarm_element_results_port, <plain args>) { |r_res_p, ...| <Klass>.swarm_loop(r_res_p) { Thread.new { ... } } }`). Don't override `swarm!` in Isolated subclasses; the base wires the ports, the monitor and the handshake.
3. Register a new element everywhere: `attr_reader` + `initialize`, `swarm!` (`try_swarm!`), the supervisor block (`reswarm_if_dead!`), `deswarm!` (`try_kill!`), `swarm_status`. Add the config group (`enabled_for_swarm`, period, `redis_config.*`) with `validate`s, and add `Client` delegators with config defaults.
4. Main loops build their own Redis client with `RedisClientBuilder` inside the loop thread. Never reuse `rql_client.redis_client` in a loop, and never pass a client, logger or other non-shareable object into a Ractor. Pass `config.slice(...)` and scalars instead.
5. Inside a Ractor, reference only shareable constants and module functions (`RedisQueuedLocks::Swarm::X.op`, `RedisQueuedLocks::Resource`, `RedisQueuedLocks::Utilities`). No instance state, no captured locals.
6. Change element state only inside `sync.synchronize`. `Utilities::Lock` is a reentrant `Monitor`, so the public→private nesting is intended. Keep the single-slot request/reply pairing atomic.
7. Keep the lifecycle API names and semantics (`try_swarm!`, `reswarm_if_dead!`, `try_kill!`, `status`, the `swarmed__*` predicates, the `:status`/`:is_active`/`:start`/`:stop`/`:kill` commands) the same across both bases. The supervisor and `Swarm` rely on that duck typing.
8. Main loop threads must have `abort_on_exception = false` (both control units set this) and let errors kill only the loop. Recovery belongs to the supervisor, so don't add retry loops inside elements.
9. Stop the supervisor before killing or re-creating elements, or it will race and resurrect them.
10. Report element status as the nested `{ running:, state: }` hashes with `'non_initialized'` for missing parts. Update `swarm_status` RBS types when the shape changes.
11. Zombie detection compares probe scores (`Time.now.to_f`) with `Resource.calc_zombie_score`. Keep `zombie_ttl` in ms at the API and convert with `/ 1_000.0`. Use `Resource::SWARM_KEY`/`*_PATTERN` and never hardcode keys.
12. Mirror every change in `sig/redis_queued_locks/swarm/**` and keep the existing `# steep:ignore` on nil-narrowed `Thread?`/`Ractor?` calls (Steep doesn't narrow `attr_reader` results).
13. Isolated communication goes only through `Ractor::Port`s: create the results port in the main Ractor (`swarm!`) and the command port inside the element Ractor (`.swarm_loop`), and register `Ractor#monitor` on the results port before waiting on it. Every command gets exactly one reply, sent before the Ractor leaves its loop. Treat Symbol replies as death notices. Don't use `Ractor.receive`, `Ractor#send` or the default port, and never share one port between elements. Naming: port variables, attributes and params end in `_port` (`swarm_element_results_port`, `swarm_element_commands_port`). Block (proc) params use short initial-letter names (`r_res_p` for the results port, `r_com_p` for the commands port), like the other abbreviated Ractor block params (`rc`, `z_ttl`).
14. Inside an element Ractor, terminate threads with kill + join (`.terminate_thread`) and keep `:kill` terminating every thread of the Ractor. Otherwise its status lags as `running`.
15. Don't use `{ ok:, result: }` inside swarm elements (see "Internal API: scalars and primitives"). Commands are Symbols. Replies, helper returns and predicates are bare scalars/primitives, or a flat Hash of scalars, with `nil` for "no answer / dead". Keep the wrapper only at the public boundary (`Client`, `Acquirer::*`, `Swarm#swarm!`/`#deswarm!`, `ProbeHosts.probe_hosts`, `FlushZombies.flush_zombies`). Type internal replies in RBS as literal types/unions (`bool`, `String`, `{ alive: bool, state: String }`) rather than `xxxResult` records.
16. Swarm specs (in `describe 'swarm'`) deal with real timing: set short periods via config, kill elements with `try_kill!`, wait longer than `liveness_probing_period`, and match states loosely (`eq('running').or(eq('blocking'))`, `'sleep'`/`'run'`).

## Known quirks (don't copy; fix only in a dedicated change)
- Typos: `swarm_element__termiante`, `@since 19.0.0` on `Threaded#reswarm_if_dead!`, `@api ppublic` on `Swarm#zombie_acquirers`, "lopp"/"teh" in comments.
- `swarm_loop__stop` is not used by the swarm itself, only by specs.
- Killing an element while its main loop is still connecting to Redis makes Ruby's `Socket.tcp` helper threads print `terminated with exception ... IO#write` reports. This is harmless noise from the stdlib.
- `sleep(0.1)` "give a timespot" waits in `swarm!`/`deswarm!`/`observe!` instead of real readiness signalling.
- RBS runtime type checking (`rbs/test/setup`, the `typecheck-runtime` CI job) can't run inside Ractors. Its hooks on methods called in the element Ractor (`.swarm_loop`, `.flush_zombies`) read `RBS.logger` and raise `Ractor::IsolationError`, so Isolated elements die at startup and the swarm specs fail only under that job.
- Swarm has no logging or instrumentation, and supervisor errors are silently dropped (`TODO: (CHECK)`).
- `FlushZombies` scans the whole keyspace on every run and runs `ZREM` for every zombie acquirer on every queue.
