# Evalens TODO

## Execution progress and identity handoff

- Define a versioned execution event contract before adding `watch` or progress
  output. First use: give an agent the run id right after creation without
  changing the snapshot query commands. Decide JSONL framing, terminal events,
  disconnect behavior, and whether a heartbeat or lease is needed.
- If complete large-catalog traversal becomes necessary, add stable cursor
  pagination to QueryService and the API first. Do not add `--all` over offset
  pagination.

## Trajectory relationships

- Add explicit cross-trajectory relationship metadata and render links between
  trajectory lanes in the merged timeline. Derive links from explicit Salix
  conversation and tool-call identifiers. Never infer causality from timestamps.
  This likely needs a stable parent or causal step ID in the trajectory step
  contract.

## Dataset review workflow

- Add a PR-oriented diff summary for two dataset digests: added, removed, and
  changed item IDs and description changes. Do not expose R2 credentials or
  commit dataset payloads.
