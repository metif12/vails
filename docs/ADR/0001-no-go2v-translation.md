# ADR-0001 — No Go→V translation; Vails is a re-implementation

Date: 2026-09-26. Status: accepted.

V ships `v translate` / `vlang/c2v` for **C→V only** (Clang-AST based;
C++ is early-stage). No Go→V tool exists or is on the V roadmap, and Go's
`reflect`, `go/types`, goroutine scheduler and CGO patterns have no direct
V counterpart.

Decision: do not attempt automated translation of `wailsapp/wails`.
Use v2 (stable, `internal/frontend`, `pkg/assetserver`, `pkg/commands`)
and v3 (beta, `pkg/application`, `pkg/services`, `pkg/events`,
`internal/generator`) as API/architecture guides; write idiomatic V.

Consequence: larger upfront design work, but a smaller, V-native codebase
instead of transliterated Go that fights the V compiler.
