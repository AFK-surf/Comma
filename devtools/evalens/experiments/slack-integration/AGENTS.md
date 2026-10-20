# Slack live evaluation experiment

## Experiment contract

`slack-agent-workflows-live` is the only executable Slack experiment in this directory.
The provider-action dataset is a local scenario catalog, not a second experiment.

- Every item creates a clean Salix group, router, session, and group-scoped Slack connect.
- Dataset items have only `id`, `input`, and `expected`. Put Slack setup and turns
  inside `input`. Do not add top-level fixture fields.
- Keep provider tokens, workspace identity, channel allowlist, and target channel out of
  the dataset. Tokens belong in adapter config. `channelId` is a run parameter.
- Use the Salix integration ID `slack`. Do not select a materialization kind in
  experiment code.
- Keep live Slack concurrency at `1` while one app can have only one active group connect.

## Real input and delivery

- Send all user/setup writes through `SlackDriver` and the official Slack SDK.
- The primary driver must authenticate as the configured human user. It must not be a
  bot and must not belong to the materialized Salix Slack App.
- Other-App input requires `otherAppDriver`, genuine `bot_id` evidence, and a Slack App
  distinct from the Salix bot.
- Do not tell the Agent to reply through Slack. The Agent chooses the delivery path.
- Append `send by codex` to live test messages that this experiment creates.
- Observe every real provider thread that a workflow turn creates or targets. Only
  replies from the target Salix bot inside that turn's thread count as delivery. Ignore
  top-level replies and other authors.
- For an unmentioned ordinary channel message, no reply in its thread is correct.
  Observe that thread for the full configured silence horizon, even if Salix input
  ingestion is detected earlier.

## Observation boundaries

- `SlackDriver`: deterministic input and setup writes.
- `SlackObserver`: provider state and external-result observation.
- `SlackFixtureCleaner`: best-effort teardown.
- Use `createSlackEvaluationTools` only to share one SDK client. Do not add a
  forwarding `SlackAdapter` facade or methods that hide which boundary owns an action.
- When an Agent returns a DM channel from `slack.send_dm`, authorize that exact channel
  only through `SlackObserver.withAllowedChannel()`.
- Observe only successful DMs addressed to the verified driver user.

## Trajectory and evaluation

- Collect exactly one trajectory from the Salix router session. Slack SDK observations
  are result/artifact data, never a second or synthetic trajectory.
- Extract Slack operation and attachment-read evidence from that trajectory in this
  experiment, not in the generic Salix adapter.
- Evaluators use the frozen result, artifacts, and trajectory. They must not call live
  Slack.
- Keep one deterministic evaluator that returns the `delivery`, `external_assertions`,
  and `safety` scores. Use the semantic evaluator only for content that needs judgment.
  Silence is deterministic.
- Parse provider results structurally. Do not treat message text that contains words
  such as `failed` or `error` as an infrastructure error.
- Missing Agent reply, wrong placement, duplicate delivery, or unwanted reply is an
  evaluable failure. Invalid token, missing scope, permission, transport, malformed
  provider response, setup failure, or missing trajectory is a run error.

## Cleanup

- After each item, try to remove messages, files, reactions, pins, Canvas resources,
  topic/purpose changes, and setup fixtures.
- Cleanup is best-effort. Log errors and continue with the remaining Slack and Salix
  cleanup.
- A cleanup failure must not change a completed evaluation result.

## Verification

Run from `devtools/evalens`:

```sh
bun run format:check
bun run lint
bun run typecheck
bun test ./packages/adapters/test/slack.test.ts \
  ./experiments/slack-integration
```
