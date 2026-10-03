# ADR-0030 — `state.AppState`, and the `store` word belongs to the thing that persists

Date: 2026-09-29. Status: accepted (shipped; `v test .` 32/32 on Windows).

## Context

`state/store.v` shipped in T4 as the managed-app-state store: one per
`application.App`, raw JSON per key, reached from inside validated command
handlers. The ROADMAP separately lists a **`store` service** (persisted
key-value data) in S2, unstarted.

So the repo was about to contain two things called "store", differing only in
the case of one letter, meaning two different things:

| | what | lifetime | where it lives |
|---|---|---|---|
| `state.Store` (T4, shipped) | app state, Tauri `.manage()` equivalent | the session | in-memory `map[string]string` |
| `store` (S2, planned) | persisted key-value data | across launches | on disk |

In a language whose house style is snake_case, `state.Store` and `store` read
as the same word. A reader of `ROADMAP.md` could not tell which one a
sentence meant, and the fix that mattered — "the plain noun goes to the
persisted one, because that is what people mean by a store" — was blocked
while two things competed for it.

The collision was small to fix, and the measurement is what made it cheap:
`state.Store` had exactly **two** references in the whole codebase, both in
`application/application.v` (`import state` and one private field), and **the
public API never carried the name** — `set_state` / `get_state` /
`has_state` were already the only surface. So the wire contract, the
generated `.d.ts`, and every example were untouched by construction.

## Decisions

- **`state.Store` → `state.AppState`**, the constructor `new_store()` →
  `new_appstate()`, the file `state/store.v` → `state/appstate.v`, and
  `application.App`'s private field `store` → `state`.
- **The bare word `store` goes to the persisted service**, which keeps the
  name it was always going to have, and matches Tauri's vocabulary, where
  `tauri-plugin-store` is exactly that. This is the half of the change that
  does the real work: the in-memory type gave up a word it was holding badly,
  rather than the persisted one being renamed to avoid a conflict.
- **`AppState` is the name its own comment already claimed.** `store.v:1` said
  *"managed app state, Tauri `.manage()` equivalent"*, so the type was
  carrying a name that did not describe it. The rename makes the name true
  instead of renaming a concept.
- **The two things stay separate types.** They are not merged, and neither is
  absorbed into the other. See below.
- **The module name did not change.** `state.AppState` stutters slightly, and
  the module is still the right layer boundary; V's own stdlib does the same
  (`sync.Mutex`, `json2.Any`), and here the stutter buys unambiguity.
- **The `state` module documents the rename in its own header.** A future
  reader who wonders why two things in this repo use the word "store" should
  not have to rediscover the collision by finding it.

## Rejected alternatives

- **Merge into one type with a `persist` flag.** Rejected on layering, not on
  naming, and that is the reason worth recording. `state/appstate.v:12-14`
  says explicitly that it is not thread-safe *because* handlers run on the
  webview main thread (ADR-0010). A persisted store is touched by `spawn`ed
  workers and, through a capability, by a page. Merging them puts a
  capability-gated IPC surface and a main-thread in-process map behind one
  type, which forces a single locking story onto two access patterns that
  genuinely cannot share one. That is an architectural regression, and fixing
  a naming problem with one is a bad trade.
- **Rename the persisted one to `kv` instead.** Zero code churn, which is
  genuinely tempting. Rejected because it inverts the natural reading —
  "store" would then mean in-memory and "kv" would mean on disk — and because
  `state.Store` was the one whose own doc comment described something else.
  Renaming the type that is already misnamed is the stronger fix.
- **Delete the `state` module and inline the map into `application.App`.**
  Most decisive (the name disappears rather than moving) but it trades a naming
  problem for a layering one: T4 introduced the module as a seam, it has its
  own test file, and the accessors would move into `application` for no gain
  that the rename does not already provide.
- **Leave it and rely on convention.** A capitalisation difference is not a
  convention anyone can apply while reading prose, and prose is where this
  ambiguity did its damage.

## Consequences

- A direct `state.Store` import breaks. In this repository the only importer
  was `application`, so the blast radius was two lines; an external importer
  would need a one-word change. The public API is unchanged, which is why this
  is a rename and not a breaking release.
- `store` is now unambiguous everywhere: the persisted service. `AppState` is
  the in-memory one. `application.App.set_state` keeps its name because it was
  always accurate — it sets state, not a store.
- The `state` module's field in `App` is named `state`, which shares the
  imported module's name. It compiles — a field is always reached as
  `a.state` and the module is always `state.new_appstate()`, so a bare
  identifier `state` is never written — and the fallback if a future V release
  ever objects is `managed`, a one-word change. Verified on V 0.5.2.

## The acceptance criterion, corrected

I first wrote this as "`grep -ri store state/` must be empty", and that was a
badly-formed criterion: the file documents *why* it was renamed, which
necessarily mentions `store`, and "stored keys" / "stores a plain string" are
ordinary English. The criterion that actually measures the thing I set out to
fix is about **identifiers**, and it is repo-wide:

```
grep -rn "\bStore\b|new_store" --include="*.v" .    →  must be empty
```

Verified empty after the change. The word may appear in prose; the symbol may
not.

## Notes

- **`application_test.v` needed no change at all.** It exercises only
  `set_state` / `get_state` / `has_state`. That is the check that the public
  API had never leaked the name, and it is why the rename cost two files
  rather than five.
- **The field-name/module-name overlap was the one real compile risk**, and it
  was predicted in the plan before the change was made rather than discovered
  afterwards. V 0.5.2 accepted it: `v test .` 32/32, with
  `state/appstate_test.v` at [26/32].
- **This ADR exists because ADR-0020 (the `updater` track) needs a persisted
  `skipped_version`, and ADR-0031/0032 add a native UI tier and a data
  tier.** All three wanted the word. Resolving it once, explicitly, is cheaper
  than three tracks discovering the same collision.
