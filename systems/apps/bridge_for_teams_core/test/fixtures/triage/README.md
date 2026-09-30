# Online-shaped Triage cases

Current participation contract (owner decision, 2026-09-12): keep the selected
online profiles. Intake selects one Worker. Code creates one canonical Task.
The Worker reads original evidence and the current source thread, then chooses
reply, reaction or silence through `internal.triage.complete`. Code publishes the
initial result and settles the Task. Router does not polish that result or run
an initial model turn. A confirmed public reply admits ordinary follow-ups to
Router with the same Task. Ambient Triage does not publish Task cards.
Use the collaboration composition replay for this current contract.
Earlier Router-polished, card-only, evidence-first and peer-review treatments
below are historical diagnostics, not current acceptance criteria.

The native engine harness stops at a persisted Worker assignment. Its six
ordinary scenarios require the quiet period and one existing Worker. The
`slack_permalink_assignment` case checks the frozen link in that handoff.
These tests do not execute the Worker or prove reply quality or delivery.
`Online.replay` sends a captured input to the current evaluator. It does not
replay a stored terminal. Old inputs without a Worker roster remain unchanged
and must fail the current assignment contract. Their fidelity tests do not
prove current participation quality. Worker composition and Investigation
runtime tests cover the current source-read and completion path.

`online_cases_20260907.json` derives from the two stored online model inputs
investigated on 2026-09-07, not from a newly authored question. Raw captures and
production run/Slack coordinates stay outside the repository. Customer/person
and endpoint display names are replaced; opaque aliases and source references,
fact ordering, missing context, conflicting facts and actor classification stay
unchanged. The referenced reply's media filename/coordinates are also replaced.

## Direct correction controls (2026-09-11)

`Corpus.direct_correction_cases/0` adds three separately tagged live cases. The
Calendar variant preserves the original source messages and cutoff. Only its
optional mirror history/replies callbacks are absent: production MessageRead
uses finite captured HTTP pages. This is a conditional transport fixture, not
proof of historical Slack coverage or a repaired mirror watermark. The original
eight cases retain their original reader and expectations.

`direct_answer_controls_20260911.json` contains two explicitly synthetic
controls: a request to stop an unnecessary reminder, and a question whose time
and location are already stated. Both explicitly address Comma and use the direct-command lane. Neither may create
a Task. Expected answers
remain observer-only data; they are not inserted into provider requests.

Run with the same explicit Router and Worker profiles as the composition suite:

```sh
mix test \
  apps/bridge_for_teams_core/test/contexts/triage_investigation_composition_test.exs \
  apps/bridge_for_teams_core/test/contexts/triage_collaboration_composition_test.exs \
  --only triage_direct_correction_case --seed 0
```

Each case keeps the existing 300-second/40-call budget. The observer requires
the exact source receipt and Router acknowledgement, no unresolved provider
reply obligation, and delivery to the approved thread. A Task must finish with
an eligible Worker result, its actual return acknowledged by the Router, and
the final card delivered. Initial direct-Task cards and progress updates remain
valid. The Calendar case also requires completed, unfiltered capability
discovery before its final result; listing Tasks or apologizing alone cannot
pass. Empty local connector/device inventories establish an unavailable-source
result only. They do not establish any real Calendar or Comma event state.
Complete public replies still need independent source-grounded review.

## Supplied screenshot read (2026-09-11)

`Corpus.subscription_screenshot_original/0` preserves the ambient question
`这个会封号吗 :doge:` and its original PNG. The later bot reply asking the user to
describe the already supplied image is held out. The source text does not name
the provider visible in the image. Keep the unchanged source bytes at
`$COMMA_TRIAGE_COLLABORATION_CACHE/subscription-original-FSUBSCRIPTION001.png`.

Run the same two composition files with
`--only triage_subscription_screenshot_original --seed 0`. The case keeps the
ordinary reader, permissions, selected role profiles and 300-second/40-call
budget. Set `COMMA_TRIAGE_LIVE_SUPPORTS_IMAGES` and
`COMMA_TRIAGE_WORKER_SUPPORTS_IMAGES` to `true` or `false` from each selected
template. The fixture preserves this capability when it creates local agents;
the model name alone does not enable `fs.read_file` image input. It requires
investigation without an upfront request to describe the
image, then checks that the original PNG bytes reached a successful native
Worker image request before the committed result. Normal Task return and
authorized simulated Slack delivery must also finish. This is separate from
the original eight cases. Image receipt alone does not verify platform terms,
prove an account is safe from enforcement, or establish online delivery.

## Preserved observations

| Dimension            | Bare forwarded reply                                                                                                           | Token report                                                                                 |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Trigger              | One bare link; no question or mention                                                                                          | One token-revocation question; no readable link                                              |
| Frozen event         | Human, ambient, not fast-path                                                                                                  | Human, ambient, not fast-path                                                                |
| Frozen message actor | Human                                                                                                                          | System; preserved as observed, not silently corrected                                        |
| Context              | One member, 20 retained facts, including conflicting model claims and a preference not to start a bot for a casual video share | Same bounded retained context; no invented incident answer                                   |
| Referenced source    | Existing BFT media-search progress reply, itself containing a cross-channel video link; two image searches still failing       | No tool source in the stored input; the Slack attachment was not present in that model input |
| Historical calls     | One web read returned Slack application script, then a second model request                                                    | One model request, no tools; a proposed investigation did not become a Task                  |
| Model budget         | Responses, low effort, 4,096 output tokens                                                                                     | Same                                                                                         |

The bare-link case must not require a reply or Task: reading the source can
justify silence when it adds no value. Do not transform it into a release
question with a planted answer. The token case must not receive later migration
explanations, repair PRs, screenshot OCR that was not captured, or a preselected
Worker. A tool result is another speaker's source claim, not evidence that this
replay itself searched or inspected media.

The linked reply body was read back from Slack while preparing this fixture;
its edit history was not captured. Its timestamp precedes the decision, but
historical body-byte identity is therefore unverified. Later thread replies are
not included. The frozen evaluator snapshots, in contrast, came from the stored
online runs and do not inherit the current thread's later content.

## Replay boundary and remaining differences

`TriageOnlineCaseFixture.replay/2` sends the preserved snapshot through the
current real evaluator and configured provider adapter. Responses loopback tests compare the actual outbound
user input with the fixture, including message/fact/member cardinality, tool
availability, budget and lack of later answers. The linked source uses real
authorization and dispatch against loopback Slack; current source-reading code
is the treatment, not a historically identical web tool.

This replay starts **after context freezing**. It does not verify ClickHouse
ingestion, context assembly, the Runtime fence, default worker scheduling, Task
execution or source delivery. The separate synthetic composition test still
covers those portions it actually exercises; it is not a substitute for these
online inputs. The separate three-Worker execution probe below now verifies the
existing downstream mechanics through an explicit test-only handoff. Production
Triage handoff and investigation-quality acceptance remain pending. The historical
ambiguous-worker result proves no unique Worker was selected, not that a Task was created.

Historical `openai/gpt-6-astra` is provenance only. It is never selected from the
fixture. Live tests use the current deployed Router's complete profile, including
Astra when that is the deployed model, and require its model to match the
explicit expected-model pin. Any difference from the historical model must be
reported, not described as an identical online replay. A different provider
endpoint or unavailable historical source also remains an explicit difference.

## Commands

Use the existing isolated local PostgreSQL configuration. From `systems/`:

```sh
mix test apps/bridge_for_teams_core/test/contexts/triage_engine_live_acceptance_test.exs --exclude live_llm
```

After reading the current deployed Router's complete provider profile and keeping its key
only in the process environment:

```sh
mix test apps/bridge_for_teams_core/test/contexts/triage_engine_live_acceptance_test.exs --only online_case_quality
```

The pair costs three model requests. Its output records the historical/tested
model, decision, elapsed time and request count. Passing wire or shape checks
does not establish useful model judgment or completed investigation.

Do not combine a scenario-specific `--only` with `--include live_llm`: ExUnit
includes either matching tag, which would run every live test, not only the pair.
The expected-model and credential preflight still applies to the selected test.

## Historical baseline run: 2026-09-07 05:00 UTC

The deployed Router resolved `google/gemini-3.8-flash`, provider `gemini`, through
its current gateway and credential. Its omitted protocol means Chat Completions
under the production provider resolver; it must not be replaced with Responses.
The template budget was 65,536 with medium reasoning; the Triage entrypoint's
normal clamp produced actual requests with `reasoning_effort=low` and
`max_tokens=4096`. No online configuration or Slack messages were changed.

All three live tests ran: 12 provider requests including preflight, 57.7 seconds,
2 test cases passed and 1 failed. This is not a green quality acceptance:

- Bare forwarded reply: one successful exact Slack source read, then silence
  (`no_actionable_request`), no delegation; two model requests. It did not ask
  for the source again or claim to have searched the referenced media itself.
- Token report: silence (`insufficient_evidence`), no delegation; one request.
  The replay shape passed, but investigation and result return remain unverified.
- Synthetic Slack-source question: the reply included the separately read
  10 percent / 30 minutes / 0.5 percent conditions; two requests.
- Six-scenario regression: the unanswered rollback-window question was ignored
  (`no_actionable_request`), and a public outage still awaiting recovery was
  incorrectly called `already_answered`. The frozen durable input was read back:
  all three question messages and both outage updates were present, the decision
  targets were correct, and neither target had another explicit addressee.
  This rules out missing thread input for these failures; it does not establish
  whether a prompt change or model behavior is the underlying cause.

The remaining synthetic discussion/answer/already-answered/durable-decision
scenarios produced valid replayable decisions. Raw local evidence remains
outside the repository; test counts do not imply Task execution or delivery.

After the profile guard and tag-selection correction, the combined local
Pipeline/RunFence/Ledger/SlackEffectAdapter/Router-Task/native/engine regression
passed 108 tests (3 live tests excluded in that deterministic command).
Formatting and `git diff --check` passed. The separate live quality failure above
was not replaced by these deterministic passes. Subsequent live results follow.

## Current source classification and live reruns

A later read-only lookup of the token run's exact stored private source bundle
confirmed `file_share`, a present human user, and no bot ID/profile/app identity.
The old reader classified any nonempty subtype as system. The fixture now stores
only those de-identified source metadata facts next to the untouched snapshot.
The current classifier preserves human authorship for `file_share`, `me_message`
and `thread_broadcast`; bot evidence still takes precedence and actual system
subtypes stay system. See Slack's [message subtype reference](https://docs.slack.dev/reference/events/message/).

`replay(id, profile, source_projection: :current)` is a separately named treatment:
the real CH reader derives the actor from that captured raw shape, while every
other outbound snapshot field stays byte-equivalent after canonical encoding.
It does not restore attachments or re-run the full online context assembly.
The original SYSTEM snapshot remains a fidelity control, not a current-source
quality test. A separate deterministic Runtime/source/freeze/wire/proof test
checks that a human file-share question remains human throughout that chain.

Immutable raw-page v3/v4 audit bundles may lack an explicit actor kind. Their old
classification must remain stable in both normalized-context and transport-hash
verification; the regression covers both schemas and rejects using today's rule
to reinterpret an old proof. Existing classified snapshots are never rewritten.

Run the current-source model probe with `--only current_source_quality` (one
request); the full live file now has four tests and thirteen requests including
preflight. `COMMA_TRIAGE_TRACE_TOOL_CALLS=1` optionally records actual assistant tool
calls through a fixture-only observer that returns the real provider result
unchanged. It does not fabricate a tool outcome or alter production runtime.

All whole-suite reruns used the freshly resolved current Router profile above:

| Run | Result                                | Outcome evidence                                                                                                                                                                                                                                                                                                     |
| --- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R2  | 0/3 passed, 9 requests                | Initial prompt clarification did not fix the ambient question; two source cases rejected invalid read-call targets before Slack HTTP. The token case was not reached.                                                                                                                                                |
| R3  | 2/3 passed, 12 requests               | After removing the silence-only JSON example and disclosing exact Slack call arguments, the six scenarios and source question passed. The historical SYSTEM token question still produced no investigation.                                                                                                          |
| R4  | 3/4 passed, 13 requests, 47.8 seconds | Current-source token projection produced a scoped investigation delegation; both Slack reads passed. The ambient rollback-window question again returned `no_actionable_request`, so the suite is still **not green**. The unresolved outage retained a two-hour recovery follow-up rather than claiming completion. |

The narrowed tool-argument schema has its own before-fail/after-pass wire test;
sampling alone does not establish that it caused the observed source success.
Likewise R3's question pass did not prove a reliable prompt fix: R4 disproved
that conclusion. No further same-class prompt patch or sampling-until-green is
used here. A valid delegation proposal does not close Router/Worker execution;
the separately scoped downstream probe follows.

## Three-Worker downstream capability probe

`triage_investigation_composition_test.exs` uses the current-source token question
with the real evaluator, then **manually bridges its delegation in test code** to
the existing product-system Router ingress. This is not the production
`TriageDelegation` edge, which still rejects multiple active Workers.

Three real product/control Workers advertise distinct, honest specialties. Only
the authentication Worker's VFS contains the synthetic diagnostic artifact and
its random incident identifier; neither the Router handoff nor Task instruction
contains that identifier or the incident answer. Actual model-selected tools,
Task/Conversation owners and participant delivery execute. ClickHouse context,
OAuth/group context, S3 and Slack transport retain the explicitly documented
local fixture seams. It proves neither access to online incident evidence nor
the original incident's cause.

Run in the isolated test process/store, with the same complete profile variables
as above plus `COMMA_TRIAGE_LIVE_REASONING_EFFORT` and
`COMMA_TRIAGE_LIVE_CONTEXT_TOKENS`. `COMMA_TRIAGE_LIVE_PROTOCOL` must be present;
an empty value intentionally preserves the deployed Chat Completions default.
No key or provider fallback is used. From `systems/`:

```sh
mix test apps/bridge_for_teams_core/test/contexts/triage_investigation_composition_test.exs \
  --only triage_investigation_composition
```

The pass-through provider permits at most 24 invocations over five minutes,
including the evaluator and downstream Agents. It counts provider entries, not
the provider's own HTTP retry attempts. Runtime agents preserve the current
template reasoning/context/output budgets; those historical runs used Triage's
then-current low/4096 clamp. The fixture permits only its listed read/Task/card tools and rejects
unknown Slack operations. There are no online Slack writes.

| Run | Result                                                                 | Boundary reached                                                                                                                                                                                                                                                                                   |
| --- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Fixture observation failed, 39.9 seconds; invocation count unavailable | Auth Worker selected, Task result and source card contained the artifact identifier, and Router received it. The assertion read an async-running receipt instead of the committed tool result. Reasoning/context profile fields were not yet propagated, so this is not complete-profile evidence. |
| 2   | Fixture observation failed, 96.8 seconds, 13 invocations               | Complete current profile; reached `ready_for_review`. The capture assertion incorrectly treated form-encoded metadata JSON as a map.                                                                                                                                                               |
| 3   | Execution test passed, 49.8 seconds, 12 invocations                    | Real `agent.list` preceded Task create; correct auth Worker read its VFS; one canonical result Message reached Router with matching identity; one Task became `ready_for_review`; exact source card used one post and two updates.                                                                 |

Both fixture corrections preserve the behavior assertions: read the actual
committed async result; decode known nested Slack JSON fields at capture. No
runtime fix, forced Worker result, extra model retry, or lifecycle bypass was
introduced. Known invocation count for runs 2+3 is 25; run 1 and monetary/token
cost totals are unavailable, not zero.

**The passing execution test is not full content-quality acceptance.** Parent
inspection of Run 3's actual result found an overclaim: it converted
`last_refresh_attempt_at: null` (no recorded attempt) into a statement that the
client never attempted refresh, then presented that as the cause. The artifact
supports an expired access token, an unrevoked refresh token and absent recorded
refresh; it does not prove no attempt occurred or exclude every alternative.
The marker/error assertions do not detect that distinction. This observed
quality failure remains open, alongside the ambient-question failure above.

Production Triage-to-Router admission, stable Task identity across Session
rotation, source/Task linkage back into the Triage UI and real Slack acceptance
are not covered by this test-only bridge. The test does not claim a second
result queue or Task lifecycle is needed.

## Owner-approved quality-first budget differential

The owner subsequently accepted higher cost and latency. The current product
candidate is **medium / 16,384 output tokens**, capped further by the selected
Agent's own lower limit. Ordinary non-product Triage retains its Agent options.
The prompt text, model, request admission (at most two), no-retry policy and
150-second Runtime lease are unchanged by this experiment. The historical
low/4096 measurements above remain failed evidence, not the current policy.

| Treatment      | Full-suite result                                                                                            | Elapsed | Provider entries | Reported prompt / completion tokens |
| -------------- | ------------------------------------------------------------------------------------------------------------ | ------- | ---------------- | ----------------------------------- |
| medium / 4096  | 3/4; six-scenario test stopped at invalid fast-path decision                                                 | 132.7 s | 9                | 38,942 / 15,570                     |
| medium / 16384 | First 4/4 pass; six scenarios, two frozen cases, authorized-source reply and current-source token projection | 169.7 s | 12               | 49,837 / 21,289                     |

The entries/usage in this budget table exclude one existing preflight request per
suite: the actual provider-entry totals were **10** and **13**, respectively.
Preflight usage was not recorded, so those token sums are partial, not full cost.
Final audit corrected this omission; future runs pass the same existing preflight
through the read-only observer too, without adding a request.

The failed output reported 4092 completion tokens. Budget pressure is a plausible
explanation, not confirmed truncation: the raw finish reason was not retained.
The passing run does not establish reliability or finish the Worker/Task goal.
The tests have different executed-case counts due to the first early failure;
their totals are not an equal-work latency/cost comparison. Monetary cost is unknown.

Replay now treats historical wire options as provenance only and uses the current
runtime profile plus current evaluator policy. Captured JSON remains unchanged.
The wire fixture's old 2000-token toy profile is replaced with 65536, verifying
the actual request clamps at 16384. Native before/after: 42/43 then 43/43; wire:
8/8. Only the budget/policy-version expectations changed, not outcome assertions.

The composition probe now separately judges the actual delivered report against
its artifact, in one additional provider call using the same current profile.
It calibrates on a grounded control and the historical unsupported causal claim
in the same call. Invalid output, failed calibration, or an unsupported actual
report fails acceptance. This is a test-only semantic check, not a production
gate, and model judgment remains evidence rather than an infallible oracle.

## Production handoff and evidence-first acceptance

The composition file now enters production Runtime and the terminal fence, loads
the immutable PG obligation, and invokes the real ProductEffectWorker delegation
adapter. It no longer inserts a test-only Triage-to-Router bridge. Initial source
authority uses the same production route-owner claim as the other live fixtures;
the CH rows, S3, OAuth/group fixture and loopback Slack remain explicit seams.

| Production-path run | Result                              | Evidence                                                                                                                                                                                                         |
| ------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1                   | Failed, 15.4 s, 1 provider entry    | Fixture omitted the route owner that patrol normally supplies; real freshness rejected `source_unavailable`. Fixed fixture admission, not production checks.                                                     |
| 2                   | Failed observer, 79.1 s, 11 entries | Task/result/card reached; prompt audit incorrectly inspected only `system` roles, whereas the runtime carries its frozen prompt as `summary`.                                                                    |
| 3                   | Failed quality, 83.0 s, 13 entries  | Every Worker request demonstrably received the evidence rule. Actual report still inferred no refresh attempt from a null record and broadened the snapshot's revocation claim. Calibrated assessor rejected it. |

The new candidate uses an evidence-first ordinary Task: Worker returns source
observations and attaches the existing evidence; Router reads the exact Message
attachment in its own VFS before forming and sending the conclusion in that Task.
No new state, publication gate, Workflow or second Task is introduced. The live
test requires actual attachment transfer/read and final-send ordering; it also
checks all canonical messages and every rendered Slack card revision, not merely
the first Worker report. Interim progress must be grounded; both final Router
message and final card must be grounded and useful. A third control establishes
that the assessor does not demand a complete diagnosis from factual progress.
No evidence-first quality success is claimed; the recorded treatment failed below.

### Evidence-first results and observer limits

| Run | Result                                                                                                                                                                                        | Provider entry calls                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| R1  | Failed in 112.2 s on quote comparison retaining Markdown delimiters; actual Worker and Router reports also overclaimed absence of refresh/revocation.                                         | 17                                  |
| R2  | Failed in 120.5 s on an observer requiring `read_conversation` despite the exact delivered Message already materializing the original attachment in Router VFS. Actual source read succeeded. | 16                                  |
| R3  | Failed quality in 285.6 s after all Task/attachment/source-card mechanics passed. Worker and intermediate/final card text retained unsupported causal or revocation claims.                   | 20 (15 runtime, 5 assessor batches) |

R2 used a neutral Worker profile following its assigned deliverable rather than
forcing a diagnosis. The attachment contract now accepts the exact delivered
Message or an exact later read as the source of the reader-local path, and still
requires original bytes, actual Router `fs.read_file`, and subsequent canonical
result delivery. Production uses the existing attachment materializer, not a new
fallback/synchronization protocol.

Current probe bound is **40 provider entries over five minutes**, not the original
24 above. The whole current online profile is preserved. Assessments use batches
of at most two actual surfaces plus three controls per batch; all controls must
calibrate and every returned quote must match the sample's visible wording
(ignoring only whitespace and Markdown emphasis/code delimiters). R3 controls
all calibrated but its Router verdict still missed an overclaim. Its final-card
verdict also wrongly objected to legitimate source/path references as well as a
real unsupported claim. Model assessment is fallible, not an authority.

The search flattener previously used as a card observer deduplicated repeated
inline fragments, dropping a later `token_expired` within a sentence. The current
test-only `TriageTaskCardText` observes the actual native-card fields in order,
preserves repeated inline text, and fails on unknown shapes. A deterministic
test renders a real native card containing repeated code, earlier details, lists
and source links. Raw Slack wire payloads are retained by future live runs.
Operational references are no longer themselves treated as extra diagnostic
claims by the assessor. This is wire-text observation, not Slack-client pixel
acceptance; production search behavior is unchanged. No fresh quality pass is
claimed after these observer corrections.

The proposed independent pre-publication review changes the Triage source card's
immediate-Worker-body contract. It is **not implemented**, pending the concrete
owner decision recorded in `docs/bridge-for-teams/design.md`.

## Final repeat and local test-budget correction

The first unchanged medium/16384 repeat finished **3/4 in 208.8 s**, but the six-
scenario test stopped before its sixth scenario when BFT/Billing sandbox owners
expired after the default120000ms. The log explicitly records that timeout;
this is not an additional model-quality verdict or a successful full repeat.
It made12observed provider entries including preflight, with complete reported
usage46,282prompt +19,562completion =65,844tokens; HTTP retries and money remain
unmeasured. The other three source/replay tests passed.

The live module already permits900000ms for the six sequential model scenarios.
Its SQL sandbox ownership now has the same explicit900000ms test-only limit,
using DataCase's existing tag. No production inference budget, Runtime lease,
retry count, or scenario expectation changes. The next full repeat is recorded
separately, preserving this failed attempt.

Final full repeat: **4/4 passed**, eight deterministic wire tests excluded,
105.2s, **13 provider entries including preflight**. All entries reported usage:
49,838prompt +21,592completion =**71,430tokens**. The current read-only selected
profile remained Gemini/medium; product clamp remained medium/16384. Provider
HTTP retry counts, price and gateway cache behavior were not measured, so the
latency difference and repeated pass are not causal performance or independent-
sample reliability evidence. The separate investigation-content probe remains
failed; this four-case decision/replay suite does not close that outcome.

## Silent investigation owner correction (2026-09-07)

The owner rejected early progress: investigate silently and publish when the
result returns. Production handoff, shared internal/external Router instructions,
Slack manual and Triage policy v18 now agree. A delegated investigation with no
substantive answer uses silence/insufficient_evidence; supported direct answers
and genuinely necessary clarifications remain allowed. The ordinary Task gets
the evidence and Router result, then ready_for_review, then its existing native
card. There is no added publication gate or delivery protocol. The card still
includes its ordinary bounded recent-message window, not only the final sentence.

The composition probe observes canonical Task status and Messages at every
loopback Slack request, before returning the HTTP receipt. Its first write must
already have the exact committed Router result and ready_for_review. Ordinary
post_message, add_reaction and bind_thread_to_task remain callable; hiding these
operations is not the silence oracle. The test still checks content separately
and must not be relabelled as an overall pass when only timing passes.

Before:111.1s,12provider entries; first card appeared at active with only the
initial command, and the new timing assertion failed. After:221.5s,23entries;
immediate Triage silence/no companion reaction, one chat.postMessage only,
first-write exact Task ready_for_review with the Worker evidence and Router
result already committed. All timing/Task/source/attachment assertions passed.
Content quality still failed on actual Worker, Router and card overclaims about
absent refresh records and snapshot revocation state. Keep that failed run.
Contract tests first failed2/47, then98passed with4live exclusions across the
four relevant files. No production model/profile or online Slack state changed.

The v18 decision-suite replay first failed before model invocation while reading
the live profile; a read-only Pod check was Ready and the next exact profile
read succeeded. Full replay:3/4passed,8excluded,210.6s,11entries; the frozen-source
case failed on Req.TransportError reason=closed, while the other cases including
the six-scenario direct-answer/silence checks passed. Only that interrupted case
was rerun unchanged:1passed,11excluded,32.8s,3entries. Do not label these separate
runs a single4/4 pass. Full-run reported usage57,322tokens omits one failed entry
with no usage; focused rerun reports19,564tokens with none missing. No production
retry policy changed. Final eight changed Elixir files and diff checks pass.

## Rejected evidence-revision candidate and inference diagnostics

The additional fresh-context `analysis.revise_with_evidence` writing tool was
removed after full composition R1/R2 both retained delivered factual errors.
Its successful mechanical tests did not establish semantic improvement. The
production handoff no longer requests that capability. Original Task identity,
attachment read, silence until returned result, and independent quality checks
remain; removing helper-specific assertions is not a relaxation of report quality.

`investigation_reasoning_framing.json` freezes the actual earlier local command,
Worker/Router reports and synthetic artifact. `investigation_evidence_revision.json`
freezes R2 helper outputs and first-write canonical texts. Its artifact is
explicitly reconstructed from the deterministic fixture plus observed incident
marker, not a captured R2 helper input or HTTP wire. The rejected helper's exact
instruction is frozen there so the diagnostic does not depend on a deleted
production source file. No credentials or private model reasoning are included.

`triage_investigation_reasoning_probe_test.exs` is inference-only and opt-in.
It requires the explicitly selected complete profile: model, expected model,
provider, base URL, protocol (empty is the explicit Chat default), API-key env
name with its value present, reasoning effort, max tokens and context tokens.
After supplying that test environment, run one diagnostic with:

```sh
mix test apps/bridge_for_teams_core/test/contexts/triage_investigation_reasoning_probe_test.exs --only triage_claim_findings_probe
mix test apps/bridge_for_teams_core/test/contexts/triage_investigation_reasoning_probe_test.exs --only triage_evidence_only_probe
```

Each test's PASS means the bounded inference request(s) and output observation
completed, **not that the generated answer is correct**. Exact full outputs
must be read against the supplied evidence; calibrated model assessors have
already missed mixed good/bad reports. Do not inspect only the caveat section.

Observed with current Gemini3.8Flash/medium/65536: explicit findings followed by
rewrite still overclaimed revocation (one entry,27.108s,6445reported tokens).
Source-only sparse/historical/complete-window arms all retained scope errors
(three entries,41.4s,6824reported tokens). Historical and complete-window evidence
are labeled synthetic counterfactuals, not additions to an actual incident.
Sparse also turned observation time into request time and null into no refresh;
complete-window input allowed a ten-minute negative result but output said
“从未”. These observations reject a simple source-only replacement; they do not
prove a universal model limitation. Three production quality candidates have
failed; another implementation awaits the owner decision recorded in
`docs/bridge-for-teams/design.md`.

## Per-role profile correction and bounded counterfactual diagnostics

The previous stop statement applies to another production quality fix, not to
safe local investigation. Current read-only resolution of the project's Router
and selected internal `dev` Worker found different actual profiles: Router uses
Gemini 3.8 Flash/medium with the default Chat protocol; Worker uses Sol/Responses
with no explicit reasoning-effort key. Previous all-Gemini compositions remain
valid homogeneous diagnostics, not evidence for this actual role combination.

The composition fixture now requires separate `COMMA_TRIAGE_WORKER_*` settings
(including `EXPECTED_MODEL`) alongside the existing Router environment. An
explicitly empty Router or Worker `REASONING_EFFORT` preserves absence of the setting;
missing configuration never falls back to the Router. Observed Triage requests
retain the selected Router profile with the existing product medium/16,384
output bound. Ordinary Router and Worker requests retain their own profiles.
The three local specialties still share one selected internal Worker profile;
this is not the full online roster or external-runtime acceptance.

The same three source-only inputs were also run against existing Astra/low and
the actual internal Sol Worker configuration. Astra/low took 34.4 seconds and
2,090 reported tokens; one historical report still presupposed a failed renewal.
Sol took 26.3 seconds and 2,313 reported tokens, retaining unsupported refresh
premises and request/observation-time confusion. Neither is content acceptance.
An explicitly local Astra/high treatment took 72.3 seconds and 3,572 reported
tokens. Independent full-text comparison found no demonstrated material error
in those three outputs. This covers only these synthetic source-only samples,
not a Task loop, repeatability, or online behavior. Protocol and effort differ
between some arms, so differences cannot all be attributed to model identity.

The six new role-profile regressions plus the existing result observer pass
(seven tests; one live composition excluded). Actual-role composition R1 then
completed in 168.7 seconds/17 provider entries/223,837 reported tokens. All
mechanical/profile checks passed and the model assessor returned true, but
independent full-text review found a definite unsupported no-refresh cause and
a fabricated request time in the Router/card. This is a concrete false-green
semantic assessment; the matching-profile run does not pass quality acceptance.

Worker-only Astra/high R1 ended on the first unchanged Gemini Triage request's
transport close, before Worker execution, with unknown usage. One retained
same-condition retry completed in 198.6 seconds/23 entries/300,192 reported
tokens. Its eight captured surfaces had no demonstrated material error under
independent full-text review; the Worker also challenged an ambiguous Router
summary and the correction reached an updated card. The automatic assessor
inconsistently accepted the canonical Router text but rejected its rendered
copy. Neither automatic true nor false substitutes for checking the evidence.

That second run is still incomplete as a whole-loop observation: product
requests continued after its quality snapshot froze. Sequential per-session
quiet checks do not prove both actors and their later deliveries have finished.
The next test-only correction compares exact Task messages, title/status and
card writes again after scoring, refusing an unassessed changed snapshot rather
than silently resampling it. No production quiescence or publication gate is
added. The next local run retains the narrower Worker-only treatment to resolve
this specific observation gap before changing any more roles.

Subsequent Worker-only R3 exposed a test timing error: a legitimate later Router
correction was incorrectly required to exist before the first card. The observer
now selects a Router result after the exact returned Worker message in the first
write's canonical sequence; it still checks both the first and latest Router
results and all delivered card text. Twelve pure tests passed. R4 correctly
detected a changed end snapshot (4 messages/2 writes became 5/3). Independent
review of its emitted final snapshot found an unsupported failed-token-exchange
premise in the initial Worker/Router/card, despite a later accurate correction.
The Worker-only treatment is not stable acceptance; old failures are retained.

Source-only same-model/high diagnostics also retained scope errors: Sol took
30.639s/2,440 reported tokens; Gemini took52.490s/8,820. All-role Astra/high R1
(Triage still uses the product medium/16,384 clamp) yielded eight captured
surfaces without a demonstrated material content error under independent review.
Its test nevertheless failed after302.9s:33 admitted/completed provider entries,
498,857 reported tokens, and the five-minute test entry budget prevented the
next assessment call. Later Router work was not included in the earlier capture;
no complete lifecycle/snapshot or repeatability acceptance is claimed.

That run also exposed an existing fixture boundary: discovery and Slack thread
read tools were disabled, and loopback did not serve thread reads. A Worker
report of help returning only resolved is not proof of a production missing
manual: disabled help returns private guidance, which the existing clean-context
privacy projection can replace with that marker. A test-only correction is now
restoring exact-source local read support and adding a no-LLM control for the
guidance projection. Privacy policy and all online settings remain unchanged.
Prior runs remain explicitly unavailable-Slack-read diagnostics. The next normal
read composition returns to the actual online-equivalent Router/Worker profiles.

The correction's eighteen non-LLM observer tests now pass. Correct disabled-help
envelopes produce real guidance, retained during repair and projected to resolved
only in clean context; allowed fs.read_file help retains its real manual/schema.
Loopback tests exercise actual GET-query/POST-form contracts, short-page cursor
continuation, an empty terminal page and exact-scope rejection. They do not add
incident facts. An assessment exception now still captures the current public
Task/messages/cards before reraising the original failure, without retrying or
increasing the five-minute/40-entry bound. Actual-role normal-read composition
is the next separate live validation; enabled tools alone are not read receipts.

## Normal-read role comparison and final regression evidence

Actual online-equivalent Gemini Router + Sol Worker normal-read composition
completed in 187.5s with 24 provider entries and 328,302 reported tokens. It
failed quality: the final snapshot retained five messages and three card writes,
and the final Router/card still presupposed that no refresh had been initiated
from a null record. A later correction of the revocation claim did not correct
that refresh premise. The old successful-end summary did not preserve read
receipts on this failed path; enabled read tools alone prove no actual traversal.

The observer now records read request/response pairs before and after assessment,
independently of the final pass/fail summary. Eighteen non-LLM observer tests pass.
The narrower local Router-side Astra/high diagnostic retains Sol Worker's actual
profile. Triage also inherits Astra's model from the Router template but keeps
its own medium/16,384 clamp, so this does not isolate the final Router call alone.
Defaults and online configuration remain unchanged.

This treatment ran once:355.5s,33 admitted entries with complete usage,
502,101 reported tokens including assessment. Its fourth assessment batch was
denied by the existing five-minute entry budget. The test remains failed; the
exception observer retained the final snapshot and verified that its five
messages/one card write were unchanged from before assessment, both observed
sessions were quiet, and the Task remained ready_for_review.

Actual captured loopback POST conversations.replies requests traverse the exact
source's short first page and empty terminal cursor page. Independent full-text
review found an unsupported premise in the first internal Worker report, then
an explicit Router request to correct it before publication, Worker withdrawal,
and a corrected final Router result. No material error was demonstrated in the
first published card, including its retained details, or final Router result.
This is pre-publication correction, not an earlier public error erased by a later
update. The test's separate per-working-message scoring has not been changed,
and the incomplete grader is not relabeled as an overall pass. One treatment
is not reliability or online-equivalent acceptance.

Latest deterministic52-file scope:897passed,2skipped,9liveexcluded,exit0;
58changed Elixir files pass format checking. Earlier890/891 and41/42 runs remain
recorded failures. The max-wait test now asserts an exact overdue generation
with fresh debounce-window members instead of relying on three admissions
fitting into a130ms wall-clock window. Production timing is unchanged. The
untouched stale-wake test passes in this latest broad run; its earlier failure
is not thereby explained or erased. Background SQL ownership noise also remains
in the successful log. These tests do not close the actual-profile content gap.

## Worker-authored answer with unchanged online role profiles

The owner rejected an expensive Router and approved correcting the earlier local
evidence-first role split. The production handoff, shared Router policy and Slack
manual now assign evidence collection, interpretation and complete user-facing
answer authorship to Worker. Router coordinates specific gaps, then sets
ready_for_review and publishes after the final Worker Message returns. It must
not append an acknowledgement or rewritten answer that replaces native output.
No renderer selector, final-result flag, lifecycle gate or protocol state was added.

The contract regressions changed from requiring a separate Router conclusion to
requiring Worker authorship and Router coordination. Old handoff/policy/manual
instructions failed the new exact assertions; all48 targeted tests now pass.
An initial manual test used a nonexistent workflow field and was corrected to
triage_investigation_publication before counting its semantic red result; two
initial policy line selectors selected an adjacent test and are not red evidence.

The composition observer now compares every actual native main
output with its captured canonical Worker's latest eligible Message, and to prove
that exact Message reached Router before first publication. Source identity,
original artifact bytes and reader-local delivery, silent-until-result timing,
Task status, single-card updates, role-profile fidelity, all visible content
quality and post-assessment snapshot checks remain in scope. A Router source
read or second Router diagnostic Message is no longer required. The next live
run keeps actual Gemini Router/Triage and actual selected Sol Worker profiles;
no content success or online change is claimed yet. All26 no-LLM observer tests
pass, and all59 currently changed Elixir files pass formatting. Independent
narrow review found no concrete authoring/contract blocker; this is not a model
quality result.

The first Worker-authored actual-profile run proved first native output authorship
and returned-before-publication order, but the Sol answer still contained false
no-refresh and request-time premises. It then stopped on a test-only decoding
bug: the delivered attachment blocks were stored as a Session JSON string. The
observer now accepts that actual wire and canonical block lists; the old helper
failed its dedicated JSON regression, and all27 observer/text tests pass after
correction. No production delivery format changed and the content failure remains.

A local Worker-Astra/high treatment, still with Gemini Router/Triage, produced a
complete1815-character report followed by a153-character clarification before
first publication. Main output became the clarification; details clipped the
report at1200characters, removing its concrete next steps. Independent review
found no demonstrated material error in the combined canonical report/correction,
but the published card was incomplete. No complete run/model-quality pass is claimed.

Author/reviewer discussion identified missing presentation context in the actual
Worker command. The handoff now passes native newest-message output/shortened
details into that command: finish with a self-contained answer within the existing
2500-character body and restate a full corrected answer for later corrections.
Router may request consolidation, not author it. The synthetic Worker profile
does not supply this missing context directly; inspect the real delegated command.
All48 handoff/policy/manual contract regressions passed after prior instructions
failed the three new assertions. Native recency, lifecycle and provider budgets
remain unchanged; the same role treatment is being checked after this explicit
composition correction, not resampled without a change.

Final-contracted comparison: Worker Astra/high R2 completed with one passing live
test,146.4s,15 provider entries and159575reported tokens including assessments.
All five surfaces were independently compared with the source; the938-character
answer was retained fully in the one card, no material error was demonstrated,
and the final snapshot was unchanged. Actual Router-to-Worker command included
the presentation context; native output was not a fragment. Original attachment,
reader-local delivery and returned-before-publication checks passed. Only an
emoji read was captured, not Slack thread paging. This remains one local treatment.

The same final contract with actual Sol Worker also completed mechanically:
117.8s,15 calls,166074reported tokens,one card,ready_for_review,unchanged snapshot.
ExUnit and automatic assessment were green, but independent source/full-content
review rejects the answer: it promotes10:05observation time to request time and
presupposes no refresh rather than retaining successful-refresh/stale-use as an
open alternative. Do not record unchanged-profile content acceptance from this
false-positive grader. There was no observer decoder error or Router re-authoring.
No more same-condition model samples are planned for this authorship change.

The first post-authorship 52-file regression finished902passed/1failed,2skipped,
9liveexcluded. The unchanged directed mid-thread PostgreSQL case queried all
namespaces while recovery could admit a prior ambient receipt in the default
namespace. A deterministic foreign-namespace ambient admission through the real
Admission path made the old global assertion fail. The query now counts every
lane only inside the case's own namespace; it does not filter away an unexpected
same-namespace ambient membership. The no-root assertions remain unchanged and
all3 tests in the file pass. No runtime recovery or timing behavior was changed.
The final52-file rerun completed exit0:40store+161agent+380IM+143core+62SalixWeb+
117BFTWeb=903passed,2skipped,9liveexcluded. All60 changed Elixir files passed
format checking, and diff checking passed. The earlier failure is retained.
These deterministic results do not override the separately audited actual-Sol
content failure or turn the one local Astra/high sample into reliability evidence.

## Ordinary Worker tool surface and supplemental context

The owner identified an extra composition-only tool whitelist. Its original
purpose was external-effect isolation, but it also hid ordinary investigation
tools. The fixture no longer sets `disabled_tools` for either role. A real
fixture-created Agent/runtime/ToolDisclosure/help regression failed on Worker
`web.search` before removal and passes afterward; normal Worker role limits
(including Router-private memory and provider writes) remain unchanged.

External isolation now uses named local transport seams: selected real LLM
POST requests, exact loopback Slack, finite Exa runbook responses, S3 Fake,
empty connected-device/MCP inventories and unavailable Compute host transport.
These are not an OS-wide egress sandbox or a claim that all external services
are implemented. Unknown fixture reads fail explicitly, not as fake success.
Normal built-in plugins stay available; plugin visibility is not transport
authority. The launcher explicitly selects the Fake S3 backend.

This is a **new** five-message local scenario: the original sparse question and
VFS snapshot are unchanged; an ordinary source-thread reply links a separate
diagnostic thread containing a same-session refresh success and a subsequent
failed request using the old reference. No expected answer or new fact is
injected into initial Triage/Worker input. Ordinary history/replies use a finite
local reader; modern search retains real Group/connect/catalog/publication and
result-window checks but uses explicitly labeled case-insensitive term matching,
not real ClickHouse embeddings/ranking. A generic web runbook contains no incident
facts. Captures attribute actual context reads to the Worker; simply having the
tools is insufficient to pass the live composition.

The semantic assessment receives the separately labeled artifact, supplemental
corpus and runbook, and retains all canonical messages/card revisions/title and
attachment surfaces plus the unchanged-after-assessment check. Original source
attachment bytes, exact returned-before-publication Worker result, Worker-authored
native main output and silence before ready remain required.

Focused validation:47 passed,1 live excluded. The first combined attempt had5
context-test setup failures because its standalone Group lacked router_agent_id;
ordinary Slack visibility correctly rejected the unbound connect. Adding the
normal Router binding to that new test setup made all47 pass. The actual live
composition's seed already had that Router binding. No production policy was
changed. The new real-role run is reported separately; earlier sparse-evidence
model failures remain historical results, not retroactive passes.

The first new-scenario actual-role run completed its real Worker investigation
and stable single-card delivery in181.3s,20calls,476485reportedtokens. The Worker
followed the source-thread link and read the three supplemental diagnostic
messages; its1247-character full answer used successful-refresh/old-request
correlation, retained the unknown implementation step and preserved the original
attachment. All5surfaces received independent review: no material diagnosis or
full-answer error was demonstrated. This proves local history/replies use, not
modern semantic search or web execution by that model.

ExUnit still failed: the scorer rejected the card's `not_synced` statement because
its input omitted the actual MessageRead response envelope. The reader receipt
was before the production coverage annotation, so it could not settle that claim.
The failure is retained. The test now observes successful Slack READ results after
the real Provider and feeds their exact response envelopes into semantic evidence;
internal authored results and Slack writes are never source evidence. A real
Provider test confirms exact `incomplete.reason=not_synced` capture with unchanged
permissions/results, bounded non-secret query coordinates and exact cleanup.
The Worker's supplemental-evidence check now uses the returned Provider body,
not merely a reader invocation. All51focused tests pass,1liveexcluded;7file format
check passes. The repaired-observer same-profile run is reported next, separately
from the retained first-run grader failure; no model/prompt/corpus change was made.

Repaired-observer R2 completed132.8s,19calls,433221reportedtokens:1live test passed,
24observer tests excluded. The unchanged actual Sol Worker independently made
two ordinary get_thread_replies calls (source then linked diagnostic thread).
Both actual response envelopes carry incomplete.reason=not_synced and are now
retained in the assessment input. The complete Worker result uses the successful
refresh and later old-reference request, bounds the unknown cache/update step,
and remains the full one-card main output. Original attachment, exact return
before publication,ready_for_review and stable final snapshot all pass. This is
local finite-corpus acceptance; no web/modern-search use by this model, universal
reliability or online Slack acceptance is claimed. Independent R2 content review
and the55-file regression are recorded at completion below.

Final independent R2 review confirms all5whole surfaces have no demonstrated
material factual or delivery error: the1004-character Worker answer is retained
in full, original310-byte attachment matches, actual two Provider wrappers prove
not_synced, and the correlated events/remaining unknown implementation step are
handled correctly. Final55-file regression completed exit0:40store+161agent+
380IM+172core+62SalixWeb+117BFTWeb=932passed,2skipped,9liveexcluded. All66 changed
Elixir files pass format checking and diff checking passes. No online configuration,
Slack write, deployment, commit or PR operation was performed. These checks close
the normal-tool local scenario, not the prior sparse-evidence failures or general
online/model reliability.

## Persistent Goal: ordinary tools with missing and foreign evidence

The opt-in composition now accepts `COMMA_TRIAGE_INVESTIGATION_CASE=positive`,
`sparse`, or `wrong_session`; unset preserves the positive corpus. Only the
independently retrievable local data changes. Sparse has the original question
and no supplemental incident rows. Wrong-session links the same bot's other
incident, whose diagnostic identity is consistent across its root/refresh/request
rows. Initial artifact, ordinary roles, prompts, selected role profiles and
delivery protocol stay unchanged. The finite enum rejects unknown values.

Quality controls follow available evidence: a complete sparse investigation can
give a bounded finding and precise next check without pretending to know a root
cause. Only scenarios containing supplemental records assert acquisition of
those records; sparse does not impose a tool quota. Every visible surface and
post-assessment snapshot is still checked. Focused tests:56passed,1liveexcluded.

Actual-profile sparse R1:150.5s,19entries,418978reportedtokens,0/1passed,26excluded.
The Worker read the source through ordinary Provider, received only the question
and not_synced, returned its1508-character complete answer plus310-byte original
artifact, and published one unchanged Worker-authored card. Independent review
confirms a material unsupported no-refresh cause in the summary; subsequent
uncertainty does not retract it. Do not inflate that finding into a claim that
the report unequivocally says every system never called refresh or invents an
exact request timestamp. The automatic grader rejects the canonical answer but
accepts its rendered copy; it remains fallible and is not an independent oracle.

Actual-profile wrong-session R1:166.4s,21entries,487827reportedtokens,1passed,
26excluded. The Worker searched, read the source thread, excluded the foreign
incident and searched again. Actual response envelopes retain not_synced and the
empty current-incident result. Independent review of all5complete surfaces found
no demonstrated material error; the865-character answer and original attachment
remain intact in the unique stable card. This pass does not erase the sparse
failure. Both runs keep Gemini Router/Triage and the selected Sol Worker; neither
changes or validates real Slack/configuration/deployment.

The next diagnostic reuses the already-authorized local Worker-only Astra/high
treatment on the exact sparse scenario with ordinary tools. It is not a silent
replacement of current-profile acceptance, not an online mutation, and not a
new production prompt/review mechanism. Its result is recorded separately.

Worker-only Astra/high sparse R1 completed168.7s/26entries/630007reportedtokens;
wrong-session R1 completed136.3s/19entries/445572reportedtokens. Both opt-in runs
passed1test with26excluded, one complete Worker-authored card, unchanged original
attachment and stable final snapshot. Parent read both independent full-content
reports: no demonstrated material incident-content error across either set of
5surfaces. Sparse used three actual Worker-attributed thread/keyword/modern-index
reads; wrong-session used four actual reads. Run-level MCP/env empty inventories
lack per-agent attribution; public exports do not separately duplicate the VFS
read response, whose real Worker Session/committed result the composition asserts.
Do not turn those review limits into invented execution failures or broader
online/OS-wide guarantees. Both remain local candidates, not current-profile fixes.

`release_observation` adds one fully synthetic REL-204/staging/atlas-api question,
original job/verification export and five-message local corpus. Router discovers
the existing release specialty; its original prompt remains unchanged. The source
supplies the starting VFS path and read-only/full-attachment requirements, not the
diagnosis. Supplemental data separately records a2/3updated deployment snapshot
and the exact verification request reachingrev-203. The underlying rollout/routing
cause and full rollback history are absent. All dates match the August18source;
the generic runbook defines fields without supplying case outcomes.

Selected Worker, original artifact/path, report marker and evidence marker now
follow finite case data; old token source/artifact bytes and normal permissions
remain unchanged. Domain-matching judge controls replace token-only assumptions
for the release case. All61focused tests pass,1liveexcluded. First release/Sol
launch stopped before model entry because host GCP credential refresh requires
interactive reauthentication; this is pending validation, not a failed report.
Current host executable/config/account and network were checked, including the
same refresh error with supported Python3.11. Do not retry until login is restored.

Final Goal-phase55-file regression exits0:40store+161agent+380IM+182core+
62SalixWeb+117BFTWeb=942passed,2skipped,9liveexcluded. All66changedElixirfiles
pass format checking and diff checking passes. This does not close the pending
release-domain model run, the current-profile sparse content failure, online
delivery or user acceptance.

## Resumed Goal: release evidence and source-locator diagnosis

Host GCP authentication was restored on2026-09-08; exact account refresh and
fresh actual-profile model calls succeeded. The former pre-model auth stop is
resolved. The first release fixture attempts separately exposed a terminal
newline rejected by the canonical source contract and a stale token-question
mirror seeded by the old helper. Only the synthetic source is trimmed and the
release mirror reseeded. The composition now checks the actual production
ClickHouseTriageThreadReader returns the selected source before model calls;
all three older token cases keep their exact source/artifact and metadata.
The intervening first-request transport closed error had no Worker result and
remains unattributed. Do not count these setup/transport attempts as bad answers.

Current-profile Sol release R4 completed131.948s,19provider completions,
412952reportedtokens. The1236-character full answer and352-byte original
artifact reached one unchanged card, but no successful supplemental Slack read
was observed. Independent review failed investigation completeness, not factual
fabrication or delivery: available release/route facts were left as future
checks. Its Task-scoped absence statement does not claim the whole Slack corpus
is empty; the automatic grader's broader interpretation is rejected.

Worker-only Astra/high release R1 completed155.727s,22provider completions,
516356reportedtokens. Two Worker-attributed thread responses provide the actual
deployment snapshot and matching old-backend request. Independent whole-content
review found no material error across5surfaces; the1413-character answer and
original352bytes remain in one stable card. This is the third reviewed local
candidate scenario, not current-profile, statistical-reliability or live proof.

The unchanged Router profile generated different commands: Sol R4 lacked an
exact Slack locator; Astra R1 retained it. Private canonical triage_source_refs
are not a Worker-visible ordinary Task projection. Group-scoped Slack search
still makes the finite corpus discoverable, so this is not proof of unavailable
tools/source or of a model-only causal difference. Older captures contain no
complete first Worker request, and the Provider observer retains successes only.

An opt-in test-only treatment,
`COMMA_TRIAGE_WORKER_CONTEXT_DIAGNOSTIC=release_source_locator`, keeps the current
Router/Sol profiles and ordinary tools. The existing pre-Provider wrapper adds
only the original public read locator to every Worker request, not to Router or
Triage. It is continuing context, not first-input-only handoff preservation.
The committed obligation and canonical Task must match that exact source. The
first full original/modified request is exported with exact configured gateway
credentials redacted; Task binding and Worker tool calls/messages are exported.
No new production tool, check, prompt, authority or source projection is added.
Router prose stays stochastic: this treatment is not a frozen-command causal
comparison, normal product acceptance, or permission to bypass the existing
same-class production-fix stop.

Treatment R1 stopped before Router/Worker entry: the test compared a projected
source:// alias to an original Slack URI. It now uses the existing exact
read-only fetch_delegation API and claim.namespace_key. R2 completed124.832s,
19provider completions,425608reportedtokens,1passed30excluded. The original
first Worker input has no Slack locator; the only provider-input addition is
the read-only block. Actual source and diagnostic thread reads returned data;
the original attachment, full answer, single native card and final snapshot
checks pass. Main read both completed independent reports: content and exact
source-binding checks pass for this treatment; the1535-character answer retains
the key observations and coverage limits. Old-backend exact Ready/Endpoint
membership remains only a labeled inference, not a verified instance fact.
Three legacy searches failed with provider_error in the actual operation logs;
10/12exported tool messages are async-running receipts, not terminal bodies.
That export does not identify the precise search failure cause or constitute
complete asynchronous result capture. Two actual thread responses separately
prove successful source acquisition. No model rerun is needed to duplicate them.

Latest4-file deterministic regression after the diagnostic binding correction:
62passed,1liveexcluded,exit0; current composition formatting and diff checks
pass. The earlier942-pass55-file sweep remains historical; production code did
not change during this resumed phase. No current sparse failure, online delivery
or user-acceptance criterion is closed by these counts.

Further production correction is pending the owner's concrete adoption decision:
retain the current Router, consider the independently reviewed Astra/high Worker
candidate and deterministic public read-locator retention in the Task command.
This is not permission to expose private source refs/reply authority, revive a
revision helper, add a quality gate, change online templates, or deploy. The
existing same-class production-fix stop and explicit user-quality acceptance
remain authoritative. No additional unchanged model sampling is planned.

## Owner-resumed prompt and production read-source handoff

On2026-09-08 Peng approved a bounded local attempt while prioritizing the same
selected online profiles. A generic Worker-only investigation paragraph was
tested with unchanged Gemini Router/Sol Worker, normal tools and finite data.
P1 sparse completed162.153s/419071reportedtokens but still asserted no refresh;
P2 release completed126.176s/441245tokens and its two real thread reads supported
the complete answer. Both full-surface independent reviews were read. P2 also
received source coordinates in Router prose, so prompt causality is unproved.
The first actual Worker inputs are now exported without requiring the optional
locator treatment. The default provider messages remain untouched.

No further wording variant is selected. The approved next production candidate
projects bounded public source locators through the existing Worker Task source
summary, with no command/fingerprint/source-id change and no runtime read/RPC.
Existing SourceRefProtection registers the three product-owned Triage keys to
prevent generic retargeting; ordinary read and external-write permissions remain
unchanged. Old admitted same-source input is not backfilled. The actual first
Worker request must contain this production context; the previous optional
test-only locator treatment remains disabled for current-profile acceptance.

The production Provider/Task/Worker queue test first reproduced missing context
and accepted generic retargeting, then passed those two checks after correction.
New A/B async and old-source restart regressions are separate deterministic
evidence, not model reasoning or online delivery acceptance. The shared corpus,
assessors and selected profiles are unchanged. Current sparse content still
fails until a whole-chain actual-content observation proves otherwise.

P3 source-candidate sparse completed132.678s/18calls/422628reportedtokens with
the current Gemini/Sol profiles. Actual first messages equal provider messages,
include both production investigation guidance and exact read-source context,
and have no test-side locator injection. The Worker actually read the original
thread and made three searches; evidence remains partial and sparse. Router
command prose independently also includes the original locator, so this is not
a controlled causality experiment for the new summary. No runbook read is proved.

Mechanical acceptance passed:1247-character/2195-byte authored report,310-byte
unchanged attachment, result before one card, ready_for_review and unchanged
final snapshot. The automated test reports1passed,30excluded,exit0. Main and
independent complete-content review nonetheless fail its causal calibration:
the report no longer asserts no refresh, but ranks non-running/non-scheduled/
unrecorded refresh as a medium-confidence explanation of service non-renewal.
The observations do not establish non-renewal or distinguish a successful refresh
followed by use of the old token. This is a recorded automatic-grader false
positive, not license to weaken the human/independent content criterion or add
a case-specific runtime gate. Next unchanged sampling/prompt patch is stopped.

Source implementation regression is56files/950passed/2skipped/9liveexcluded;
37relevant protocol configurations match expected outcomes. The A/B fixture
persists captured pending/completion events after both Provider calls complete;
its evidence is provenance replay, not autonomous mid-call crash recovery.
These counts and source availability do not close current Sol quality or online
acceptance. No online profile, permission, credential or external data changed.

## 2026-09-08: real collaboration corpus and complete-output correction

`collaboration_cases_20260908.json` freezes eight distinct, de-identified real
threads before the first model run: two meeting/action questions, two source
research requests, two incomplete/conflicting-source questions and two correct
silence cases. Original timestamps, message order and held-out cutoffs remain;
later replies and expected outcomes are not model input. The corpus adapter
normalizes connector-rendered labelled mentions to canonical Slack mention
syntax and retains Slack-shaped de-identified IDs for the normal privacy pass.
Four explicit mentions enter signed ProviderHTTP; four ambient targets enter
the production Triage Runtime/fence. They are not interchangeable ingress tests.

The real-model composition keeps freshly resolved selected Gemini/Sol profiles,
ordinary Worker tools and local source caches/Slack loopback/fake S3. It observes
actual source reads, canonical Task results, returned messages and card writes.
Semantic quality and human usefulness are separate from its mechanical checks.
The original run and each failed answer remain in the goal's evidence report.

That wider run exposed a false-positive observer: `TriageTaskCardText` and the
production native output both sliced at 2,500 characters. Two long answers
therefore passed while losing their endings. The oracle now renders the full
canonical answer without the production slice. A production Task/Participant
regression fails before the rendering fix and passes afterward, including a
correction after an identical long prefix. Render generation 7 retains the
newest complete message; history details and legacy output remain bounded.
The earlier 2,500-character authoring workaround above is historical, not the
current completeness contract. This does not prove Slack's live size acceptance.

The next source-attribution treatment distinguishes reading an attributed claim
from verifying the underlying state, and original-source requests from repeating
an old summary. It contains no corpus facts or case-specific production rules,
does not raise models or restrict tools, and must be judged with the same frozen
sources and expectations. Prompt-presence tests are not behavior acceptance.
