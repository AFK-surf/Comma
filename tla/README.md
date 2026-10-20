# System-core TLA+ policy

Keep only the most important system-level properties. All repository-owned
`.tla` and `.cfg` files together must have **at most 5,000 physical lines**.
Comments and blank lines count. Do not minify, relocate, generate, or archive
models inside the repository to avoid the budget. Older models remain in Git
history.

## Retained boundaries

| Suite                                                    | System-level failure protected against                                                                                                                         | Limits                                                                                        |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| [Salix](salix/README.md)                                 | Conflicting durable commits; stale-owner writes; duplicate or acknowledged-but-not-durable input; archive loss; external-runtime acceptance/identity confusion | Per-object CAS and bounded failures; not whole-system exactly-once execution                  |
| [Mesh trust](agent_vmm/README.md)                        | Revoked membership resurrection; unauthorized route/result replay; pairing before key confirmation                                                             | Abstract cryptography and registry CAS; conditional convergence, not a cryptographic proof    |
| [Billing](billing/README.md)                             | Unpaid/duplicate grants, ACK before journal commit, stale subscription event overwrite                                                                         | SQL transaction/row-lock assumptions and current provider reads; no delivery liveness         |
| [Signing-key rotation](oauth_idp_key_rotation/README.md) | New signing key used before compliant verifier caches can contain it                                                                                           | Routine rotation with bounded cache age; no emergency-rotation or operator-progress guarantee |

This is a selected set of bounded checks, not a composed proof of Comma.

IFC authorization and consent use the [Lean system model](../docs/verification.md), not TLA+.

## Deliberately not modeled

TLA+ covers only the core server. Client code has no TLA+ models. Implementation
tests cover client behavior.

Feature/UI lifecycles, presentation, local ordering, individual integrations,
search/indexing, scheduling refinements, Workflow/Triage reducers, provisioning
substeps, and migration protocols have no dedicated models. Their
implementation tests and product guarantees remain. The absence of a model is
**not** a claim that the retained models prove these behaviors. It does not
authorize removing runtime validation, tests, or recovery that the product needs.

Older documents and source comments can name removed modules, properties, or
commands. Those are **historical only**, not current TLC coverage. This roster
replaces all earlier inventories and all earlier rules that required a model
for each distributed feature. Do not restore a removed model only to satisfy an
old anchor or a prose-based check.

## Running and maintaining the suite

```sh
make tla                         # all retained safety/liveness/counterexamples
make tla-salix                    # Salix only
make tla-other                    # budget check, mesh trust, billing, signing-key rotation
./tla/salix/check.sh --list        # exact Salix configuration roster, no Java
./tla/salix/check.sh Lease         # selected configuration
python3 tla/check-budget.py       # physical-line inventory and budget
```

Java 11+ is required. On macOS with Homebrew OpenJDK, put the installed JDK's
`bin` directory on `PATH`. CI runs `Systems TLA+ Model Checks`, including its
`tlc` aggregate. Repository administrators must remove any retired workflow jobs
from branch-protection requirements if configured there.

The budget check counts tracked and non-ignored `.tla` and `.cfg` files in the
whole checkout. Moving a file outside `tla/` does not bypass the cap.

If you change a retained boundary, update the model and its code mapping in the
same PR, or explain why its abstraction is unchanged. New core coverage must
identify a distinct durable-state, ownership, accepted-work, authorization or
financial failure. It must fit the shared budget by simplifying or replacing
other coverage. Ordinary feature changes use implementation regressions instead.
Always state fault bounds and fairness. Do not infer liveness from safety. Keep
expected counterexamples violating, including honest residual limitations.
