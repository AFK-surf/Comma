# Meetings and calendar

## Dashboard meeting preparation

BFT organization owners and admins configure team preparation at **Meetings > Preparation settings**.
Each Agent Swarm uses its existing Salix Group identity. The page creates no second meeting or preparation lifecycle.
`MeetingCalendarSettings` stores the Group's calendar enrollment in Postgres. Saved settings override deployment defaults for that Group, including when paused.

Selected calendars' meeting details become team content in the selected channel.

Research starts twenty minutes before delivery and uses the existing authorized public-source contract.
With research off, the notice has only the title, time, event link, and Meet link. It creates no research triggers and does not copy the invitation description.
An existing personal-reminder rule still schedules attendee DMs without research.
Calendar writeback and automatic joining are separate opt-in actions.

New Dashboard enrollments leave attendee DMs off. Administrators can enable them for the selected bot.
Enabling DMs needs the OAuth scopes `users:read.email`, `im:write`, and `chat:write`. Existing enabled enrollments stay editable when scope evidence is missing.
Changing the bot resets the toggle. Saving without the field keeps the existing rule for the same bot.
The rule uses the `personal_preparation` setting. It applies to attendees matched to Slack accounts and respects their opt-outs.
The scope status comes from the current connection snapshot. It does not prove delivery or grant OAuth permissions.
Team-only plans need shared research completion but no personal recipient roster.
The Dashboard has no personal preference page or route, and the team page never shows personal reports.
The `meeting.preparation.set_personal_reminders` tool controls personal reminders through a trusted Slack origin.

The worker reads saved settings on each pass, every 120 seconds by default. A healthy pass applies settings within that interval plus the pass work budget.
Provider or storage failures produce bounded errors, and the next pass can retry. The Dashboard must not show missing status as an empty calendar.
Saving settings does not enable a disabled runtime service. The page reports that condition separately.

Each save advances the Group's settings revision. New dispatch and preparation effects must match the current enabled revision.
Pause and scope changes revoke old revisions before new effects are admitted. Messages already accepted into the Conversation log cannot be recalled.
Revision checks are not atomic with provider writes. An effect admitted before a change may finish after it.
Storage failures deny effects until the current settings can be read.
Settings reuse the calendar and MeetingPlan authorization boundary and add no release or artifact gate.
After saved settings exist, keep their table during rollback. Older binaries cannot enforce them, so use forward repair.

Refresh is explicit. There is no per-meeting polling. A queued notice does not prove receipt.
Local preview fixtures verify the page and saved settings, not live delivery or deployed acceptance.

## Dashboard meeting history

**Meetings > Upcoming** shows team preparation. **Past meetings** lists ended meetings and material links.
History uses the same owner and admin boundary and selected Agent Swarm as preparation settings.
The server checks organization membership and project ownership on each read. History does not need preparation to stay enabled.

History includes only the configured public Slack team channel, with an active connection in the same tenant and Group.
Private channels, DMs, other connections, other channels, and other providers are excluded before records reach the browser.
Unknown channel visibility denies the read. Dashboard login does not prove Slack membership, and a Dashboard role grants no other meeting sources.
Slack checks the user's current access when they open a recording, Canvas, or thread link.
The page returns no summaries, transcript bodies, content previews, bot tokens, or storage URLs.
Missing source authorization needs a future verified identity binding, not the bot's private-channel access.

Each page uses one indexed Group query, at most twenty state reads with concurrency eight, and one channel lookup, within a fifteen-second RPC budget.
Pages use stable meeting-ID order. Records are sorted by date within each page only. Same-title records stay separate by meeting ID.
An empty filtered page can have a next page. The interface keeps that navigation and shows source errors apart from empty results.

Recording links come from existing Slack artifact permalinks, not the Meet join URL or private storage.
Canvas links need existing publication or channel-sharing evidence. Only HTTPS Slack links are returned.
A captured recording without a shared link differs from a meeting without a recording. Processing alone does not prove a recording exists.
Known legacy Slack preparation messages show their meeting heading, not the full notice.
Page actions do not modify recordings, Canvas, or sharing permissions.

## Personal preparation

An ordinary meeting Worker owns research and wording. The Router starts the Task but does not rewrite the finished preparation.
The product mock and the runtime have separate acceptance states. The runtime contract alone does not prove a reviewed UI or deployed feature.

Input is original public Slack material in the meeting workspace.
`read_shared_source` uses the fixed plan connection and one channel per call.
Private channels, DMs, email, workspace memory, and direct reads from other integrations are out of scope.
Unavailable sources do not prove that no work happened.

Every eligible attendee gets the basic title, time, event link, and Meet link at the reminder time.
Research adds personal advice only when its sources support it. Missing or failed research does not suppress the basic reminder.

Before model review, require a nonempty message from a non-bot author, or a nonempty file admitted by the public source reader.
Recipient identity and bot summaries alone fail this check. Passing it does not prove claims in mixed sources.

## Draft and review sequence

1. Complete shared research.
2. Read the next attendee's bounded private context.
3. Draft that attendee's preparation privately.
4. Run independent source review before the first save.
5. Correct unsupported owner, date, or source claims.
6. Save the reviewed result, then process the next attendee.

The reviewer gets the draft, current UTC, recipient, and source material, without unrelated Session context.
The call envelope's explicit `ifc.sources` references must resolve to stored original tool results, also with IFC off.
That one declaration is the source list for review. A source array encoded once as a JSON string is also accepted.
Use the displayed `src:` references, not tool-call IDs or the whole context.
A private result that lists all recipients cannot flow into one recipient's report or a Task completion message.
This sequence grants no general permission to read private communications. See [IFC](verification.md) for source and audience rules.

## Preparation completion

The roster starts with Calendar invitees, not subscribers.
One active Google Admin connection in the Comma group lets the schedule read Google Group members.
It needs custom OAuth with Directory group read scopes. Calendar scopes do not suffice.
A bounded adapter reads Directory through Composio's pinned proxy, because Comma has no Google token.
Only active, unrestricted Slack users get DMs. Without Admin access, direct invitees still get them.
Connecting later needs a new preparation revision.
Each run scans at most twenty invitees. A failed scan stays retryable and does not block known recipients.
After ten Directory pages per group, the reader fails instead of accepting a partial list.
It saves each member's source group and rechecks membership before a DM.
Removed invites or memberships, opt-outs, cancellation, and the meeting-start cutoff stop DMs.

Resolve every roster page, including empty pages, before research completes.
Each recipient needs a report or a no-action review with original sources and `report: ""`. A no-action review still sends the basic reminder.
Missing originals or failed reads and reviews leave research incomplete.
The first saved review is immutable for its revision.

`personal_reports_pending` covers discovered recipients awaiting reminders.
The meeting rejects `prepared` until shared and personal research complete. These checks do not prove delivery.

The schedule discovers recipients independently of the Worker. Each run resolves at most twenty roster emails and rechecks at most twenty pending recipients.
The participant outbox uses a per-person idempotency key. Use one schedule per meeting, without per-person polling.
Return discovery errors for retry. Do not mark discovery complete before recovery or the deadline.
If advice loses source authorization, send only the basic reminder.
Do not reopen or resend settled rows. Queued does not prove provider delivery.

## Meeting execution and notes

A calendar read does not prove admission. A finished model request does not prove summary delivery.
Use the owner status and explicit error outcome for the failed stage.

If the Google account cannot sign in, the Meet bot joins as a guest. A Meeting that refuses guests fails.
On node stop, bots leave and deliver results. A killed node loses unfinished recordings.
Live ASR (`meetings.live_asr`) adds a transcript section per provider. Its failure does not fail the meeting.

## Google Meet links in Comma chats

A person can ask the Router to join a Google Meet from a Comma chat that the Router takes part in, such as Home.
The Router decides, as for Slack, and calls `meeting.join` ([CommaProvider](../systems/apps/salix_meet/lib/salix_meet/comma_provider.ex)).
Worker and Task chats cannot start a join, because `meeting.join` is Router-only.

- The tool reads the committed message again. It must be a Comma user's message, and its own text must hold the link.
  A `meet_url` from the model must be one of those links. Two links without a `meet_url` are refused as ambiguous.
- The bot joins as a guest on the server runtime (`runtime_policy.join_as = guest`). It does not use the sender's computer.
- One message makes one join. While a Meeting of the same Meet code runs for the same chat, a later request reuses it and asks its join again: a join the runtime refused is retried, a dispatched one is left alone. After it ends, a new request makes a new Meeting.
- The summary materials of such a Meeting carry the chat's audience, and the summary goes back to that Conversation.
- A refusal before the join, such as no configured runtime, goes back to the Router as the tool error.
- After the join request, the Router's messages in the same chat give the status in the sender's app language (`metadata.locale`):
  joining, waiting for a host, joined, and the reason for a failure. "Joined" comes only from the runtime's `in_meeting` report.
- After the meeting, the Router writes the notes as for other providers, and Salix posts them in the same chat. No transcript or audio file is attached.

Keep online replay and provider checks away from real meetings unless the owner approves.
End-to-end evidence records the released revision, account, meeting input, result, and cleanup.
A replay fixture proves neither provider permission nor deployed network access.

## Personal calendar subscription links

`calendar.issue_feed_link` mints the requesting human's private feed credential and returns its `feed_url`.
The model sends that URL to the requester with the normal send_message tools. Issuance behaves the same on every source provider.
Issuance is scoped to the sealed `principal_ref` of the requester. It fails closed without one and rejects a principal from another tenant.
A model-supplied subject cannot widen that scope.

The URL is a bearer credential for read access to the requester's whole calendar.
The runtime does not check the reply destination. An agent that answers in a group chat exposes the URL to that group.
Treat an exposed URL as an exposed credential and reissue to invalidate it.
Reissue rotates the feed under its fence. A concurrent reissue fails with `calendar_feed_stale`.
Rotation stops the previous URL, so a resend by reissue breaks a link the user already added.
Returning a URL does not prove the user received or added it.

## Router-owned meeting summaries

No independent summary LLM runs. Failed or cancelled meetings and frozen or published notes keep their path.

The Router reads all pages through `meeting.read_summary_materials`, then submits with `meeting.submit_summary`.
Both need exact product event, Group, meeting, and request provenance. Transcripts are untrusted.
Submission is IFC egress to the sealed original destination. Request-triggered tools permit only context reads and submission.

CAS-protected submissions are immutable, and identical retries are idempotent. Changed inputs, expired or replaced requests, and stale claims are rejected.
Delivery keeps owner attribution and provider and Canvas publication checkpoints. Acceptance is not delivery.
After publication, `meeting.completed` stays passive context.

Three expired attempts produce `router_summary_timeout`, with no legacy-model fallback.
Delivery telemetry reports waiting as `retained` and terminal failure as `unavailable`.
No exactly-once provider effect or progress under permanent service failure is promised.
