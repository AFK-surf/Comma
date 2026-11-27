# Distributed protocol agent instructions

These rules apply to TLA+ models in `tla/` and to every change of a modeled distributed protocol, wherever its code lives.
The repository root `AGENTS.md` also applies.

TLA+ covers only the most important system-level properties, within 5,000 physical lines across all `.tla` and `.cfg` files (comments and blank lines included).
Do not compress formatting, move models outside `tla/`, generate hidden models, or keep retired copies to evade the budget.
Scope and commands are in [`README.md`](README.md).
Client code (Electron, web, iOS/Android, client TypeScript core) has no TLA+ models. Implementation tests cover it.

- Update retained models in the same change when their transitions, assumptions, invariants, or progress claims change.
  If unchanged, explain the code mapping in review evidence. Keep bidirectional anchors.
- Model durable-state safety, ownership and fencing, accepted-work preservation, and authorization and financial integrity, not every feature lifecycle or retry.
  Extend or replace a core model only for a distinct system-wide failure boundary, and state what existing coverage pays for it within the budget.
- Keep orthogonal protocols separate. Compose only for a shared invariant.
  Model realistic failure, retry, and stale-owner interleavings. State fault bounds and fairness. Check a progress claim as liveness, or claim no progress.
- Run `make tla`. Expected counterexamples must stay violating. Passing TLC proves the bounded abstraction, not runtime conformance.
- Feature-level behavior stays in implementation tests and protocol docs. Removing its model does not remove its guarantee or regression tests.
  Old anchors to models outside the current roster are historical, not machine-checked evidence. Do not recreate them.
