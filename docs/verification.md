# Verification

Proof sources, commands and queries: [kernel README](../systems/native/verified_kernel/README.md).

## Session reduction

Session proofs cover append-only transitions and terminal/blocked-ACK/stale-compaction preservation under stated hypotheses.
See the [Session proof sources](../systems/native/verified_kernel/proofs/VerifiedKernelProofs/Session/).
S3 commits, codecs, and scheduling are outside these proofs. Keep their boundary regressions.

### Accepted work and durable confirmation

Accepted work is durable Session input, not Task completion or reply delivery.
Its identity and payload must stay queued, represented by a Session record, or retained in sealed storage.
A queue ACK confirms materialization. It does not discharge a business or reply obligation.
The proof does not use the dedupe ledger as a substitute for the work.

Delivery admits input records, birth metadata, `context` facts, and supported workspace operations.
Owner controls and unknown types fail closed before effects. `inputIdentitiesDistinct` checks every batch identity writer.
The host repairs UTF-8 before admission. Proofs use this canonical input.
Rejection returns `invalid_delivery_events` without reserving the source ID.
Full refinement is open in [#1799](https://github.com/AFK-surf/Comma/issues/1799).

Archive proofs connect published catalog entries, pending writes, and fenced CAS to physical input facts.
Semantic codecs ignore map order but keep field presence, list order, and scalar values.
Model snapshots and notification lists are proof-only projections, not runtime state or gates.
The theorem authorizes no arbitrary raw `queue_ack`/`queue_consume` events.

Proofs start with empty modern storage. Legacy/imported states need separate proofs.
The owner chose the Lean boundary. Elixir/Erlang, libraries, C, BEAM/FFI, codecs and storage remain assumptions.
Hypotheses cover arguments, identity, request/response pairing, storage facts and public reports.
Conditional proofs change no product guarantees or boundary tests.
They prove no provider rollback, exactly-once external effects, scheduling progress or Task completion.
See the [complete boundary](../systems/native/verified_kernel/README.md#lean-only-refinement).
Run the axiom audit, native tests, Session regressions and retained TLA+ suite.

## AgentLoop control

See [agent loop proofs](../systems/native/verified_kernel/README.md#agent-loop-proofs).

## Shared executable kernel boundary

C `invoke_etf/1` takes `{1, domain, 1, operation, payload}` and returns `{1, :ok, result}` or `{1, :error, domain, binary_code}`.
The kernel alone owns immutable Session state and decisions. The host passes facts through arguments and holds an opaque `SalixAgent.InternalSession` handle.
The Actor and storage CAS select the current committed revision.
State crosses as data only at `load`, `persist`, `open`, and `export`.
`open_envelope` takes only the named fields of a tool or runtime context.

Lean owns presentation, compaction decisions, settlement, restart planning, wait timeouts, and activation retry deadlines.
Lean owns request encoding and attachment provenance, including the Anthropic Messages, OpenAI Chat, and Responses encoding, parsing, SSE state, and retry decisions.
The host owns timer delivery, process observations, external authority, durable commits, image reads, stored-result reads, credentials, and network I/O.
Site-proxy chat translation and media APIs are outside the agent-loop provider domain.
Query results do not prove commit success. Draft retirement follows committed results.

Except for the retry, materialization, command-confirmation, and loop properties, these definitions lack functional correctness proofs.
Lean checks termination of pure definitions. This proves no execution-time bound, termination of external calls, or Actor retry progress.
Most queries are not proved. An opaque handle alone does not establish a narrow semantic boundary.
NIF and local HTTP regressions cover partial JSON, Unicode splits, rejection, protocol replay, and stack safety.

The wire accepts pure ETF and supported State/MapSet envelopes. Reject other structs, PIDs, references, functions and compressed ETF. No custom fallback.
Host decoding, schema admission, C ownership, compilation and transport remain trusted/tested boundaries.

## IFC authorization contract

`hard` selects the existing strict policy. Stored `enforce` values select the same policy.
`audit` records Hard permission decisions without blocking. `off` disables the IFC decision gate.

With IFC enabled, model calls require `ifc` with a `sources` array. Runtime exemptions cover only: `help(tool)`, `im.provider_apis_list(provider)` or verified built-in skill reads with only `path`.
Runtime checks exclude custom skills, indexes, scoped connections and business reads.
Malformed declarations fail. Request authority is unchanged.
Only trusted built-in provider catalogs without connection/tenant parameters are public. Connection discovery and unknown results stay agent-private.
Provider help exemptions require exact built-in entries, excluding tenant overrides.
Declarations also apply to `end_turn.reply` and Station Task tool arguments.
Station Task calls lift `args.ifc` before dispatch. Their `src:q-1` names the current call under the Task label; this boundary has no Salix session history.
Before capability dispatch, tool parameter validation rejects missing declarations, `context`, encoded arrays, and malformed references.
This produces `invalid_params`, not an IFC deny, in audit, easy, and enforce modes.
Local validators may add fixed public parameter, availability, or envelope diagnostics at `items[0]` (`#0`). Visible calls receive these directly as tool receipts. Foreign calls and receipts stay hidden. Root audiences remain unchanged or fail-closed.
The projection excludes arguments, tool names, backend text and resource existence. Provider errors and `public_summary` do not qualify. These errors do not enter effect permission resolution.
Canonical HTTP and script calls carry `ifc` beside their tool arguments. Their help schemas disclose this field.
Session controls without a reply do not require a declaration. Off-mode admission remains unchanged.
Easy and enforce withhold streamed reply drafts until authorization. Audit retains incremental drafts before declaration validation (owner decision, 2026-11-18).
Audit still validates the completed call and executes valid calls whose permission verdict is deny. An invalid call can require correction after its draft appeared.
An explicit `[]` remains valid for content that uses no registered source. This does not verify the declaration against the output text.
Runtime-owned constructors default missing sources to `[]` for Worker failure reports, Loop calls, and Task cards (owner decision, 2026-11-17).
They preserve supplied sources. Other model calls, including Station agents and scripts, get no empty default.
This policy removes context-based source checks for undeclared program data. It does not prove that these programs carry no private content.
Requester and destination checks still apply according to mode. Conservative transcript labels can still include the full context.
Rules below default to Hard.

### Easy policy

Easy checks whether the authenticated requester can read each declared IM source.
IM sources are provider conversations and internal Comma Conversations. A Comma Conversation reaches only its participants and supervisors.
Members can share their private messages and channel messages with other destinations without a receipt.
Channel sources also require the connected bot to be in that channel (owner decision, 2026-11-17).
This bot requirement applies to supervisors too. Their clearance replaces the requester membership requirement.
Nonmembers cannot use the bot's access to read those messages. Group supervisors retain their existing clearance.
Easy ignores non-IM audience restrictions, destination writers, public-egress policy, and external-principal placement policy.
It also skips the Hard Task-to-station placement gate.
Platform ownership, credentials, and tool availability remain separate from IFC.

Easy records public-channel messages with a specific channel label.
When the bot is in a public channel, every requester placed inside its workspace can read it, as Hard reads the space. Its full roster is not listed.
When the bot is absent or its presence is unknown, nobody can read it.
Public-channel labels recorded in Easy stay unknown in Hard.
A legacy space label cannot establish channel or bot membership. It stays unknown, including for supervisors.
Missing IM membership, unknown source references, and unlabelled content do not grant access.
Sandbox tool results use the same IM reader check before returning content to the runtime.

Easy document/directory reads use `unclassified_non_im`. Easy ignores it. Hard treats it as unknown and must resolve the audience again, including after mode changes.
Durable files retain their source labels in both modes.

Easy skips sealing and SSH host tags but retains shared-memory writer controls.
SSH results retain their tags so Hard can enforce them after a mode change.
The existing shared `/memory` writer whitelist applies in every mode.

Bot presence is a nullable field on the existing provider scope projection. Unknown presence does not permit a channel read.
Slack reads bot membership from `conversations.info`. Feishu and Lark use the bot-authenticated `members/is_in_chat` endpoint.
Every mode uses bounded background refresh, never decision-time reads.
A failed read keeps the stored value. Verified bot join and leave events update a conversation the store already knows.
A missed event takes effect on the next refresh.
Missing bot-presence facts remain unknown. Direct-message identity checks remain unchanged.
The migration adds one nullable column. Existing scope facts and membership records remain intact.

### Hard policy

A tool request needs a consumed command from the same authority.
Data, forwarded text, and untrusted pages do not authorize a request.
Unknown authority is not permission.
For unknown writers, authenticated ingress establishes the requester as writer only when the destination equals the activation source scope. Other rules remain unchanged.

Source admission distinguishes ordinary flow, authored sources, in-place use, receipts, and instructions.
Ordinary flow requires `readersSubset(destination, source) = yes`.
Non-flow admission needs the policy's readable, unsealed source facts.
Under every declassification policy, a person's own direct or group command is an authored source for that person's request.
The message must be a command item that the requester's authority wrote. Messages of other people, tool results, and agent output stay under the other rules.
An explicit empty source list is empty.
Effect authorization does not inject accumulated model knowledge.
Resolve tenant, destination, membership, source, and request facts at their host boundary.
A decision reads conversation structure and membership only from the stored projection and calls no provider for them (owner decision, 2026-11-04).
Ingress records structure, and provider join and leave events change membership.
When IFC is active, a provider tool call that creates a chat, joins a chat, or adds chat members also refreshes that conversation's stored projection.
A background listing re-reads a conversation's members at most once per 15 minutes per node, when ingress or a decision names it.
A stored member set stays valid until an event or a listing changes it. A missed leave event stays in effect until the next listing.
A conversation without stored structure or a complete member set has unknown writers and members.
The runtime decides each tool call once per round and reuses that verdict when the planned batch runs.

Provider attachments retain trusted ingress labels when delivered to the Router or directly to a bound Task.
Cross-Agent attachment copies retain the source manifest label only when it names the same blob.
Attachment block fields do not set labels. Missing labels remain private. Blob imports join existing destination labels at commit time.
A stale blob whose source path changed has no inferred audience. These rules do not authorize Task data to shared Group storage.

Internal Task reports resolve placement for the Task's human readers, not only the assigned agent.
Stored placement facts and authenticated ingress placement take precedence over provider fallback.
For missing Slack Task-reader facts, read at most 20 named users per connection per resolution.
Cache positive and unknown results for one minute in 4,096 node-local slots, scoped to the installation generation.
Expired entries do not authorize a transfer. Provider failures, disabled installations, and readers past the limit stay unknown.
This does not give general command authority to an agent-authored Task message.
[Task ownership](architecture/DOMAIN_CONCEPTS.md#loop-tasks) grants only the listed Task effects. IFC still checks sources and destinations.
Workers act for their Task requester only during assignment turns, as sandboxes do. Stations and Cloud VMs require public sources. A Task-owned sandbox accepts Task sources.

Receipt expiration is checked at authorization time.
Lean claims sequential receipts atomically at each claim boundary. If a later claim fails, earlier receipts can stay spent without dispatch.
This is not exactly-once delivery or unconditional liveness.

Low-observable payload noninterference applies only when the declared data dependencies are honest.
A proof does not establish that an LLM declared every dependency it used.
`lark.create_chat`, `lark.add_chat_members`, `feishu.create_chat` and `feishu.add_chat_members` check every named recipient as `lark.share_doc` does.
All recipient checks must pass before dispatch, including delivery of the new group name.
These checks cover declared sources. Member grants do not infer group history that the caller did not declare.
Group supervisors (`ifc.supervisors`, CFT Data policy) read all connected conversations, including sealed/shared rooms, spaces, tags, Tasks and Group memory.
Internal Comma conversations are outside this. Sealing still forbids declassification for everyone, supervisors included.
A Group's `memory_writers` controls Router `/memory` mutations. Unrestricted mode allows everyone.
Restricted mode permits only listed activation requesters, including schedule and Loop creators. Missing requesters are refused before commit.
This covers writes, deletes and destination copies through `memory.write`, `fs.*`, `env.copy` into any Group agent, and `migration.import`.
Tools checks workspace events. Peer copies check before their own commit.
The resolver uses `cleared` for supervisor reads with unknown rosters and adds supervisors to known rosters. Destination checks include their access.
Public Slack channels have a company-wide audience, including relevant guest access.
BFT dashboard project members and Task Share and Document Share readers are outside the current IFC model.
Feishu and Lark directory reads (people, departments, the contact data range) carry the space's audience. A chat's details and members carry that chat's audience, and a chat list labels each chat by its own.
A directory read does not return the mobile number of a person whose `mobile_visible` is `false`. The list of a Group's signed-in Feishu or Lark accounts carries the Group's audience.
`fs.read_file` labels a built-in skill file public only when the selected projection entry comes from `BuiltinSkills.snapshot()`.
Bytes and provenance come from the same entry, never persisted `origin`.
Custom skills, including same-name or same-id overrides, and the mixed skill index retain the agent-private default.
Unlabelled user files and unavailable or empty history, device, and MCP results keep their existing labels.
`device.list` and `device.get` are reads and carry the Group's audience. `loop.get` and `loop.list` carry the label the Loop recorded at creation, which its wakes and lifecycle notices also carry; a Loop without one reads as `agent_private`.
MCP, Composio and `ssh.*` results carry the Group's audience, not the round's label; an SSH host key that an operator restricted to a tag adds the tag and serves only people cleared for it and supervisors ([Outbound SSH Session](architecture/DOMAIN_CONCEPTS.md#outbound-ssh-session)).
`oauth.request_authorization` returns a public runtime-minted link without the model's `reason`. The tool has no effect of its own.

### Hard request visibility

Hard/enforce keeps one Session. `IFC.ProjectionRequest` intersects authenticated reply/Task domains. Unknown targets/membership fail closed.
Omit inaccessible bodies/attachments/reminders, foreign assistant/tool pairs and provider continuation.
Hidden results retain fixed visible-call receipts without source/entity/existence/error details.
Map dense refs back before dispatch. Preserve data.
Static Agent instructions and platform registry catalogs remain. Skills require selected `BuiltinSkills.snapshot()` provenance. Dynamic/custom/unknown sections stay hidden.
Assistant/result bounds join visible inputs and targets, including late images. Old entries need bounds, except visible-call receipts.
Compaction joins all inputs. Hide mixed summaries from lower domains. Defer per-domain summaries.
VFS images use one snapshot for labels/blobs. Unsealed remote screenshots stay omitted, without workspace copies.
Enforce narrows tools to `end_turn` after eight visible no-progress rounds, without visible active async work or unresolved delegation.
Count local errors, terminal empty results, unavailable receipts and repeats. Pending/useful results reset the streak.
The cap excludes hidden history/Group task counts. Reply IFC checks, wait contracts and Lean settlement stay unchanged.
Ingress seals source and Group catalog segments separately.
The cap is no execution lock or total-round bound. Invalid replies can exhaust the repair budget.
Keep prefix/catalogs stable across time and caps. Put guidance in tool descriptions.
Use selected built-in reply field names/types/required keys. Exclude values/examples/tenant manuals.
Old inputs need sealed source text. Off/audit/easy stay unchanged.
Lower-target effects rely on honest declarations and Lean checks, without injected view bounds. No global zero-leakage guarantee.

## IFC proof scope

Existing decision soundness proofs describe Hard. Easy has runtime boundary tests, not a corresponding decision soundness theorem.

`ifc` help describes policy, not a second authorization engine.
A denial points to that topic through `help_tool` and `help_params`, unless the activation has no authenticated requester.

Resolution reports all unknown refs. Public-egress checks report all non-public sources. Admission reports all restricted sources.
Each stage must pass before the next runs. Request and writer failures keep an empty source-failure list.
The top-level clause/ref names the first failure.

Before a retry, the agent must remove restricted information from its answer and declare only the sources the revised answer uses.
Removing refs alone does not authorize the original content. User-facing source names stay subject to the requester's read permission.

Do not accept `sorryAx` or native-evaluation shortcuts as proof evidence.

## What runtime tests still protect

Keep codec compatibility, malformed-wire rejection, C/ETF ownership, facade dispatch, resolver facts, and host authorization integration tests.
Keep runtime lattice, fact-change, and compaction properties.
Abstract label laws do not prove that a host transformation preserves those facts.
Remove redundant tests only with executable proofs for their exact property and domain.
Do not replace runtime failure, concurrency, or provider tests with pure reduction proofs.
