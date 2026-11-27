# Proactive evaluation experiments

This directory defines two Evalens experiments for Comma Proactive:

- `proactive-triage.exp.ts`: evaluates one revision on frozen datasets containing
  single-item triage cases, counterfactual pairs, and multi-hour or multi-day event streams.
- `proactive-shadow-diff.exp.ts`: compares a Baseline revision against a Candidate revision
  on matched event streams, reporting decision flips and two-pass position-debiased blind
  pairwise A/B scores.

## Datasets

Official held-out datasets live outside Git and are loaded by name and SHA-256 digest via
Evalens dataset storage (`evalens dataset pack` and `evalens dataset publish`).

Each item follows `ProactiveEvalItemSchema` in `dataset.ts` with one of four kinds:

- `triage`: one arrival screened against portrait, Home history, matters, notebook, and pool.
- `counterfactual_pair`: a `base` and `variant` snapshot that differ in one context fact to
  verify that decisions flip when user context changes.
- `day_stream`: a chronological multi-source stream evaluated against daily interrupt, signal,
  and duplicate budgets.
- `shadow_diff`: a sanitized real-world snapshot for Baseline vs Candidate diff and blind A/B
  judging.

## Running locally

Build and pack a dataset from a Staging shadow snapshot:

```sh
bun run experiments/proactive/build-shadow-dataset.ts \
  --snapshot /path/to/staging_shadow_snapshot.json \
  --out-dir datasets/proactive-shadow-v1 \
  --name proactive-shadow-v1 \
  --redact

bun run cli dataset pack proactive-shadow-v1 --config evalens.local.config.json
```

Run with pre-recorded shadow JSON outputs (for fast re-scoring or blind A/B evaluation)
by passing a JSON `--params-file` containing `run` and `eval` parameters:

```sh
bun run cli run experiments/proactive/proactive-shadow-diff.exp.ts \
  --config evalens.local.config.json \
  --params-file proactive-shadow.params.json
```

Example `proactive-shadow.params.json`:

```json
{
  "run": {
    "datasetName": "proactive-shadow-v1",
    "datasetDigest": "<sha256>",
    "baselineRevision": "accc5f64f",
    "candidateRevision": "7e5d30af9",
    "baselineResultsPath": "/path/to/shadow_baseline.json",
    "candidateResultsPath": "/path/to/shadow_candidate.json",
    "model": "codex"
  },
  "eval": {
    "swapPasses": true
  }
}
```

Or execute live Elixir worktrees by setting `baselineSystemsDir` and
`candidateSystemsDir` along with `baseUrl` and `model` in `run` params.

## Blind human review HTML

`blind-review-html.ts` exports `renderBlindReviewHtml`, which renders anonymized,
deterministically randomized A/B cards for human blind rating before revealing revisions.
