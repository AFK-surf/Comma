# Slack Agent live evaluation

`slack-agent-workflows-live` drives a real Salix Agent through Slack, records one Salix
router trajectory, observes the resulting Slack state, and evaluates the delivered
behavior. It accepts both one-shot provider actions and multi-turn workflows.

## Runtime flow

```text
create clean group and router
  -> materialize the eval-only Slack installation into that group
  -> prepare Slack fixtures with the driver SDK
  -> send real user/App messages
  -> wait for Salix input and thread delivery
  -> collect one router trajectory
  -> observe Slack state
  -> evaluate frozen output
  -> best-effort Slack cleanup, then Salix cleanup
```

The target Slack connect is group-scoped. The reusable installation credentials live in
local Evalens config, but every item receives a new connect. Run with concurrency `1`.
OAuth fixtures may reuse a binding only when its stored connection is tagged with the
same integration ID; an ordinary user-owned provider/alias binding is a conflict.
OAuth, plugin, and MCP setup is compensated as one materialization operation, and a
remote MCP fixture succeeds only after refresh leaves its binding runnable.
Salix serializes that complete operation with a durable group lease and records each
logical fixture as `pending`, `committed`, or `failed`; an idempotent follower may replay
only the committed result.

## Run configuration

Use [the repository example config](../../evalens.config.example.json) as the complete
shape. The important boundaries are:

| Value                                      | Location                                    | Purpose                                         |
| ------------------------------------------ | ------------------------------------------- | ----------------------------------------------- |
| Salix URL, tenant, template                | `adapters.salix`                            | Create and observe the clean group/router       |
| Target Slack App credentials               | `adapters.salix.integrations[]`, ID `slack` | Materialize the group-scoped Agent connect      |
| Driver user token/workspace/user/allowlist | `adapters.slack`                            | Prepare input and observe provider state safely |
| Optional second App token                  | `adapters.slack.otherAppDriver`             | Produce genuine other-App-authored input        |
| Evaluation channel                         | run parameter `channelId`                   | Select the dedicated live-evaluation channel    |
| Timeouts and settle window                 | run parameters                              | Bound Agent and provider waits                  |
| Codex authentication                       | `adapters.codex`                            | Run semantic evaluation                         |

The primary driver must be a real human user. The target Salix bot and optional other App
must already be members of the evaluation channel.

Run locally:

```sh
bun run cli run experiments/slack-integration/slack-agent-workflows.exp.ts \
  --config evalens.config.json \
  -- --run.channelId <eval-channel-id> --run.agentTimeoutMs 180000
```

Packing the dataset locally does not publish it or update a remote registry.

## Current workflow dataset

| Item                                     | Workflow represented                                                                |
| ---------------------------------------- | ----------------------------------------------------------------------------------- |
| `history-final-decision-after-reversals` | Find the final decision in noisy history after dates and owners changed             |
| `long-thread-release-handoff`            | Consolidate a long release handoff with completed, cancelled, and risky work        |
| `meeting-transcript-followup-correction` | Turn a transcript attachment into a follow-up artifact and apply thread corrections |
| `pr-review-loop-from-slack-context`      | Continue a multi-round review conversation after fixes and a CI update              |
| `scope-change-to-handoff-brief`          | Follow narrowed scope and stop implementation in favor of a handoff brief           |
| `single-terminal-implementation-plan`    | Produce exactly one terminal implementation-plan artifact                           |
| `decision-thread-to-maintained-canvas`   | Create a Canvas from a decision thread and update that same Canvas                  |
| `bot-authored-pr-recheck-handoff`        | Accept genuine input authored by another Slack App and reply in its thread          |
| `no-mention-no-agent-reply`              | Ignore ordinary channel discussion that did not address the Agent                   |

The PR and meeting cases currently evaluate reasoning over Slack attachments; they do not
claim to perform real GitHub or meeting-system operations.

## Provider-action catalog

The retained one-shot catalog covers these atomic and compact workflow capabilities:

| Item                                     | Capability                                                 |
| ---------------------------------------- | ---------------------------------------------------------- |
| `slack.thread.read-and-reply`            | Read a prepared thread and answer in the trigger thread    |
| `slack.dm.send-to-driver`                | Send a DM to the verified driver user                      |
| `slack.permalink.read`                   | Read a dynamically prepared message permalink              |
| `slack.channel-history.summarize`        | Read and summarize prepared channel history                |
| `slack.file.upload`                      | Create and upload a requested file                         |
| `slack.attachment.fetch`                 | Fetch and use a prepared Slack attachment                  |
| `slack.inbound.create-text-file`         | Turn an inbound request into a same-thread text attachment |
| `slack.message.create-and-update`        | Create and update the same message                         |
| `slack.message.create-and-delete`        | Create and delete the same temporary message               |
| `slack.reaction.add`                     | Add one reaction to the selected message                   |
| `slack.pin.add` / `slack.pin.remove`     | Add or remove a pin                                        |
| `slack.channel-topic.update`             | Update the evaluation channel topic                        |
| `slack.channel-purpose.update`           | Update the evaluation channel purpose                      |
| `slack.canvas.create-and-edit`           | Create and edit a Canvas                                   |
| `slack.canvas.access-driver`             | Create a Canvas and grant access to the driver             |
| `slack.provider-error.foreign-reaction`  | Report a provider-denied action without claiming success   |
| `slack.workflow.release-brief`           | Read discussion/attachment, upload a brief, and react      |
| `slack.workflow.incident-handoff`        | Read an incident link, create a Canvas, and grant access   |
| `slack.workflow.publish-correct-and-pin` | Publish, correct, react to, and pin one notification       |

Duplicate-name user ambiguity and inviting other users are excluded. Prompts may refer
only to the configured driver user, for example “私信给我”.

## Dataset shape

Items use only `id`, `input`, and `expected`. Input contains ordered `slackSetup` plus
either a one-shot `slackTrigger` or multi-turn `slackTurns`:

```json
{
  "id": "slack.permalink.read",
  "input": {
    "slackSetup": [
      {
        "action": "post_message",
        "alias": "source",
        "text": "Verification code is ORCHID-731."
      }
    ],
    "slackTrigger": {
      "text": "Read {{source.permalink}} and report the code."
    }
  },
  "expected": {
    "externalAssertions": [{ "kind": "permalink_read_observed", "target": "source" }],
    "semanticCriteria": ["The reply contains ORCHID-731."],
    "forbiddenOutcomes": [{ "kind": "unrelated_write" }]
  }
}
```

Setup supports messages, thread replies, text files, reactions, and pins. Aliases resolve
to runtime Slack IDs. `{{alias.permalink}}` is the only trigger interpolation.

## Observation and evaluation

Each workflow turn is observed in the real Slack thread it creates or targets. Only
replies from the materialized Salix bot inside that turn's thread count; top-level
messages and other authors are ignored. This also lets a silence case detect an unwanted
Agent reply in the unmentioned message's own thread. SDK state is stored as observation
data; the Salix router session remains the single trajectory.

| Evaluator                      | Scores                                      |
| ------------------------------ | ------------------------------------------- |
| `slack-workflow-deterministic` | `delivery`, `external_assertions`, `safety` |
| `slack-workflow-semantic`      | `semantic`, `semantic_pass`                 |

An item strictly passes when delivery, all external assertions, safety, and semantic pass
are all `1`. Silence cases use deterministic evaluation only.

No thread reply after successfully delivered input is an Agent-quality failure. Invalid
credentials, missing scopes, SDK/setup/read failures, malformed provider responses, and
inability to collect the Salix trajectory are run errors. Cleanup failures are logged and
Slack fixture cleanup does not block Salix cleanup. Inside Salix cleanup, however, an
unconfirmed IM discovery or delete deliberately retains the Agent and group subtree so a
later cleanup retry can still reach and release the group-scoped connect.

## External requirements

- Dedicated Slack evaluation channel listed in `allowedChannelIds`.
- Installed `evalens` Slack App invited to that channel, with the scopes generated by
  `SalixIM.SlackScopes`; reinstall it after scope changes.
- Public Slack Events URL that reaches the Salix instance.
- Separate human driver token matching the configured workspace and user.
- Optional distinct App/Bot token for other-App input cases.
- Salix tenant, Agent template, model/runtime credentials, and Slack provider tools.
- Authenticated Codex adapter for semantic evaluation.
- Gitignored local config; no token or secret may appear in datasets, manifests, logs,
  trajectories, results, or artifacts.

Real GitHub, Linear, Notion, Google, code-execution, meeting, CI, or worker-control cases
require their own group-scoped integration/environment materialization and deterministic
external fixture observation. Slack attachments that describe those systems are not a
substitute for real provider side effects.
