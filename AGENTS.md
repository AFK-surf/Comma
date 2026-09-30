# Comma Agent Instructions

Development skills live in `.codex/skills` (aliased by `.claude/skills`) and
`systems/.claude/skills`. Product Agent skills under
`resources/salix-system-files/skills` do not govern repository development.

## Domain concepts

Read [the domain concept inventory](docs/architecture/DOMAIN_CONCEPTS.md) before adding or changing a domain entity.
Do not add an entity unless an existing concept cannot represent the required behavior.
Prefer existing entities, relationships, values, or explicit projections over duplicate identities and lifecycle authorities.
When a new entity is necessary, update the inventory in the same change.
Record why reuse is insufficient, its identity and scope, its authoritative owner, its lifecycle, and its relationships.
Include implementation links. Update affected entries when renaming, merging, retiring, or changing ownership of existing concepts.
A new page, provider, transport, DTO, or storage layout alone does not justify a new domain entity.

## Deployment source

Deploy staging only after the PR is merged into `main`, using the image and
chart built and published from that mainline commit. Production uses the
existing staging-proven mainline promotion flow. Never deploy an unmerged
feature/PR branch artifact, including through an image-tag override, and never
deploy a branch first with a plan to merge it afterward. Manually selected
rollback artifacts must also come from the approved mainline release flow.
Existing failed-transaction recovery may restore the pre-release serving
snapshot before an incompatible cutover; it does not authorize choosing that
snapshot as a later release candidate. An environment still serving a
historical branch artifact is not reconciled until a mainline release commits
successfully. Merge authorization, CI/review gates, stored-data safety, and
post-rollout convergence still apply.

## Salix

For Salix conversations, participants, messages, or delivery, use
`docs/README.md` to find the contract for the changed behavior. Mutate only through
`ConversationServer -> ConversationActor`. Participant mutation is separate
from message append; participants are delivery targets, not senders. Never
persist the in-memory `participant_count` aggregate.

## Release convergence and migrations

Rollouts and provider migrations may interrupt service between phases. Preserve
owned data. After cutover, restore service within the documented release or
provider budget. A failed dependency may instead return a bounded, actionable
error. Do not add a rolling-window reader, dual write, fallback, adapter,
shadow state, or extra rollout solely for intermediate availability. Transform
durable facts once, rebuild only owner-approved disposable state, or fail closed
until the completed release reconciles the affected path.

For example, if the Sprites Device disconnects during a Group migration's
`preparing` phase, read the saved operation and source seal. Retry that phase
or cancel it when the source is reachable. Do not add another carrier to keep
the Group online during `preparing`. The migration is complete only when the
Cloudflare Device connects, retained Sessions and input resume, and the archive
hold clears after a durability check. A committed provider field is insufficient.

Graceful rolling updates are the default.
The authoritative policy is `docs/release-operations.md#rollout-policy-and-human-shutdown-approval`.
Staging scale-to-zero or deployment-wide shutdown requires a human issue comment
under that policy. The issue title and body must say
`HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE`.
Agents must never approve, impersonate a human approver, or bypass this requirement
through direct cluster commands. Temporary mixed-version unavailability alone
is not a reason to choose shutdown.

An incompatible schema cutover may use the existing `exclusive` release mode
only with the required human approval.
The PR must identify the durable facts that survive, the exact disposable scope,
the post-cutover convergence condition and budget, and whether recovery is
pre-cutover rollback or post-cutover forward repair. Do not add compatibility
state merely to make an old binary a post-cutover rollback target. Backups and
restore evidence are required only for durable data that the cutover can alter;
they are not required for an owner-approved rebuild of disposable projections.

Destructive scope must be resolved with a bounded read before execution. Never
infer that a cache, VM disk, workload volume, credential store, or projection is
disposable: the owning product decision must name it. Preserve unrelated data,
use only approved mainline artifacts, and report any required re-enrollment or
reauthentication as part of the convergence result.

## Documentation style

Use the project `ste-writing` skill for documentation, READMEs, runbooks, release
notes, and pull request text. Use STE-flavored mode by default. Use strict mode
for procedures and safety text. Do not use this default when the user requests
detailed writing or a different style.

## Documentation scope and budget

Keep general documentation under `docs/` to at most 20 tracked files, recursively.
Each counted file must be at most 20,000 UTF-8 bytes, including non-Markdown files.
Exclude `docs/architecture/` and `docs/user_manual/` from both limits. Preserve
these directories during general documentation cleanup unless separately requested.
Run `pnpm docs:check` after documentation changes.

Consolidate current contracts by topic. Update an existing document instead of
adding another RFC, plan, review transcript, completion report, or hand-test diary.
Remove obsolete and duplicate content. Keep historical decisions in Git history,
not a relocated archive, generated copy, or another directory that evades the budget.
Keep generated PDFs, screenshots, and previews outside the general documentation inventory.
The architecture and user-manual directories retain their existing artifact workflows.
Do not move current documentation elsewhere merely to meet the limit.

Preserve current product, authorization, data-safety, and operational guarantees
when consolidating. Keep proof assumptions and verification limits explicit.
Repair current links and affected tooling. Remove obsolete prose checks rather
than retaining filler to satisfy them. Do not rewrite published migration sources
or historical evidence merely to update their citations.

## Distributed protocols

Keep TLA+ focused on the most important system-level properties, within a
repository-wide budget of 5,000 physical lines across all `.tla` and `.cfg`
files (including comments and blank lines). Do not compress formatting, move
models outside `tla/`, generate hidden models, or retain retired copies to evade
the budget. The authoritative scope and commands are in `tla/README.md`.

- Update retained models in the same change when their transitions, assumptions,
  invariants, or claimed progress change. If unchanged, explain the code mapping
  in the PR. Keep bidirectional anchors for retained models.
- Model durable-state safety, ownership/fencing, accepted-work preservation,
  authorization and financial integrity, not every feature lifecycle or retry.
  Extend or replace a core model only for a distinct system-wide failure boundary;
  state what existing coverage pays for the addition within the budget.
- Keep orthogonal protocols separate; compose only for a shared invariant.
  Model realistic failure/retry/stale-owner interleavings. State fault bounds and
  fairness; check any progress claim as liveness, otherwise claim no progress.
- Run `make tla`; expected counterexamples must remain violating. Passing TLC
  proves the bounded abstraction, not runtime conformance or end-to-end behavior.
- Feature-level behavior stays in implementation tests and protocol documentation.
  Removing its model does not remove its product guarantee or its regression tests.
  Old anchors to models outside the current roster are historical references,
  not current machine-checked evidence; do not recreate them automatically.

For Salix also follow `systems/AGENTS.md`.

## Comma App local development

For everyday Electron UI development and debugging, prefer running local source
with the dev app identity against the staging backend. From the repository root:

```sh
COMMA_BUILD_FLAVOR=dev \
COMMA_API_BASE_URL=https://salix-staging.comma.surf \
pnpm --dir clients dev:electron
```

This keeps the `Comma Dev` identity, `@comma-dev` data directory, and `comma-dev://`
protocol while using staging services. Do not select the staging build flavor
merely to reach its backend: that shares the installed Comma Staging app's data
directory and protocol handler. Existing credentials from a different backend
cannot be reused; do not automatically clear a developer's profile to switch
backends. Treat staging interactions as real shared-environment operations.

Use `make dev-electron` when working on the local backend or when deterministic
local fixtures are needed. Package an `.app` only when explicitly requested or
when the task requires packaged behavior, such as signing, keychain identity,
installation, updates, or packaged resources. Existing build-based E2E checks
remain applicable; packaging is not the default way to launch everyday dev work.

Local model switching also requires Agent configuration admission. Database
migrations alone do not complete this initialization. The source dev-container
runs `systems/devcontainer/bootstrap.exs` before starting the backend. For an
unfinished handoff, it verifies that Bridge agent and project tables are absent,
then completes the empty handoff through `SalixStore.AgentConfigurationRollout`.
If Bridge tables exist, use the existing release handoff instead.

If Router or Worker model selection returns
`agent_configuration_rollout_pending`, check local bootstrap completion before
changing the model or API key. After updating bootstrap code, run
`make dev-container-restart` with the same Compose port overrides used at startup.
For example, preserve `COMMA_DEV_REDIS_PORT=16379` if that stack uses port 16379.
Retry the model selection and confirm the saved value through `GET
/v1/comma/workspaces/:workspace_id/agent-models`. Do not manually write admission
markers or apply the local initialization path to staging or production.
See [local model switching](docs/development.md#local-model-switching).

Subscription accounts require the bundled Go worker and a persistent encryption key.
The `comma-dev-salix-agent-priv` volume isolates the Linux worker from host builds.
After a Compose volume change, recreate the dev-container with `make dev-container-rebuild`.
After adding subscription support to an older dev-container, rebuild it with the same port overrides.
Local startup retains its generated key at `/var/lib/comma-dev/subscription-storage-key` in `comma-dev-cache`.
Preserve that volume and the database together. Do not regenerate the key to fix startup errors.
See [local subscription setup](docs/development.md#local-subscription-setup).

## Client UI

UI: `clients/packages/ui`; Figma: `VnkgBb2xCr5bRp4KHrLrqs`. Use Central Icons,
not SVG exports. Record node id, Figma name, variant, and npm import in
`components/icons/iconRegistry.ts` (helpers: `centralIconVariants.ts`).

1. Call Figma `get_design_context` on the icon/small instance, not a page. Map
   `data-name`'s leading phrase to `IconXxx`; never infer it from UI labels.
2. Confirm it under
   `@central-icons-react/round-{outlined|filled}-radius-{1|2}-stroke-2/`.
   Client glyphs use stroke `2`; radius/fill vary.
3. Wire the registry/entry point. Only `src/tokens/icons.ts`'s
   `iconStrokeWidth` sets weight; no per-icon `strokeWidth`.
4. Run `pnpm exec vitest run packages/ui/src/components/icons`.

Visible scrollbars use `ScrollArea`, not CSS/raw `overflow-*`. Choose one
`edgeEffect`: `none`, `mask`, or `blur`. `edgeMask` is only opacity fade;
`edgeBlur` only gradient blur; direction comes from `orientation`. Keep effects
opt-in/narrow. Extend `ScrollArea`; no edge-axis controls, per-instance
`ResizeObserver`, or local measurement.

Before using a base component, follow its `GUIDE.md` if present.

## External integrations

- Prefer official SDKs, then maintained popular libraries. Before handwriting
  protocols, document why libraries fail; isolate the adapter and integration
  test it.
- For new artifact-acceptance, release, or service-availability gates, the
  independent reviewer must assess the architecture. Identify the independent
  failure boundary and the user, operator, or deployer decision each gate changes.
  Without that review, only delete or narrow such gates. Input validation and enforcement of
  existing domain or authorization rules use the normal code review.
  Trust successful CI and content-addressed releases. Do not duplicate their
  checks at runtime or keep checks solely for tests, models, or reports.
- Before adding a hash, digest, signature, certificate, revision, credential,
  or identity check, document the concrete threat or user-visible failure, the
  independent authority for the expected value, the verification owner, and
  the fail-closed user result. A same-origin checksum, an online signature
  created inside the same serving/primary-database trust domain, or a value
  with no behavior-changing consumer is not a separate security boundary.
  Keep such values only as explicitly labeled provenance or diagnostics, or
  remove them. Expanding the protected threat boundary requires owner review.
- Billing catalogs use stable product-owned plan/package keys and provider
  lookup keys. Provider ids such as Stripe `price_*`/`cus_*` are synchronized
  mappings, not product identity.
- Never sync providers from migrations. Migrations may seed local catalogs;
  explicit release/ops tasks must converge external objects with dry-run,
  retries, and drift failure.

## Runtime and data access

- Separate manager connectivity, command authority, and child process lifetime.
  Manager loss, upgrade, or an older version alone does not authorize stopping
  independently running children or invalidating their durable identity.
  Reject unsupported operations locally. Preserve explicit revocation and
  stale-target fencing without converting them into unrelated health gates.
- Bound requests, pages, concurrency, and recovery work rather than imposing an
  arbitrary total workload/appliance count. Existing constants and TLA bounds
  are not product capacity decisions. Appliance resource budgets are shared,
  not per-appliance CPU/memory reservations or fixed percentage partitions.
- A file-descriptor identity check may protect one operation from path replacement.
  Do not promote inode, ctime, transport epoch, or executable version to durable
  business identity without a concrete failure, owner, and behavior-changing consumer.
- Keep entity-owned behavior local; use RPC only for distributed contracts.
- Bound request/render/polling paths. No full fan-out scans; use
  cached/precomputed/indexed data.
- Reconcile many children in a worker, queue, or pipeline.
- Keep interaction-critical state cheap to load and UI-shaped.
- Before polling/timers/per-client refresh, estimate per-user/org cardinality
  and document the bound. Tests must reject unbounded per-child RPC/full scans.

## Native capability kernel

All main<->renderer capabilities use generated leaves in
`clients/packages/native-bridge/src/capability-leaves.ts`; regenerate.

- `defineNativeCapability`: command, request -> typed result.
- `defineNativeEvent`: fire-and-forget event.
- `defineNativeState`: owned replay-last `{ snapshot, get, subscribe }`; only
  the owner's mutation/snapshot path publishes, via composition-root wiring.

Leaves define zod I/O, permission, handler metadata, and mock/web fallback. The
generator owns contracts, bridge/types, bindings, and manifest. Renderers
spread it and call `getNativeBridge()`. Only aliases may be handwritten.

Forbidden:

- Raw IPC or new `ipcMain.handle` outside the gateway; legacy allowlist only
  shrinks.
- Electron-main imports or raw secrets in renderer/shared. Main is bearer
  authority: SecureStore holds tokens; `/v1` strips renderer auth and injects.
- State publication from renderer, gateway, dev surfaces, or bypasses.
- Hand-edited generated artifacts; edit the leaf and regenerate.
- Fake dev data; mark paths `needs-capability` or `planned`.

Verify with:

```sh
pnpm --dir clients check:foundation
pnpm --dir clients --silent check:foundation -- --list
pnpm --dir clients typecheck && pnpm --dir clients lint
```

`check:foundation --list` lists configuration and generated-file consistency checks.
It does not prove runtime isolation or security. Verify those boundaries through execution.

## Tests

Keep the test suite proportional to the behavior and risk it protects. Actively
remove low-value tests, not just the first obvious examples:

- Remove tests whose only purpose is to prove that a retired behavior, API, or
  implementation identifier is absent. Test the current user or safety contract instead.
- Do not assert over implementation source, scripts, workflow text, or their AST.
  Migrate valid quality goals to behavior tests. Delete redundant implementation checks.
  Keep compiler, type, lint, and generated-file consistency checks.
- Do not snapshot trivial implementation properties, source phrases, prompt
  wording, CSS classes, literal schemas, or a helper's own declaration.
  Keep checks for externally meaningful output and real authorization or ownership boundaries.
- Avoid oversized case matrices for simple functions or modules when the cases
  do not protect distinct behavior or failure boundaries.
- Remove property tests fully covered by Lean only after identifying the executable
  theorem and confirming the same property and input domain. An abstract or
  similarly named theorem is insufficient. Keep codec, FFI, host-fact resolution,
  compaction, transport, and other runtime tests outside that proof boundary.

Do not maximize deletion counts at the expense of meaningful regressions.
Prefer interaction, failure, and runtime-boundary evidence over assertions that
merely repeat the implementation or documentation.

- Test business/user behavior; prefer E2E across runtime/UI/native boundaries.
  Fixes need regressions. Extend existing E2E; justify heavyweight setup. Do
  not test-wrap simple repo checks.
- For modified tests, report old behavior, new behavior, and why.
- If behavior changes lack tests, check PR `[test-not-required]` with a concrete
  reason before relying on `make test-policy`.
- Put Playwright tests near runtime/package (`clients/{packages/app,apps/electron}/e2e`).
- Reserve `clients/e2e/p0` for critical frequent paths and startup/isolation.
- Put unit/component tests nearby; shared helpers in `clients/packages/test-utils`.
- Prefer local Docker. For cluster validation, build locally and push an image
  tag only to an isolated test workload outside staging and production.
  Staging and production follow the Deployment source rule above.
  Never push a test branch unless asked.

## Review loops

Repeated same-class blockers signal an architecture problem. Before a second
fix, author and reviewer must discuss whether the promise is wrong and narrowing
is acceptable. Weakening an existing product/API/operational/security/data
guarantee requires a human-owner decision recorded in the PR; a guarantee new
to the same unmerged PR may be narrowed if noted. At the third round for the
same subsystem/class, stop fixes and await the owner's decision on a one-page
structural-cause statement.

## Merge review gate

Use `feat: description`, `refactor: description`, or `fix: description` for pull request titles.
You may add a scope after the type, such as `feat(billing): add Cloudflare VM pricing`.

Merge only after review converges with no blockers. Non-blockers neither gate
merge nor reset convergence. Classify by effect:

- **Behavioral blocker:** trusting it breaks correctness, data safety, security,
  or availability. Add/run a reproducible before-fail/after-pass E2E; without
  one, it is not this blocker type.
- **Semantic-contract blocker:** an authoritative contract contradicts the
  implementation and misleads a caller/operator. Show the claim, wrong
  decision, and reality; verify correction against code/direct tests. Product
  red->green E2E is unnecessary.
- **Non-blocking:** the worst effect is imprecision.

Artifact, importance, effort, and confidence do not set severity. Missing both
blocker evidence bars means non-blocking. A test unable to fail on its defect
cannot close a behavioral blocker; later strengthening is non-blocking.

Before merge, audit relevant docs, including untouched ones, against code/tests:
design, protocol, API/storage, lifecycle, operations, and hand-test. Semantic
drift blocks; editorial drift may follow up.

Head changes re-run CI. Reviewer delta acknowledgment replaces exact-head audit
only for editorial changes. Contract, operational, or behavior claims are
semantic regardless of file type and re-run applicable gates.

## Worktrees

Use the current repository checkout for one PR. Create additional worktrees
only when developing multiple PRs in parallel, with at most one additional
worktree per additional concurrent PR. For example, two parallel PRs use the
current checkout and at most one additional worktree. Sequential PRs and phases
do not require separate worktrees.

After a branch is merged, switch its checkout back to the main branch and reuse
that directory for a new PR. If no additional parallel PR needs a worktree,
remove the clean worktree. Preserve uncommitted changes and work owned by others.

## Commands

```sh
make test-clients
make test-clients-smoke
make test-systems
make test-policy
```
