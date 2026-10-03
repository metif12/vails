# ADR-0032 — Data services: a `store` with a swappable engine, and a `sql` that never takes SQL from a page

Date: 2026-09-29. Status: planned (ROADMAP track D; no code yet).

## Context

The request: SQL and key-value databases written in V — `vsql` and LevelDB —
as a plugin or a service.

Two things decide the shape of this, and one of them was a correction during
planning.

**The libraries exist, and their maturity is the headline:**

| | what | stars | last activity | license |
|---|---|---|---|---|
| `vlang/leveldb` | "LevelDB key/value database implementation in pure V" | 9 | pushed 2026-07 (2 months) | BSD-2 |
| `elliotchance/vsql` | "Single-file or PostgreSQL-server compatible transactional SQL database written in pure V" | 346 | **pushed 2025-02 (19 months)** | MIT |

Neither is stale in the sense of being abandoned, and both are **pure V**,
which matters more than star counts here: ADR-0013 chose stdlib `net.http` over
`veb` specifically to keep the Windows test suite gcc-free, and both of these
honour that. But a framework making persistence its default on a nine-star
two-month-old library is a different proposition from making it an option.

**The correction: `store` was going to be a wrapper, and it should not be.**
The initial plan was a `kv` service wrapping `vlang/leveldb`. That produces two
persisted-KV surfaces the moment the `store` service lands — which the ROADMAP
already lists in S2 — and every user then has to answer "which one do I use?"
with no good answer. Two surfaces for one job is the exact mistake ADR-0030
just undid at the naming layer. The resolution is the one recorded here: **one
`store`, with its engine behind a seam.**

## Decisions (planned, to be confirmed in D0)

- **One persisted key-value surface: the `store` service.** It keeps the plain
  name, per ADR-0030. The bare word means "durable", and that is now settled
  for the whole repository.
- **The default engine is a JSON file, not a database.** The data this holds
  is config-shaped — theme, window bounds, feature flags, the updater's
  `skipped_version` that ADR-0020 plans — so a few KB to a few hundred KB.
  Whole-file rewrite on save is irrelevant at that size, it needs no
  dependency, it keeps the Windows test suite gcc-free, and the file stays
  **inspectable**, which is a real property: a user or a support thread can
  open it. A KV store is a few hundred lines, so Vails writing it is not a
  compromise.
- **The engine is a seam with a second implementation behind it, not a
  default swap.** `v.lang/leveldb` is a legitimate engine once it matures and
  is the right one for append-heavy or large data — for which the JSON engine
  is simply the wrong tool. It is `vails.json`'s `store.engine`, default
  `file`. This is also the answer to the "should we depend on a 9-star
  library?" question: no, not by default.
- **`state.AppState` is untouched.** In-memory session state and durable
  storage are different things with different lifecycles, and
  `state/appstate.v:12-14` says outright that it is not thread-safe *because*
  handlers run on the webview main thread. One is a process-local map read from
  a command handler; the other is a service behind a capability, touched by
  workers. Merging them (or making `AppState` itself persistent) would force
  one locking story onto two access patterns that cannot share one — the same
  rejection recorded in ADR-0030, reached from the other direction.
- **The `sql` service does not accept SQL text from a page.** This is the most
  important decision in the track. A `sql` command that takes a query string
  from the frontend is a remote-code-execution vector the moment the app loads
  remote content, and it is exactly why `opener` carries a scheme allowlist
  (ADR-0015) and why scoped `fs` is last and riskiest. The design: **the
  frontend names a query, and V owns the SQL.** A registry on the V side maps
  names to statements; a name that is not registered is an error naming the
  registry, not a syntax error from the database. At an absolute minimum,
  multiple statements are refused even then.
- **Both are services, not plugins — and that question was answered in
  ADR-0014/0015, not here.** The service manifest, the single `install` path,
  the capability gate, the `*_support()` backend report for `doctor`, and the
  `.d.ts` generation are all already built. A new data service inherits them
  for free; the only work left is recording that the "plugin or service"
  question has an answer.
- **`vsql` is consumed, not written.** The asymmetry with `store` is
  deliberate and worth stating: a key-value store is a few hundred lines, an
  SQL engine with a parser, a planner, a catalog and transactions is a
  different order of problem — and one already exists in pure V, so wrapping it
  costs nothing and rewriting it costs a great deal. The 19-month gap since its
  last push is recorded as a risk, not waved away.

## Waves

`D0` the security decision, above, as pure-V policy with tests (~1 d) → `D1`
`store`: file engine, the `Engine` seam, config, migrations-free versioning
(~3 d) → `D2` the LevelDB engine, opt-in, with its maturity recorded (~2 d) →
`D3` the `sql` service on `vsql`, query-name registry, gcc-free tests (~4 d).

**D0 alone is worth doing first regardless of order**: it is a day, it is
pure V, and it is the decision that has to exist before any `sql` code is
written. An implementation written against the wrong security model is
expensive to fix after the fact.

## Rejected alternatives

- **A `kv` service wrapping LevelDB, alongside the planned `store`.** This was
  the initial plan and it is the thing being removed. Two persisted-KV APIs in
  one framework, with no good rule for choosing between them, is the mistake
  ADR-0030 was written to undo one layer up.
- **LevelDB as the default engine.** Better engine for large data, and a
  nine-star two-month-old library is not what a framework's default persistence
  should rest on. It stays reachable; it does not carry the default.
- **A SQLite backend** (there is a `vsqlite` CLI and V's own `vsqlite` tool).
  SQLite is C, and C breaks the gcc-free rule ADR-0013 adopted deliberately.
  Recorded as rejected with the reason, because it is the obvious suggestion
  and the reason is not obvious.
- **One type for in-memory and persisted state, with a `persist` flag.**
  Rejected in ADR-0030 on layering; it is the same rejection and it does not
  become acceptable by being restated.
- **Letting the frontend send SQL.** The reasoning is in the decision above and
  is not repeated here, but the alternative deserves a name: a database service
  is the one capability where "the page asked nicely" is not a security model.
- **Making `stronghold` the answer too.** It stays out of scope, and for the
  same reason `leveldb` is not a second store: S2's `keychain` covers secrets
  with the OS keychain behind it, which is a different job from persistence.

## Consequences

- `store` leaves the S2 list and becomes D1, with an engine decision attached.
  S2 gets shorter by one item and the ROADMAP gains one.
- The `sql` service's usability is deliberately narrower than SQL. A developer
  who wants ad-hoc queries writes a V function and registers a name; that is
  the price of a service a page can be granted, and it is the same price
  `opener` charges for not being an arbitrary launcher.
- A `store` service means ADR-0020's updater state has a natural home — but
  the updater does **not** wait for it. U4 keeps its private JSON file, which is
  the seam D1 later absorbs. Sequencing: D1 after U4, not before.
- Both new services add to the `services` catalog, so `manifest_test.v`'s
  count assertion and `support.v`'s list both move, and `vails dts` gains two
  namespaces for any app that grants them.

## Open decisions (not taken here)

- **Does `store` need any concurrency control at all in v1?** A single-file
  JSON store read and written from one process is not obviously a locking
  problem, but workers (ADR-0019's `post_to_main` makes them usable) and the
  main thread can now touch the same key. D1 decides; it is deliberately not
  pre-empted here.
- **How much of `vsql` is exposed** — just queries, or transactions, or schema
  migration as well. D3 measures what the library actually offers first.

## Notes (verified 2026-09-29, via the GitHub contents API)

- **`vlang/leveldb`**: created 2026-07-11, pushed 2026-09-26, **9 stars**, 2
  forks, 2 open issues, BSD-2, description *"LevelDB key/value database
  implementation in pure V"*. 50 KB.
- **`elliotchance/vsql`**: created 2021-07-19, **last pushed 2025-02-14**,
  **346 stars**, 19 forks, 36 open issues, MIT, docs at
  `vsql.readthedocs.io`, description *"Single-file or PostgreSQL-server
  compatible transactional SQL database written in pure V"*.
- **The name `vsql` is ambiguous** and the ADR says so rather than picking
  silently: there is also `lydiandy/vsql` (47 stars, *"A sql query builder for
  V"*, last pushed 2021-10). Two unrelated projects, one name. The track
  commits to `elliotchance/vsql` because that is the database; the query
  builder is a different thing entirely.
- **Neither library is in this V checkout.** `vlib` contains no `leveldb` and
  no `vsql`; the only near-match in the V tree is `cmd/tools/vsqlite`, a CLI
  tool. Both arrive through VPM, so B5 gates D1 and D3 exactly as it gates
  ADR-0031's `ui2` tier.
- **V's own `vlib` has a `sync.Mutex`** on both Windows and pthread
  (`vlib/sync/sync_windows.c.v`, `vlib/sync/sync_default.c.v`), so a
  file-backed engine needing mutual exclusion is pure V and gcc-free. Recorded
  here because ADR-0019 already needed it and the answer should not have to be
  looked up twice.
