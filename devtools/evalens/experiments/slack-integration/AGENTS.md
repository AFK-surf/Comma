# Slack live evaluation experiment

## Experiment contract

`slack-agent-workflows-live` is the only executable Slack experiment in this directory.
The older provider-action dataset is a local scenario catalog, not a second published
experiment.

- Every item creates a clean Salix group, router, session, and group-scoped Slack connect.
- Keep the Evalens dataset item shape to `id`, `input`, and `expected`. Put structured
  Slack setup and turns inside `input`; do not add fixture metadata as top-level fields.
- Keep provider tokens, workspace identity, channel allowlist, and target channel out of
  the dataset. Tokens belong in adapter config and `channelId` is a run parameter.
- Use the configured Salix integration ID `slack`. Do not select a materialization kind
  from experiment code.
- Keep live Slack concurrency at `1` while one app can have only one active group connect.

## Real input and delivery

- Drive all user/setup writes through `SlackDriver` and the official Slack SDK.
- The primary driver must authenticate as the configured human user. It must not be a
  bot and must not belong to the materialized Salix Slack App.
- Other-App input requires `otherAppDriver`, genuine `bot_id` evidence, and a distinct
  Slack App from the Salix bot.
- Do not prompt the Agent to reply through Slack. An Agent receiving a Slack message is
  responsible for choosing the correct delivery path.
- Append `send by codex` to live test messages created by this experiment.
- Observe every real provider thread created or targeted by a workflow turn. Only replies
  authored by the target Salix bot inside that turn's actual thread count as delivery;
  ignore top-level replies and other authors.
- For an unmentioned ordinary channel message, no reply in its thread is the expected
  behavior. Observe that thread through the complete configured silence horizon even if
  Salix input ingestion is detected earlier.

## Observation boundaries

- Use `SlackDriver` for deterministic input and setup writes.
- Use `SlackObserver` for provider state and external-result observation.
- Use `SlackFixtureCleaner` for best-effort teardown.
- Use `createSlackEvaluationTools` only to share one SDK client. Do not introduce a
  forwarding `SlackAdapter` facade or methods that hide which boundary owns an action.
- When an Agent successfully returns a DM channel from `slack.send_dm`, authorize that
  exact dynamic channel only through `SlackObserver.withAllowedChannel()`.
- Observe only successful DMs addressed to the verified driver user.

## Trajectory and evaluation

- Collect exactly one trajectory from the Salix router session. Slack SDK observations
  are result/artifact data, never a second or synthetic trajectory.
- Extract relevant Slack operation and attachment-read evidence from that trajectory in
  this experiment, not in the generic Salix adapter.
- Evaluators operate on the frozen result, artifacts, and trajectory. They must not call
  live Slack.
- Keep one deterministic evaluator returning the `delivery`, `external_assertions`, and
  `safety` score dictionary. Use the semantic evaluator only for content that requires
  judgment; silence is deterministic.
- Parse provider results structurally. Do not classify arbitrary message text containing
  words such as `failed` or `error` as an infrastructure error.
- Missing Agent reply, wrong placement, duplicate delivery, or unwanted reply is an
  evaluable failure. Invalid token, missing scope, permission, transport, malformed
  provider response, setup failure, or missing trajectory is a run error.

## Cleanup

- Try to remove messages, files, reactions, pins, Canvas resources, topic/purpose changes,
  and setup fixtures after each item.
- Cleanup is best-effort: log errors and continue with remaining Slack and Salix cleanup.
- Do not let cleanup failure rewrite a completed evaluation result.

## Verification

Run from `devtools/evalens`:

```sh
bun run format:check
bun run lint
bun run typecheck
bun test ./packages/adapters/test/slack.test.ts \
  ./experiments/slack-integration
```
