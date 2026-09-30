# System-core TLA+ policy

Owner decision, 2026-09-08: retain only the most important system-level
properties, with **at most 5,000 physical lines** across every repository-owned
`.tla` and `.cfg` file combined. Comments and blank lines count. The retained
suite is **14 modules / 57 configurations / 4,480 lines** (3,590 model lines and
890 configuration lines). Do not minify, relocate, generate, or archive models
inside the repository to avoid the budget. Older models remain in Git history.

## Retained boundaries

| Suite                                                    | System-level failure protected against                                                                                                                         | Limits                                                                                        |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| [Salix](salix/README.md)                                 | Conflicting durable commits; stale-owner writes; duplicate or acknowledged-but-not-durable input; archive loss; external-runtime acceptance/identity confusion | Per-object CAS and bounded failures; not whole-system exactly-once execution                  |
| [Mesh trust](agent_vmm/README.md)                        | Revoked membership resurrection; unauthorized route/result replay; pairing before key confirmation                                                             | Abstract cryptography and registry CAS; conditional convergence, not a cryptographic proof    |
| [Billing](billing/README.md)                             | Unpaid/duplicate grants, ACK before journal commit, stale subscription event overwrite                                                                         | SQL transaction/row-lock assumptions and current provider reads; no delivery liveness         |
| [Signing-key rotation](oauth_idp_key_rotation/README.md) | New signing key used before compliant verifier caches can contain it                                                                                           | Routine rotation with bounded cache age; no emergency-rotation or operator-progress guarantee |

Salix models remain separate where their state spaces do not need to interact.
This is a selected set of bounded checks, not a composed proof of Comma. Retained
models and configuration bounds are unchanged by the scope reduction.

IFC authorization and consent now use the [Lean system model](../docs/verification.md).
The former `InformationFlow` and `InformationFlowConsent` modules and their eight configurations are retired.
Lean proofs and runtime regressions retain their authorization and receipt guarantees, with explicit declaration and host trust boundaries.

## Deliberately not modeled

Comma Electron client behavior has no dedicated TLA+ models. Agent VMM is not
part of this client scope; its mesh-trust model remains in the roster above.

Feature/UI lifecycles, presentation, local ordering, individual integrations,
search/indexing, scheduling refinements, Workflow/Triage reducers, provisioning
substeps, and historical migration protocols no longer have dedicated models.
Their implementation tests and product guarantees remain. Removal is **not** a
claim that the remaining models prove these behaviors, and does not authorize
removing runtime validation, tests, or recovery required by the product.

Earlier documents, source comments and proposal evidence may name removed
modules, properties, commands, or passing runs. Those are **historical evidence
only**, not current TLC coverage. This roster supersedes all earlier inventories
and blanket requirements to create a model for each distributed feature. The
retired domain README files point here; use Git history for the old artifacts.
Do not restore them merely to satisfy an old anchor or a prose-based check.

## Running and maintaining the suite

```sh
make tla                         # all retained safety/liveness/counterexamples
make tla-salix                    # Salix only (also enforces the shared budget)
make tla-other                    # mesh trust, billing, signing-key rotation
./tla/salix/check.sh --list        # exact Salix configuration roster, no Java
./tla/salix/check.sh Lease         # selected configuration
python3 tla/check-budget.py       # physical-line inventory and budget
```

TLC 1.7.4 is pinned by the existing runners; Java 11+ is required. On macOS with
Homebrew OpenJDK, put the installed JDK's `bin` directory on `PATH`. The runners
use scratch directories and delete generated states/traces. CI retains
`Systems TLA+ Model Checks`, including its `tlc` aggregate; the independent
feature-suite workflows and their Make targets are removed, not silently
redirected to unrelated models. Repository administrators must remove any
retired workflow jobs from branch-protection requirements if configured there.

The budget check is part of the existing formal-validation entry points, not a
runtime/release check: its consumer is the model author/reviewer deciding whether
an addition displaces lower-value coverage. It counts tracked and non-ignored new
model/config files throughout the checkout, so moving a file outside `tla/` does
not bypass the cap. No build or deployment evidence is added.

For a changed retained boundary, update the model and its code mapping in the
same PR, or explain why its abstraction is unchanged. New core coverage must
identify a distinct durable-state, ownership, accepted-work, authorization or
financial failure and fit the shared budget by simplifying/replacing other
coverage. Ordinary feature changes use implementation regressions instead.
Always state fault bounds and fairness; do not infer liveness from safety. Keep
expected counterexamples violating, including honest residual limitations.
