# Comma Agent Instructions

Development skills are in `.codex/skills` (alias `.claude/skills`) and `systems/.claude/skills`.
Product Agent skills in `resources/salix-system-files/skills` do not govern development.
Also follow [`systems/AGENTS.md`](systems/AGENTS.md) for `systems/`, Salix, Cloud VMs, providers, releases, and migrations;
[`tla/AGENTS.md`](tla/AGENTS.md) for TLA+ and modeled protocols;
[`clients/AGENTS.md`](clients/AGENTS.md) for client apps, UI, native bridge, and client tests.

## Domain concepts

Read [the inventory](docs/architecture/DOMAIN_CONCEPTS.md) before adding or changing a domain entity.
Add one only when no existing entity, relationship, value, or explicit projection can represent the behavior. Do not duplicate identities or lifecycle authorities.
A new page, provider, transport, DTO, or storage layout alone is no justification.
Record it in the inventory in the same change: why reuse is insufficient, identity and scope, owner, lifecycle, relationships, and implementation links.
Update affected entries when renaming, merging, retiring, or re-owning a concept.

## Deployment source

Deploy staging only with the image and chart built from the merged `main` commit. Production uses the existing staging-proven mainline promotion flow.
Never deploy an unmerged branch artifact, even through an image-tag override, or a branch you plan to merge later.
Manually chosen rollback artifacts also come from the approved mainline release flow.
Prefer local Docker. For cluster validation, push a locally built image tag only to an isolated test workload, never staging or production.
Never push a test branch unless asked.
Failed-transaction recovery may restore the pre-release snapshot before an incompatible cutover. That snapshot is no later release candidate.
An environment serving a historical branch artifact is not reconciled until a mainline release commits.
Merge authorization, CI and review gates, stored-data safety, and post-rollout convergence still apply.

## Configuration updates

Before each update to a 1Password-stored configuration file, download the latest copy for the target environment.
Apply only the requested field changes to that copy. Keep previously removed fields out of the upload.

## Documentation

Use the `ste-writing` skill for docs, READMEs, runbooks, release notes, and PR text:
STE-flavored by default, strict for procedures and safety text; another style if the user asks for detailed writing or another style.

General docs under `docs/` have at most 20 tracked files (recursive), each at most 20,000 UTF-8 bytes, non-Markdown included.
Excluded: `docs/architecture/` and `docs/user_manual/`, which keep their artifact workflows and stay intact in general cleanup unless requested.
Run `pnpm docs:check` after doc changes.
Consolidate contracts by topic. Update a document instead of adding an RFC, plan, review transcript, completion report, or hand-test diary.
Remove obsolete and duplicate content. Keep history in Git, not in an archive, generated copy, or directory that evades the budget.
Do not move current docs elsewhere to meet the limit. Keep generated PDFs, screenshots, and previews out of the inventory.
Audit ignored `.context/` notes and old reports the same way: delete obsolete plans and reports that contradict current policy, and correct mixed-topic notes without removing unrelated facts, secrets, or persistent user data. Do not move obsolete content into another copy.
Preserve current product, authorization, data-safety, and operational guarantees. Keep proof assumptions and verification limits explicit.
Repair current links and affected tooling. Drop obsolete prose checks instead of keeping filler for them.
Do not rewrite published migration sources or historical evidence only to update citations.

## Pull request text

Keep the PR template with only needed sections. Write a short `feat:`, `refactor:`, or `fix:` title, optionally scoped
(`feat(billing): add Cloudflare VM pricing`), and a few short sentences or bullets on the change.
Omit motivation, derivation, investigation history, test results, verification reports, limitations, and non-guarantees.
Keep test and review evidence in CI, commits, or chat.
A requested product policy change goes in the changed contract. The PR text only names it.

## External integrations

- Prefer official SDKs, then maintained popular libraries. To handwrite a protocol, document why libraries fail, isolate the adapter, and integration test it.
- A new artifact-acceptance, release, or service-availability gate needs an independent reviewer to assess its independent failure boundary and the user, operator, or deployer decision it changes. Without that, only delete or narrow such gates. Input validation and existing domain or authorization rules use normal code review. Trust successful CI and content-addressed releases: do not repeat their checks at runtime or keep checks only for tests, models, or reports.
- Before adding a hash, digest, signature, certificate, revision, credential, or identity check, document the concrete threat or user-visible failure, the independent authority for the expected value, the verification owner, and the fail-closed user result. A same-origin checksum, an online signature made in the same serving/primary-database trust domain, or a value with no behavior-changing consumer is no separate security boundary: keep it only as labeled provenance or diagnostics, or remove it. Expanding the protected threat boundary requires owner review.

## Runtime and data access

- Keep entity-owned behavior local. Use RPC only for distributed contracts.
- Bound request, render, and polling paths. No full fan-out scans: use cached, precomputed, or indexed data.
- Reconcile many children in a worker, queue, or pipeline. Keep interaction-critical state cheap to load and UI-shaped.
- Before adding polling, timers, or per-client refresh, estimate per-user/org cardinality and document the bound. Tests must reject unbounded per-child RPC and full scans.

## Tests

Keep tests proportional to the behavior and risk they protect. Actively remove low-value tests, not only obvious ones, without maximizing deletion counts at the cost of meaningful regressions:

- Remove tests that only prove a retired behavior, API, or identifier is absent. Test the current user or safety contract.
- Do not assert over implementation source, scripts, workflow text, or their AST. Move valid quality goals to behavior tests and delete redundant checks. Keep compiler, type, lint, and generated-file consistency checks.
- Do not snapshot trivial implementation properties, source phrases, prompt wording, CSS classes, literal schemas, or a helper's own declaration. Keep checks of externally meaningful output and real authorization or ownership boundaries.
- Avoid large case matrices that protect no distinct behavior or failure boundary.
- Prefer interaction, failure, and runtime-boundary evidence to assertions that repeat code or docs.
- Test business/user behavior. A fix needs a regression at the lowest layer showing the failure. Do not test-wrap simple repo checks.
- For modified tests, report old behavior, new behavior, and why.
- Tests do not use the real network: the harness fails off-machine connections ([details](docs/testing.md#no-real-network)).

## Review loops

Repeated same-class blockers signal an architecture problem. Before a second fix, author and reviewer must discuss whether the promise is wrong and narrowing is acceptable.
Weakening an existing product, API, operational, security, or data guarantee requires a human-owner decision recorded in the changed contract.
A guarantee new in the same unmerged PR may be narrowed there.
At the third round for one subsystem and class, stop fixes and await the owner's decision on a one-page structural-cause statement.

## Merge review gate

Merge only after review converges with no blockers. Non-blockers neither gate merge nor reset convergence. Classify by effect:

- **Behavioral blocker:** trusting it breaks correctness, data safety, security, or availability. Add and run a reproducible before-fail/after-pass E2E. Without one, it is not this type.
- **Semantic-contract blocker:** an authoritative contract contradicts the implementation and misleads a caller or operator. Show the claim, the wrong decision, and reality. Verify the fix against code or direct tests. No product red->green E2E is needed.
- **Non-blocking:** the worst effect is imprecision.

Artifact, importance, effort, and confidence do not set severity. Missing both blocker evidence bars means non-blocking.
A test that cannot fail on its defect cannot close a behavioral blocker. Later strengthening is non-blocking.
Before merge, audit relevant docs (design, protocol, API/storage, lifecycle, operations, hand-test), untouched ones too, against code and tests. Semantic drift blocks. Editorial drift may follow up.
Head changes re-run CI. Reviewer delta acknowledgment replaces an exact-head audit only for editorial changes.
Contract, operational, or behavior claims are semantic in any file type and re-run applicable gates.

## Worktrees

Use the current checkout for one PR or sequential PRs and phases. Add a worktree only for a parallel PR, at most one per extra concurrent PR.
After a branch merges, switch its checkout back to `main` and reuse it.
If no parallel PR needs it, remove the clean worktree. Preserve uncommitted changes and work owned by others.
