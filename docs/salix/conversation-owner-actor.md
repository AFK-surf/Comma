# Conversations and delivery

## Dynamic UI content

A `dynamic_ui` block is a Message value, not an entity. It carries `version`, `ui_ref`, `path`, `file_name`, `mime_type`, `summary`, and a matching `text` fallback.
The sender binder supplies `blob_ref`. Callers cannot substitute blob authority.
`ui_ref` projects the blob UUID. The binder rejects bytes that change between creation and send. It grants no read or delivery authority.
`origin_task_id` keeps follow-up Task context and grants no Task access.
Each Message has at most one UI block. HTML and JavaScript stay in its immutable attachment.
Recipient materialization lets the Router forward those bytes from its authorized workspace.

The Worker sends content explicitly through the Conversation owner and IFC path. Tool output creates no visible Message. External providers receive the summary.
New versions append Messages with the existing reply and thread relationships in each destination Conversation.
Home and Task Messages can reference the same attachment version.
Devices own form state. Existing server owners keep Reminder and Task state.

## Question cards

A `question` block is a Message value, not an entity. Only an Agent sends it: a `prompt`, two to six `choices` (`id`, `label`, optional `description`, `reply` and one `recommended`), `multi_select` and `allow_other`.
The Agent send path numbers missing choice ids, fills the defaults, and appends a `text` block with `fallback_for: "question"`. That block shows the prompt and numbered choices to clients that cannot draw the card. Other Agents read it as text.
A Router asks with the question as the reply of `end_turn` with outcome `blocked`. A Worker sends it in its Task. The Router receives it and sets the Task `escalated` while the person answers.
The answer is an ordinary user Message. It replies to the question Message and carries its words, any images as ordinary attachments, and one `question_answer` block (`question_message_id`, `choice_ids`, optional `other`, `skipped`).
The owner admits an answer only against the Message it replies to: that Message asks, the choices are its own, and single-choice and closed questions keep their rules. A refusal names the fix; the product API returns only these.
Clients send the answer under `client_request_id` `question-answer:<message_id>`. Request identity keeps the first answer, so a second device gets a conflict and shows the first.
No answer state is stored. Clients read the card's state from the transcript: the first later person Message answers it, skips it, or replies in the chat; a later question replaces it.
[validation](../../systems/apps/salix_im/lib/salix_im/conversation_question.ex),
[client state](../../clients/packages/core/src/chat/model/questionStates.ts).

## Task milestone content

A `milestone` block is a Message value, not an entity. It carries a one-line `title` of at most 80 characters that names a step an Agent finished.
Only an Agent records milestones. A Message carries at most 20, for steps finished together. Milestones only append; there is no status or later edit.
Every append puts the blocks first and keeps each title on one line. A Message with only milestones gets an empty delivery filter, unless its sender supplied its own filter.
Such a Message notifies no Participant, so it does not wake the Router. It has no text, and no transcript or provider shows it. Milestones do not change Task status.
A Worker records one milestone per item for a few items and one per batch for many, about eight per request at most. A Loop run that changed nothing records none.
Clients show a Task's milestones only as its Activity: in order, each at its Message's time, grouped under what came before them.
A group starts at the brief, at a person's later Message, or at a Loop run's wake Message (a system Message whose `agent_input.trusted_origin.provider` is `loop`).
It also starts at a Router Message that hands the Task a request made elsewhere, such as in Home. The send path marks it with `metadata.task_request` when the delivery that woke the Router came from no Message of the Task, it replies to nothing, and it reaches the Task's Participants; a Router's own follow-up without a waking delivery is no request. A group without milestones is left out, except the brief.
A milestone opens the Agent's first shown Message from its own on, which shows the result, or the last shown Message before it while none has come.
A group's first row hides or shows its milestones. A row names the day only when it differs from the row above.
The Activity reads the Task's whole history. A client that holds only the latest transcript reads the rest for the Activity alone, through transcript pages with `view=activity`: each Message keeps its identity, sequence, time, sender, metadata and milestones, a request keeps its first 500 characters, and any other shown content becomes one empty text block.
A long Activity shows its first group and its latest two groups. A long group shows its first two and its latest three milestones. A fold row stands for the rest until pressed.
Implementation: [contract](../../systems/apps/salix_im/lib/salix_im/conversation_milestone.ex), [Activity pages](../../systems/apps/comma_core/lib/comma/task_activity_messages.ex), [client projection](../../clients/packages/core/src/chat/model/taskActivity.ts).

## Authority

Mutate Conversation facts only through `ConversationServer -> ConversationActor`.
The owner serializes metadata, Message append, and Participant membership transitions. Participant mutation is separate from Message append.
Participants are delivery targets, not senders. Never persist the in-memory `participant_count` aggregate.
ParticipantActor owns provider delivery, retry, recovery, and participant runtime status.
All Agent Participants use the log admission path below. Do not create a global dispatcher that bypasses these owners.

Comma keeps its fixed Router `user_chat` binding. Setup adds missing Router Participants there. It never creates a replacement Conversation or binding.
Repeated setup reuses active User membership and unchanged Agent activation fields.
Active Agent sources keep subscription start and cursor, also with unread Messages.
Router authority checks read current records before and after reconciliation.
Unadmitted inputs stay in the log. Five-second consumer retries and log recovery cover lost hints and owner restarts.
BFT and Comma can project canonical IDs, but own no second execution history.

Conditional writes keep CAS fences. The Group owner's Router address hint grants no authority.

## Message and visible reply

Salix IM owns Message identity, reply relationships, ordered history, and explicit delivery.
A reply inherits its target's thread root. Agent delivery quotes up to 1,000 target characters, only to a recipient that wrote or received it.
Model responses and internal Session records are not public Messages. Visible egress requires the explicit reply path and destination authority.
Never expose internal planning, tool results, provider context, or private summaries through implicit assistant projection.
File delivery preserves source and authorized audience. Local paths are not public URLs.

Tool results, provider ACKs, canonical appends, and user-visible delivery are different facts.
Retry and deduplication require stable delivery identity. An internal retry ledger does not prove exactly-once external delivery.
Late results must pass current owner and activation fences before they change state.

## History and projections

Conversation metadata, Messages, Participants, and provider receipts use separate collections with bounded segmented or directory-sharded access.
Runtime Session history stays separate from visible Conversation history.
Home shows external inputs and successful explicit replies. Only user inputs show a platform icon and `From <platform>` above the bubble.
`platform_message` carries provider, role, and content. Inputs use checked sender text and attachment names, never Agent prompts.
The owner links WeChat replies only to checked Home source Messages.
Media captions, names, and types grant no access to private runtime paths or provider URLs.
Badges and reply links survive native transport and reload. External messages do not settle pending Comma replies and do not notify.

Never erase history when a stream ends or create a new identity to hide a read failure.
`events?changes=1` resyncs, then names each Conversation change the session sees.

Resident internal Sessions project only committed revisions. Busy resident owners return bounded errors.
Bound status queries and SSE recovery. Stale events cannot overwrite newer snapshots or another Conversation's state.
Status hints use current activation sources and the structured wait, with no scan or extra RPC. Hints carry no source IDs or wait reasons.
Sources from one `wechat`, `telegram`, or `signal` channel give `working_provider`. Comma shows its capsule.
Only Loop sources give `loop_wake: true`. Home keeps that Participant active with no activity bubble.
Other Conversations with input give `working_conversation_ids`, at most eight. A wait gives `waiting: true`. Comma shows both only on Home. Agent tools omit them.
See [Storage](../storage-search.md) for archive errors and [Tasks](tasks-background-execution.md) for Task state.

## Provider ingress and egress

Every provider adapter uses the same ownership path. Provider threads supply context, not Conversation ownership.
Provider adapters own external formatting and rich cards.
Visible reply repair errors must give actionable outcomes, never infinite retries.

## Conversation log consumption

The ordered log supplies Router, Worker, and Meeting inputs to their Sessions.
Provider callbacks commit checked input and provenance through ConversationServer before acknowledgment.
Each verified provider source keeps its first accepted input per target Session.
After Router reset, a new callback can admit the source to the new Session. Reset alone never replays the log.
Chat shows `platform_message` when present, never provider prompt envelopes or delivery control events. Search omits internal delivery records.
Public Message appends cannot supply owner-only input fields.
After a successful explicit send, the dispatcher attempts a `provider.message` record through that owner, with no delivery targets or Agent input.
A send to the owner's Comma-managed Telegram or WeChat chat is recorded only when the turn answers a message from that chat.
The record deduplicates by tool call or provider receipt.
History writes use 64 shared projection slots. Failure or saturation can omit history, but never fails or repeats a successful platform send.
Provider Participants consume the same log. There is no second delivery queue, outbox, or durable wakeup marker.
Agent Sessions do not consume owner-authored provider commands and status projections.

Each provider owner reads at most 32 records and stores its completed position in `delivery_log_cursor_seq`.
It claims an exact Message/Participant receipt before platform I/O, settles that receipt, then advances the cursor.
A restart reads that receipt before another send. Subscription changes cannot hide unresolved platform I/O.
Slack receipt verification can confirm a prior send without a resend. It does not prove exactly-once delivery.
Three failed sends or three unsuccessful verification settlements end in a terminal error. Uncertain results are `unknown`.
A provider retry delay does not reset the attempt budget.
Task-thread detachment waits until the log cursor reaches its cutoff and in-flight I/O settles.

Conversation status is a projection of durable metadata. `provider_status_version` advances with projected facts or recovery fencing. It does not authorize a caller.
Provider app events do not change the Task business version used for review acceptance.
An explicit redelivery appends an idempotent request that refers to the original Message with a fresh input identity.

The consumer preserves target filters, attachments, provenance, billing, archive admission, and context-only wake policy.
Each Session stores progress by Participant ID. A single CAS commits input and progress together.
Non-target and imported transcript records advance progress without input.
Muted Participants do not consume the log. A later Task join can admit the required suffix.

Admission makes three attempts for other transient failures. A terminal failure records `last_rejection` with its source position.
An exhausted Triage command escalates its Task before the rejected position commits. Escalation keeps the grant, so an accepted Worker can still complete the Task.
If storage cannot commit the rejection, progress stays unchanged and recovery retries after five seconds.
Missing and retired bindings stop that source drain.
An explicit Participant delivery-status query includes `source_progress` and needs at most one Session read. Provider delivery records stay in `deliveries`.

Recovery uses the PostgreSQL `conversation_log_recovery` due index. It never traverses Group or Conversation directories.
One row per pending Conversation records the greatest prepared sequence and provider status version.
Append prepares the segment and all locators, marks the index, then publishes the tail. A failed index write prevents tail publication.
If publication stops, recovery finishes the prepared append through ConversationActor and its normal Store CAS.
Metadata changes register their next provider status version before CAS. Recovery fences an older version with a normal metadata CAS. This keeps product facts and the Task business version.
Recovery removes only the observed sequence and status version after publication and durable consumer progress. A greater concurrent target prevents deletion.
Agent filter and Session binding changes, including the first Triage join, register recovery before activation.
Cleanup carries the observed membership revision. A changed revision or owner rejects cleanup and keeps the candidate.

### Automatic initialization of existing conversations

The log lower bound is `log_start_seq`. The first append or Agent source read of an existing Conversation saves the current Message tail before a new Message commits.
Earlier unprocessed Agent inputs and pending provider output are discarded by owner decision. Canonical Messages, Participants, admitted Session inputs, and receipts stay stored.
New Conversations start at zero. Restart never moves an initialized lower bound forward. The rule applies to IM, Worker, and Router inputs.
Each provider starts its cursor at that bound or its later Participant start position.
Old delivery queues, indexes, and wakeup markers select no work. Diagnostics show abandoned pending receipts as cancelled and unresolved platform calls as unknown.
Initialization failure rejects the operation before a new Message commits.
Use forward repair only. An old consumer can replay inputs that the owner decision excluded.
