# ADR-0003 — JSON-RPC bridge with explicit registration (no reflection)

Date: 2026-09-26. Status: accepted.

Wails binding leans on Go reflection (`go-reflector`, `go/types`,
`x/tools`-based `staticanalysis`/`typescriptify`) to expose Go methods to
JS automatically. V has no equivalent: only `$for`/`$if` compile-time
introspection and `json.decode/encode`.

Decision: `bridge.Router` with explicit `register(name, handler)` and a
JSON wire format (`Request{id,method,params}` → `Response{id,result,err}`,
params/result opaque JSON strings). `generator` emits `.d.ts` from
hand-written `MethodSpec`s. Compile-time auto-derivation is deferred to
Phase 7 and only if `$for` proves sufficient.

Consequence: slightly more boilerplate per bound method, but zero magic,
fully testable without a browser, and no dependency on unstable
compiler internals.
