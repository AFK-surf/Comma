# Slack Agent live evaluation

`slack-agent-workflows-live` drives a real Salix Agent through Slack, records one Salix
router trajectory, observes the resulting Slack state, and evaluates the delivered
behavior. It accepts one-shot provider actions and multi-turn workflows.

## Isolation

Every item gets a new group-scoped Slack connect. The reusable installation
credentials live in local Evalens config. Run with concurrency `1`. OAuth fixtures may
reuse a binding only when its stored connection is tagged with the same integration ID.
An ordinary user-owned provider/alias binding is a conflict.

## Run configuration

Use [the repository example config](../../evalens.config.example.json) for the complete
shape:

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

The PR and meeting cases evaluate reasoning over Slack attachments. They do not perform
real GitHub or meeting-system operations.

## Provider-action catalog

The one-shot catalog covers these capabilities:

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

Duplicate-name user ambiguity and inviting other users are out of scope. Prompts may
refer only to the configured driver user, for example “私信给我”.

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

Observation, delivery, and error rules are in [AGENTS.md](AGENTS.md).

| Evaluator                      | Scores                                      |
| ------------------------------ | ------------------------------------------- |
| `slack-workflow-deterministic` | `delivery`, `external_assertions`, `safety` |
| `slack-workflow-semantic`      | `semantic`, `semantic_pass`                 |

An item strictly passes when delivery, all external assertions, safety, and semantic pass
are all `1`. Silence cases use deterministic evaluation only.

If Salix cannot confirm IM discovery or delete during cleanup, it keeps the Agent and
group so a later cleanup retry can release the group-scoped connect.

## External requirements

- Dedicated Slack evaluation channel listed in `allowedChannelIds`.
- Installed `evalens` Slack App invited to that channel, with the scopes generated by
  `SalixIM.SlackScopes`. Reinstall it after scope changes.
- Public Slack Events URL that reaches the Salix instance.
- Separate human driver token matching the configured workspace and user.
- Optional distinct App/Bot token for other-App input cases.
- Salix tenant, Agent template, model/runtime credentials, and Slack provider tools.
- Authenticated Codex adapter for semantic evaluation.
- Gitignored local config. No token or secret may appear in datasets, manifests, logs,
  trajectories, results, or artifacts.

Real GitHub, Linear, Notion, Google, code-execution, meeting, CI, or worker-control cases
need their own group-scoped materialization and deterministic external fixture
observation.
