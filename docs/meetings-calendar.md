# Meetings and calendar

## Ownership

Calendar adapters normalize source events. Salix owns meeting admission and execution.
Provider calendars, meeting occurrences, Agent work, and product reminder settings are separate facts.
A calendar connection is not a guarantee that a bot joined or a recipient received preparation.
Use the current admission outcome and runtime status to diagnose that boundary.
Keep provider retry, reconnect, cancellation, and owner activation bounded.

## Dashboard meeting preparation

BFT organization owners and admins configure team preparation at **Meetings > Preparation settings**.
Each Agent Swarm uses its existing Salix Group identity. This page does not create a second meeting or preparation lifecycle.
`MeetingCalendarSettings` stores the Group's calendar enrollment choices in Postgres.
Saved settings override deployment defaults for that Group, including when preparation is paused.
The additive migration preserves existing calendars, plans, reports, and deployment defaults. It makes no provider requests.

Select up to ten calendars across connected Google Calendar accounts, then select a Slack channel that the bot has joined.
Selections use exact account and calendar IDs. A calendar name alone does not identify a source.
The page can select all eligible meetings or one meeting series. Series browsing reads the next fourteen days, fifty events per page.
Preparation requires a supported Google Meet link under the existing calendar qualification rules.
Connecting another account does not select its calendars or enable preparation.
The selected calendars' meeting details become team content in the selected channel.

Choose delivery ten, fifteen, thirty, or sixty minutes before the meeting.
Research starts twenty minutes before delivery and uses the existing authorized public-source contract.
Turning research off sends only the meeting title, time, event link, and Meet link.
It creates no research triggers and does not copy the invitation description into the notice.
An existing personal-reminder rule still schedules attendee DMs without research.
Use the event link to read the original agenda.
Calendar writeback and automatic joining are separate opt-in actions.
New Dashboard enrollments leave attendee DMs off. Administrators can enable or disable them for the selected bot in preparation settings.
Enabling DMs requires known OAuth scopes: `users:read.email`, `im:write`, and `chat:write`. Existing enabled enrollments remain editable when scope evidence is missing.
Changing the bot resets the form toggle. Saving without the field preserves the existing rule for the same bot.
The rule uses the existing `personal_preparation` setting. It applies to attendees matched to Slack accounts and respects their personal opt-outs.
The scope status comes from the current connection snapshot. It does not prove delivery or grant new OAuth permissions.
Team-only plans require shared research completion but do not open or wait for a personal recipient roster.
Dashboard hides personal preferences while their product design and verified Dashboard-to-Slack identity binding remain unresolved.
The team page never displays personal reports.

The service must enable `meetings.calendar_autojoin`; an empty `channels` object permits Dashboard-managed enrollments without deployment defaults.
The worker reads saved settings on each pass, subject to its existing group and lease budgets.
The default scan interval is 120 seconds. A healthy pass applies settings within that interval plus the configured pass work budget.
Provider or storage failures produce bounded errors and the next pass can retry. The Dashboard must not present missing status as an empty-calendar fact.
Saving settings does not enable a disabled runtime service. The page reports that condition separately.

Each save advances the Group's settings revision. New dispatch and preparation effects must match the current enabled revision.
Pause and scope changes revoke old revisions before new effects are admitted. Provider messages already accepted into the Conversation log cannot be recalled through this page.
Revision checks are not atomic with provider writes. An in-flight effect admitted before a settings change may finish afterward.
Storage failures deny effects until the current settings can be read.
This reuses the calendar and MeetingPlan owners' authorization boundary. It does not add a release or artifact gate.
After saved settings exist, retain their table during rollback. Older binaries cannot enforce those settings, so use forward repair for this feature.

The preparation selector lists at most fifty Agent Swarms. The meeting list shows at most twenty projected meetings. The channel picker retains at most five hundred channels.
Refresh is explicit; there is no per-meeting polling. A queued notice is not proof that a recipient received it.
Local preview fixtures verify the rendered page and saved settings, not live provider delivery or deployed acceptance.

## Dashboard meeting history

**Meetings > Upcoming** retains team preparation. **Past meetings** lists existing ended meetings and material links.
The page uses the same organization-owner/admin boundary and selected Agent Swarm as preparation settings.
The server checks organization membership and project ownership for each read, not only when the page mounts.
History does not require preparation to remain enabled.

History includes only the configured public Slack team channel, with an active connection in the same tenant and Group.
Private channels, DMs, other connections, other channels, and other providers are excluded before records reach the browser.
Unknown channel visibility denies the read. Dashboard login does not prove Slack membership.
The configured channel is the explicit team-content scope. A Dashboard role alone does not grant access to other meeting sources.
Slack checks the human's current access when they open a recording, Canvas, or thread link.
The page returns no summaries, transcript bodies, content previews, bot tokens, or storage URLs.
Missing source authorization requires a future verified identity binding, not a fallback to the bot's private-channel access.

Meeting state and the existing sealed Group projection remain authoritative. There is no new meeting entity, migration, or recording system.
Each page uses one indexed Group query, at most twenty exact state reads with concurrency eight, and one channel lookup.
The read has a fifteen-second RPC budget and no polling. It does not use the deployment-wide meeting scan.
Pages use stable meeting-ID order. Visible records are sorted by date within each page, not across the entire history.
An empty filtered page can have a next page. The interface preserves that navigation and distinguishes source errors from an empty result.
Records with the same title stay separate because links belong to the exact meeting ID.

Recording links come from existing Slack artifact permalinks, not the Meet join URL or private storage.
Canvas links require existing publication or channel-sharing evidence. Only HTTPS Slack links are returned.
A captured recording without a shared link differs from a meeting without a recording.
Meeting processing alone does not prove that a recording exists. The page describes that state without promising a recording.
History rows show bounded titles. Known legacy Slack preparation messages show their meeting heading, not the full notice.
Selecting a row opens its material links in a separate dialog. Closing the dialog retains the current page.
The Dashboard has no personal preference page or route.
The `meeting.preparation.set_personal_reminders` tool still controls personal reminders through a trusted Slack origin.
Changing settings, selecting another Agent Swarm, or refreshing does not modify recordings, Canvas, or sharing permissions.

## Calendar worker lease

`SalixMeet.CalendarAutojoin` checks remote lease ownership before and after
bounded enrollment writes, group work, projection checkpoints, and cursor checkpoints.
A lease with enough time remaining uses the existing ETag HEAD check; otherwise
it renews with a conditional PUT. HEAD completion is followed by another time check.
The next-phase budget is the configured number of task waves times the task timeout,
plus 120 seconds for requests. ConfigJson admission keeps the work waves below
180 seconds within the 300-second lease TTL.

Failed ownership checks discard pending intents or unpublished state and stop that pass.
Each business object retains its own CAS. A lease check does not atomically fence
subsequent writes to separate objects. The implementation and regression tests are
in `systems/apps/salix_meet/lib/salix_meet/calendar_autojoin.ex` and the adjacent app tests.

## Personal preparation

When an enrollment enables personal preparation, organization rules include current attendees unless they opt out.
An ordinary meeting Worker owns research and wording.
The Router starts the Task but does not rewrite the Worker's finished preparation.
The product mock and the runtime implementation have separate acceptance states.
Do not claim a reviewed UI or deployed feature from the runtime contract alone.

This version uses original public Slack material in the meeting workspace.
`read_shared_source` uses the fixed plan connection and one channel per call.
Private channels, DMs, email, and workspace memory are outside this personal-preparation input scope.

Every eligible attendee receives the basic meeting title, time, event link and Meet link at the configured reminder time.
Research adds personal advice only when its sources support it. Missing, unfinished or failed research does not suppress the basic reminder.
Do not turn a suggestion into a commitment or invent an owner, date, or deadline.
Preserve source links and check dates against current UTC during review.
A summary is not evidence of an original commitment without its source.

Find the latest completed occurrence of the same meeting. Verify its date from original timestamps.
Read its full human transcript or exchange and relevant newer public discussions.
Use the period since that occurrence ended unless the meeting specifies another period.
Without a prior occurrence, use the agenda and recent evidence.
Adapt topics, searches and wording to the meeting's purpose and cadence. No provider or fixed topic category is required.
This does not expand source access. Direct reads from other integrations remain unsupported.
Unavailable sources do not prove that no work happened.

Transcripts can mishear names. Establish the entity from context and prefer relevant public written originals for spelling.
Sound or repeated transcription alone is insufficient. If uncertain, describe the supported topic without naming it.
Do not list candidate names or ask attendees to resolve transcription errors. Preserve unrelated names and valid abbreviations.

Calendar details contain shared follow-ups, changes and decisions, with brief background and a source-backed discussion focus.
Name people only when public originals establish their relation to the topic.
Use ordinary Markdown profile links only for source-verified names and profile URLs or Slack identities. Otherwise use supported plain names.
Never guess identities or copy the private recipient index into Calendar details.
Preserve roles: speaking or proposing does not establish ownership. Profile links do not request notifications. Provider mentions remain disabled.

Personal advice gives short, source-linked follow-ups and relevant progress. Merge records about the same work and omit unsupported sections.
Do not impose a daily stand-up format on other meetings.
Distinguish proposals, ongoing work and completed outcomes. Thread updates alone do not prove new work.
Separate later requests from previous meeting commitments. If a supported commitment has no recorded outcome, say so.
Do not infer failure or completion from silence, invent homework, or demand progress reports.
Link the previous summary once without retelling it or inventing work to meet a length target.
A greeting and summary link alone are not useful personal advice.
After source review, retain supported context or record that no advice is supported. Basic reminders require no model review.

Before model review, require a nonempty message from an author not marked as a bot, or a nonempty file admitted by the public source reader.
Recipient identity and bot summaries alone fail this check. Passing it does not prove claims in mixed source material.

## Draft and review sequence

1. Complete shared research.
2. Read the next attendee's bounded private context.
3. Draft that attendee's preparation privately.
4. Run independent source review before the first save.
5. Correct unsupported owner, date, or source claims.
6. Save the reviewed result, then process the next attendee.

The reviewer receives the draft, current UTC, recipient, and source material.
Do not include unrelated Session context.
The call envelope's explicit `ifc.sources` references must resolve to stored original tool results, including with IFC off.
Personal publication uses that one declaration for source review. It has no second source-list argument.
The host also accepts a source array encoded once as a JSON string. The same source checks apply.
Use the displayed `src:` references, not tool-call IDs or the whole context.
A private navigation result listing all recipients cannot flow into one recipient's report.
A Task completion message must not reveal that private recipient list.

This sequence separates shared research from per-recipient authority.
It does not create a general permission to read private communications for calendar preparation.
See [IFC](verification.md) for the remaining source and audience rules.

## Preparation completion

The roster starts with Calendar invitees, not subscribers.
One active Google Admin connection in the Comma group lets the schedule read Google Group members.
It needs custom OAuth with Directory group read scopes; Calendar scopes do not suffice.
Comma has no Google token, so the Google SDK cannot use this connection. A bounded adapter reads Directory through Composio's pinned proxy.
Only active, unrestricted Slack users receive DMs. Without Admin access, direct invitees still receive them.
Connecting later needs a new preparation revision.
Each run scans at most twenty invitees. A failed scan remains retryable and does not block known recipients.
After ten Directory pages per group, the reader fails instead of accepting a partial list.
It saves each member's source group and rechecks membership before a DM.
Removed invites or memberships, opt-outs, cancellation, and the meeting-start cutoff stop DMs.
The scan must finish before research completes.

Resolve every roster page, including empty pages, before completing research.
Each recipient needs a report or a no-action review with original sources and `report: ""`.
A no-action review omits advice, but the basic reminder still goes out.
Missing originals or failed reads and reviews leave research incomplete.
The first saved review is immutable for its revision.

`read_status.personal_research_complete` covers roster discovery, group scan, and each person's research.
`personal_reports_pending` covers discovered recipients awaiting reminders.
An empty queue or basic reminder without review does not prove research complete.
The meeting rejects `prepared` until shared and personal research complete.
These checks use stored state. They do not prove delivery or human acceptance.

The schedule discovers recipients independently of the Worker.
Each run resolves at most twenty roster emails and rechecks at most twenty pending recipients.
Empty pages continue. The participant outbox uses a per-person idempotency key.
Return discovery errors for retry. Do not mark discovery complete before recovery or the deadline.
Use one schedule per meeting, without per-person polling.
If advice loses source authorization, send only the basic reminder.
Do not reopen or resend settled historical rows. Queued does not prove provider delivery.

The group-scan migration adds progress and source-group links without changing settled revisions, saved reports, or providers.

## Meeting execution and notes

Joining, live capture, transcript processing, summary generation, and summary delivery are distinct runtime stages.
A successful calendar event read does not establish meeting admission or live connectivity.
A completed model request does not establish visible summary delivery.
Use the owner status and explicit error outcome for the failed stage.

Keep online replay and provider checks isolated from real meetings unless the owner authorized the interaction.
Record the exact released revision, account, meeting input, observed result, and cleanup for end-to-end evidence.
A replay fixture cannot prove current provider permission or deployed network access.

## Personal calendar subscription links

`calendar.issue_feed_link` mints the requesting human's private feed credential and returns its `feed_url`.
The model sends that URL to the requester in its own reply, with the normal send_message tools.
Issuance owns no destination, so it behaves the same on every source provider.

Issuance is scoped to the sealed `principal_ref` of the human who asked.
It fails closed without one, and rejects a principal from another tenant.
A model-supplied subject cannot widen that scope.

The URL is a bearer credential for read access to the requester's whole calendar.
The tool description instructs the model to send it only where that one requester reads.
The runtime does not check the reply destination: an agent that answers in a group chat exposes the URL to that group.
Treat an exposed URL as an exposed credential and reissue to invalidate it.

Reissue rotates the existing feed under its fence and returns the replacement URL.
The fence makes a concurrent reissue fail with `calendar_feed_stale` instead of returning a secret the winner already replaced.
Rotation stops the previous URL working, so reissuing to resend breaks a link the user already added.
Returning a URL does not prove the user received or added it.

## Router-owned meeting summaries

Completed Slack/Feishu meetings persist a versioned material request before
waking the Group Router. ASR/calibration remain unchanged; no independent summary
LLM runs. Failed/cancelled meetings and frozen/published notes keep their path.

Router reads all pages via `meeting.read_summary_materials`, then submits the
existing schema with `meeting.submit_summary`. Both require exact product event,
Group, meeting and request provenance. Transcripts are untrusted. Names require
contextual evidence, not phonetic guesses. Submission is IFC egress to the sealed
original destination; request-triggered tools permit only context reads and
submission, not separate messages, tasks, issues, scheduling or delegation.

CAS-protected submissions are immutable and identical retries idempotent. Changed
inputs, expired/replaced requests and stale claims are rejected. Delivery keeps
owner attribution and existing provider/Canvas publication checkpoints: acceptance
is not delivery. Post-publication `meeting.completed` stays passive context.

The durable sweep retries enqueue with the same source ID until ten minutes,
then replaces the request ID. Three expired attempts produce
`router_summary_timeout`, not a legacy-model fallback. Existing delivery telemetry
reports waiting as `retained`, terminal failure as `unavailable`. Implementation
regressions cover persistence/enqueue ordering, paging, CAS, request replacement,
Router wake/dedup, provenance, IFC, and the attribution gate. No exactly-once
provider effect or progress under permanent service failure is promised.
