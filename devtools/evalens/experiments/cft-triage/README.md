# Comma for Teams (CFT) Group-Chat Triage Evaluation

This directory defines two Evalens experiments for Comma for Teams group-chat Triage across both production decision layers:

- **`worker_participation`**: the Worker investigation decision (`SalixAgent.SlackParticipationPrompt` → `im_api.internal.triage.complete`) that handles ordinary ambient Slack/Feishu messages and delegated rechecks (`reply`, `reaction`, `silence`, `context_candidates`).
- **`native_evaluator`**: the native `Salix.Bindings.TriageEvaluator` decision (`comma.triage-product-decision.v2`) that handles `scheduled_recheck`, `context_extraction`, and `general` lanes.

## Experiments

- `cft-triage.exp.ts`: evaluates one revision against frozen Evalens datasets (`ambient_triage`, `counterfactual_pair`, `shadow_diff`), measuring false-intervention rate, restraint score, help recall, delegation match, follow-up compliance, fact grounding, contract validity, and counterfactual flip rate.
- `cft-triage-shadow-diff.exp.ts`: compares a Baseline revision against a Candidate revision on matched group-chat snapshots, reporting intervention/delegation/follow-up diffs and two-pass position-debiased blind pairwise A/B scores across `restraint`, `helpfulness`, `grounding`, and `groupTone`.

## Building a dataset from a Staging snapshot

```sh
bun run experiments/cft-triage/build-cft-triage-dataset.ts \
  --snapshot /path/to/cft_triage_staging_snapshot.json \
  --out-dir datasets/cft-triage-shadow-v1 \
  --name cft-triage-shadow-v1 \
  --redact \
  --diversify

bun run cli dataset pack cft-triage-shadow-v1 --config evalens.local.config.json
```

Keep raw Staging snapshots outside Git. Commit only synthetic or fully sanitized fixtures if needed. Pass `--diversify` to cap repeated threads, normalized alert/message templates, cross-layer `run_id`s, and single-channel floods.

## Running locally

Run against pre-recorded shadow JSON outputs (produced by `cft_triage_replay_runner.exs`):

```sh
bun run cli run experiments/cft-triage/cft-triage-shadow-diff.exp.ts \
  --config evalens.local.config.json \
  --params-file cft-triage-shadow.params.json
```

Or execute live Elixir worktrees by passing `baselineSystemsDir` and `candidateSystemsDir` with `baseUrl` and `model` in `run` params.

## Blind human review HTML

`blind-review-html.ts` exports `renderCftBlindReviewHtml`, generating an anonymized, deterministically randomized A/B review page with automatic thread/template/channel diversity clustering (`+N` collapsed badge and raw/diversified toggle), CFT group-chat quick tags, reveal/agreement scoring, and JSON vote export.
