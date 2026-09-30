# Evalens TODO

## Execution progress and identity handoff

- Define a versioned execution event contract before adding `watch` or progress
  output. The first use case is handing an agent the run id immediately after
  creation without changing the machine-first snapshot query commands. Decide
  JSONL framing, terminal events, disconnect behavior, and whether a later
  heartbeat or lease is needed. Persisted `running` remains lifecycle
  non-terminal, not confirmed process liveness.
- If complete large-catalog traversal becomes necessary, add stable cursor
  pagination to QueryService and the API first. Do not add `--all` over offset
  pagination or turn an interactive command into an unbounded scan.

## Trajectory relationships

- Add explicit cross-trajectory relationship metadata and render horizontal links in
  the merged timeline. Salix router and worker agents communicate through
  conversations, so selected tool-call steps may connect different trajectory
  lanes. Derive links from explicit Salix conversation/tool-call identifiers; never
  infer causality from timestamp proximity. This likely requires extending the
  trajectory step contract with stable relationship fields such as a parent or
  causal step ID.

## Dataset review workflow

- Add a PR-oriented dataset diff summary for content-addressed archives. The tool
  should compare two dataset digests, report added/removed/changed item IDs and
  description changes, and attach the summary to the review without exposing R2
  credentials or committing dataset payloads.
