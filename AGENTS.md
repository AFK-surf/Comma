# Comma Agent Instructions

Development skills live in `.codex/skills` (aliased by `.claude/skills`) and
`systems/.claude/skills`. Product Agent skills under
`resources/salix-system-files/skills` do not govern repository development.

## Domain concepts

Read [the domain concept inventory](docs/architecture/DOMAIN_CONCEPTS.md) before you add or change a domain entity.
Add an entity only when no existing entity, relationship, value, or explicit projection can represent the behavior.
Do not duplicate identities or lifecycle authorities.
A new page, provider, transport, DTO, or storage layout alone does not justify a new entity.
When you add an entity, update the inventory in the same change.
Record why reuse is insufficient, its identity and scope, owner, lifecycle, relationships, and implementation links.
Update affected entries when you rename, merge, retire, or change the owner of a concept.

## Deployment source

Deploy staging only after the PR merges into `main`, with the image and chart built from that mainline commit.
Production uses the existing staging-proven mainline promotion flow.
Never deploy an unmerged branch artifact, including through an image-tag override.
Never deploy a branch with a plan to merge it later.
Manually selected rollback artifacts must also come from the approved mainline release flow.
Failed-transaction recovery may restore the pre-release serving snapshot before an incompatible cutover.
That does not make the snapshot a later release candidate.
An environment that serves a historical branch artifact is not reconciled until a mainline release commits.
Merge authorization, CI and review gates, stored-data safety, and post-rollout convergence still apply.

## Salix

For Salix conversations, participants, messages, or delivery, use `docs/README.md` to find the contract.
Mutate only through `ConversationServer -> ConversationActor`.
Participant mutation is separate from message append. Participants are delivery targets, not senders.
Never persist the in-memory `participant_count` aggregate.
Also follow `systems/AGENTS.md`.

## Release convergence and migrations

Rollouts and provider migrations may interrupt service between phases.
Preserve central product facts and persistent user data. Cloudflare Group disks follow the [Cloud VM data policy](#cloud-vm-data-policy).
After cutover, restore service within the documented release or provider budget, or return a bounded, actionable error for a failed dependency.
Do not add a rolling-window reader, dual write, fallback, adapter, shadow state, or extra rollout only for intermediate availability.
Transform durable facts once, rebuild only owner-approved disposable state, or fail closed until the completed release reconciles the path.

Graceful rolling updates are the default. The policy is
`docs/release-operations.md#rollout-policy-and-human-shutdown-approval`.
Staging scale-to-zero or deployment-wide shutdown requires a human issue comment under that policy.
The issue title and body must say `HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE`.
Agents must never approve, impersonate a human approver, or bypass this through direct cluster commands.
Temporary mixed-version unavailability alone is not a reason for shutdown.

An incompatible schema cutover may use the existing `exclusive` release mode only with that human approval.
The changed release contract must name the durable facts that survive, the exact disposable scope,
the post-cutover convergence condition and budget, and whether recovery is pre-cutover rollback or post-cutover forward repair.
Do not add compatibility state only to make an old binary a post-cutover rollback target.
Backups and restore evidence are required only for durable data that the cutover can alter, not for an owner-approved rebuild of disposable projections.

Resolve destructive scope with a bounded read before execution.
Never infer that a cache, VM disk, workload volume, credential store, or projection is disposable. The owning product decision must name it.
Preserve unrelated data, use only approved mainline artifacts, and report required re-enrollment or reauthentication in the convergence result.

## Cloud VM data policy

Cloudflare Group VMs are temporary, volatile Agent execution environments.
Their disks, local repositories, dependencies, harness state, native history, credentials, and output not yet in Salix are disposable.
Archive and restore are best effort. Use available archives for normal restore and try the existing bounded recovery path.
If it fails, reset the exact VM and rebuild or reinstall local state.
Do not require another human approval for loss of these files or keep a release blocked to preserve them.
A destructive reset must not restore old pending execution as current work. Report any required login or interrupted work.

Salix-owned Sessions, Messages, accepted queues, credentials, and execution records keep their own storage and ownership rules.
A discarded VM does not prove that an input was never sent or that an external side effect failed.
Fence old commands and confirm the exact target stopped before you replace it.
This policy does not apply to user Devices or persistent Agent VMM Hosts.

## Documentation style

Use the `ste-writing` skill for documentation, READMEs, runbooks, release notes, and PR text.
Use STE-flavored mode by default and strict mode for procedures and safety text.
Follow a different style when the user requests detailed writing or another style.

## Pull request text

Keep the repository PR template. Keep only the sections the change needs and delete the rest.
Write a short title and a few short sentences or bullets that state what changed.
Do not include motivation, derivation, investigation history, test results, verification reports, limitations, or non-guarantees.
Keep test and review evidence in CI, commits, or the working chat.
A requested product policy change belongs in the changed contract document. The PR text only names it.

## Documentation scope and budget

General documentation under `docs/` has at most 20 tracked files, recursively, each at most 20,000 UTF-8 bytes (non-Markdown included).
`docs/architecture/` and `docs/user_manual/` are excluded from both limits. Preserve them during general cleanup unless separately requested.
They keep their existing artifact workflows.
Run `pnpm docs:check` after documentation changes.

Consolidate current contracts by topic. Update an existing document instead of adding an RFC, plan, review transcript, completion report, or hand-test diary.
Remove obsolete and duplicate content. Keep history in Git, not in an archive, generated copy, or other directory that evades the budget.
Do not move current documentation elsewhere only to meet the limit. Keep generated PDFs, screenshots, and previews out of the inventory.

Apply the same audit to ignored `.context/` notes and historical reports. Delete obsolete plans and reports that contradict current policy.
Correct mixed-topic notes without removing unrelated facts, secrets, or persistent user data.
Do not move obsolete content into another historical copy.

Preserve current product, authorization, data-safety, and operational guarantees. Keep proof assumptions and verification limits explicit.
Repair current links and affected tooling. Remove obsolete prose checks instead of keeping filler to satisfy them.
Do not rewrite published migration sources or historical evidence only to update citations.

## Distributed protocols

TLA+ covers only the most important system-level properties, within 5,000 physical lines across all `.tla` and `.cfg` files (comments and blank lines included).
Do not compress formatting, move models outside `tla/`, generate hidden models, or keep retired copies to evade the budget.
Scope and commands are in `tla/README.md`.
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

## Comma App local development

Treat staging interactions as real shared-environment operations.
See [Development](docs/development.md).

## Client UI

UI components are in `clients/packages/ui`.

For a UI fix or new UI, use the design system first:

1. Find the existing component in `clients/packages/ui` and its Figma DS component and variant. Extend a component before you write a new one.
2. Use `src/styles/theme.css` tokens for color, spacing, type, radius, and motion. Do not write raw values.
3. Read Figma node values with Figma MCP. Do not estimate them from screenshots.
4. Follow a base component's `GUIDE.md` if present.

For icons and scrollbars, follow [`clients/packages/ui/GUIDE.md`](clients/packages/ui/GUIDE.md) and [`scroll-area/GUIDE.md`](clients/packages/ui/src/components/scroll-area/GUIDE.md).

## External integrations

- Prefer official SDKs, then maintained popular libraries. Before you handwrite a protocol, document why libraries fail, isolate the adapter, and integration test it.
- A new artifact-acceptance, release, or service-availability gate needs an independent reviewer's architecture assessment.
  Identify the independent failure boundary and the user, operator, or deployer decision the gate changes.
  Without that review, only delete or narrow such gates. Input validation and existing domain or authorization rules use normal code review.
  Trust successful CI and content-addressed releases. Do not repeat their checks at runtime or keep checks only for tests, models, or reports.
- Before you add a hash, digest, signature, certificate, revision, credential, or identity check, document the concrete threat or user-visible failure,
  the independent authority for the expected value, the verification owner, and the fail-closed user result.
  A same-origin checksum, an online signature made inside the same serving/primary-database trust domain, or a value with no behavior-changing consumer is not a separate security boundary.
  Keep such values only as labeled provenance or diagnostics, or remove them. Expanding the protected threat boundary requires owner review.
- Billing catalogs use stable product-owned plan/package keys and provider lookup keys. Provider ids such as Stripe `price_*`/`cus_*` are synchronized mappings, not product identity.
- Never sync providers from migrations. Migrations may seed local catalogs. Explicit release/ops tasks converge external objects with dry-run, retries, and drift failure.

## Runtime and data access

- Separate manager connectivity, command authority, and child process lifetime.
  Manager loss, upgrade, or an older version alone does not authorize stopping independent children or invalidating their durable identity.
  Reject unsupported operations locally. Keep explicit revocation and stale-target fencing, without turning them into unrelated health gates.
- Bound requests, pages, concurrency, and recovery work, not total workload or appliance count.
  Existing constants and TLA bounds are not product capacity decisions.
  Appliance resource budgets are shared, not per-appliance CPU/memory reservations or fixed percentage partitions.
- A file-descriptor identity check may protect one operation from path replacement.
  Do not promote inode, ctime, transport epoch, or executable version to durable business identity without a concrete failure, owner, and behavior-changing consumer.
- Keep entity-owned behavior local. Use RPC only for distributed contracts.
- Bound request, render, and polling paths. No full fan-out scans. Use cached, precomputed, or indexed data.
- Reconcile many children in a worker, queue, or pipeline.
- Keep interaction-critical state cheap to load and UI-shaped.
- Before you add polling, timers, or per-client refresh, estimate per-user/org cardinality and document the bound.
  Tests must reject unbounded per-child RPC and full scans.

## Native capability kernel

All main<->renderer capabilities use generated leaves in
`clients/packages/native-bridge/src/capability-leaves.ts`. Regenerate after changes.

- `defineNativeCapability`: command, request -> typed result.
- `defineNativeEvent`: fire-and-forget event.
- `defineNativeState`: owned replay-last `{ snapshot, get, subscribe }`. Only the owner's mutation/snapshot path publishes, through composition-root wiring.

Leaves define zod I/O, permission, handler metadata, and mock/web fallback.
The generator owns contracts, bridge/types, bindings, and manifest. Renderers spread it and call `getNativeBridge()`.
Only aliases may be handwritten.

Forbidden:

- Raw IPC or new `ipcMain.handle` outside the gateway. The legacy allowlist only shrinks.
- Electron-main imports or raw secrets in renderer/shared. Main is the bearer authority: SecureStore holds tokens, and `/v1` strips renderer auth and injects it.
- State publication from renderer, gateway, dev surfaces, or bypasses.
- Hand-edited generated artifacts. Edit the leaf and regenerate.
- Fake dev data. Mark paths `needs-capability` or `planned`.

Verify with:

```sh
pnpm --dir clients check:foundation
pnpm --dir clients --silent check:foundation -- --list
pnpm --dir clients typecheck && pnpm --dir clients lint
```

`check:foundation --list` lists configuration and generated-file consistency checks.
It does not prove runtime isolation or security. Verify those through execution.

## Tests

Keep the suite proportional to the behavior and risk it protects. Actively remove low-value tests, not only the obvious ones:

- Remove tests that only prove a retired behavior, API, or identifier is absent. Test the current user or safety contract.
- Do not assert over implementation source, scripts, workflow text, or their AST. Move valid quality goals to behavior tests and delete redundant implementation checks.
  Keep compiler, type, lint, and generated-file consistency checks.
- Do not snapshot trivial implementation properties, source phrases, prompt wording, CSS classes, literal schemas, or a helper's own declaration.
  Keep checks for externally meaningful output and real authorization or ownership boundaries.
- Avoid large case matrices for simple code when the cases do not protect distinct behavior or failure boundaries.
- Remove property tests fully covered by Lean only after you identify the executable theorem and confirm the same property and input domain.
  An abstract or similarly named theorem is insufficient. Keep codec, FFI, host-fact resolution, compaction, transport, and other runtime tests outside that proof boundary.

Do not maximize deletion counts at the cost of meaningful regressions.
Prefer interaction, failure, and runtime-boundary evidence over assertions that repeat the implementation or docs.

- Test business/user behavior. Fixes need a regression at the lowest layer that
  shows the failure. Do not test-wrap simple repo checks.
- For modified tests, report old behavior, new behavior, and why.
- Put Playwright tests near the runtime or package (`clients/{packages/app,apps/electron}/e2e`).
- Reserve `clients/e2e/p0` for critical frequent paths and startup/isolation.
- Put unit and component tests nearby. Put shared helpers in `clients/packages/test-utils`.
- Tests do not use the real network: the harness fails a test that connects outside this machine ([no real network](docs/testing.md#no-real-network)).
- Prefer local Docker. For cluster validation, build locally and push an image tag only to an isolated test workload outside staging and production.
  Staging and production follow [Deployment source](#deployment-source). Never push a test branch unless asked.

### End-to-end tests

An E2E test runs the whole chain, not one unit: the product's entry point, the
client core, the host and its process boundaries, and the server or its scripted
stand-in. It does not depend on the parts that cannot be made deterministic,
mainly the rendered UI.

- Drive the chain through deterministic entry points: core calls and topics
  (`startTestCore`, `FakeHost`, `FakeCommaApi`, `TestTime`), native-bridge
  capabilities, Main's services and server APIs. Do not drive business behavior
  by clicking, typing or waiting for rendered UI.
- Keep business logic out of the UI. When a behavior can be reached only through
  the UI, move its logic into the client core first, then test it there end to end.
- Test the UI separately: a component renders the core's values and its actions
  call the core (component tests).
- Use a UI-driven Playwright or Electron test only for what only a window or the
  operating system shows: native windows, focus, IPC and process boundaries,
  clipboard and dialogs, credential isolation, and rendering identity. Keep each
  such test to that boundary and do not repeat business checks in it.

## Review loops

Repeated same-class blockers signal an architecture problem.
Before a second fix, author and reviewer must discuss whether the promise is wrong and narrowing is acceptable.
Weakening an existing product, API, operational, security, or data guarantee requires a human-owner decision recorded in the changed contract.
A guarantee new to the same unmerged PR may be narrowed in that contract.
At the third round for the same subsystem and class, stop fixes and await the owner's decision on a one-page structural-cause statement.

## Merge review gate

PR titles use `feat: description`, `refactor: description`, or `fix: description`, with an optional scope such as `feat(billing): add Cloudflare VM pricing`.

Merge only after review converges with no blockers. Non-blockers do not gate merge or reset convergence. Classify by effect:

- **Behavioral blocker:** trusting it breaks correctness, data safety, security, or availability.
  Add and run a reproducible before-fail/after-pass E2E. Without one, it is not this type.
- **Semantic-contract blocker:** an authoritative contract contradicts the implementation and misleads a caller or operator.
  Show the claim, the wrong decision, and reality. Verify the correction against code or direct tests. Product red->green E2E is unnecessary.
- **Non-blocking:** the worst effect is imprecision.

Artifact, importance, effort, and confidence do not set severity. Missing both blocker evidence bars means non-blocking.
A test that cannot fail on its defect cannot close a behavioral blocker. Later strengthening is non-blocking.

Before merge, audit relevant docs, including untouched ones, against code and tests:
design, protocol, API/storage, lifecycle, operations, and hand-test. Semantic drift blocks. Editorial drift may follow up.

Head changes re-run CI. Reviewer delta acknowledgment replaces an exact-head audit only for editorial changes.
Contract, operational, or behavior claims are semantic in any file type and re-run applicable gates.

## Worktrees

Use the current checkout for one PR. Create an additional worktree only for a PR developed in parallel, at most one per additional concurrent PR.
Sequential PRs and phases do not need separate worktrees.
After a branch merges, switch its checkout back to the main branch and reuse it for a new PR.
If no parallel PR needs a worktree, remove the clean worktree. Preserve uncommitted changes and work owned by others.
