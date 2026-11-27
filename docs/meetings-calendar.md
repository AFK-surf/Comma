# Meetings and calendar

## Dashboard meeting preparation

BFT organization owners and admins configure team preparation at **Meetings > Preparation settings**.
Each Agent Swarm uses its Salix Group identity; the page creates no second meeting or preparation lifecycle.
`MeetingCalendarSettings` stores the Group's calendar enrollment in Postgres. Only these settings enroll a Group. Deployment config names no Group.

Selected calendars' meeting details become team content in the selected channel.

Research starts twenty minutes before delivery and uses the existing authorized public-source contract.
With research off, the notice has only the title, time, event and meeting links, creates no research triggers and copies no invitation description.
An existing personal-reminder rule still schedules attendee DMs without research.
Calendar writeback and automatic joining are separate opt-in actions.

The `channel_notice` setting (default on) controls the shared pre-meeting notice in the team channel.
When off, the plan schedules no channel card and no calendar writeback; saving stores `calendar_writeback` as off.
Research runs only when personal reminders are on: the shared report has no other audience.
Personal reminders, automatic joining, recording, the meeting thread, and published minutes do not depend on this setting.
Saving without the field keeps the choice; settings without it post the notice.
When off, a Slack setting needs no team channel if it joins by `organizer` delivery or only sends personal reminders.

New Dashboard enrollments leave attendee DMs off. Administrators can enable them for the selected bot.
Enabling DMs needs the OAuth scopes `users:read.email`, `im:write`, and `chat:write`. Enabled enrollments stay editable without scope evidence.
Changing the bot resets the toggle. Saving without the field keeps the existing rule for the same bot.
The rule (`personal_preparation`) applies to attendees matched to Slack accounts and respects their opt-outs.
The scope status is the current connection snapshot, not delivery or a grant.
Team-only plans need shared research completion but no personal recipient roster.
No Dashboard page sets personal preferences, and the team page never shows personal reports.
`meeting.preparation.set_personal_reminders` sets them for the trusted Slack, Feishu or Lark requester.

The worker reads saved settings each pass (120 seconds by default). Failures give bounded errors the next pass retries; missing status never shows as an empty calendar.
The worker runs where a meeting runtime is configured; otherwise the page says so.

Each save advances the Group's settings revision; new dispatch and preparation effects must match it.
Pause and scope changes revoke old revisions before new effects are admitted. Messages already in the Conversation log cannot be recalled.
Revision checks are not atomic with provider writes. Storage failures deny effects until settings can be read.
Settings reuse the calendar and MeetingPlan authorization and add no release or artifact gate.
After saved settings exist, keep their table during rollback. Older binaries cannot enforce them, so use forward repair.

Refresh is explicit, without per-meeting polling. Queued is not received.

## Meeting links

A meeting qualifies by a Google Meet, Feishu/Lark (also `vc-<region>.`), Zoom, or Microsoft Teams meeting link. `SalixCalendar.OccurrenceQualification` lists hosts and meeting paths; a product or channel page is not one.
Every qualified meeting is prepared and announced. With automatic joining on, a Google Meet is joined, and a Feishu/Lark link when the Group has a bot of its platform ([Feishu/Lark joins](#feishulark-joins)).
A Google event uses Google's conference (`hangoutLink` or video entry, also from a Zoom or Teams add-on), else the first non-Meet link in its location, then description.
A Meet link only in that text is never used: outside inviters can write it.
A Feishu/Lark event uses `vchat.meeting_url`: Feishu/Lark, Zoom, or Teams, not Meet.
A normalization change bumps `adapter_contract_id` and the `CalendarEnrollmentCache` version; the next enrollment pass reads each source again (member units at eight per pass). A meeting with an organizer keeps its plan and join identity.

## Members' own calendars

The **Calendar source** setting selects either selected calendars or every member's own calendars (`calendar_scope` `members`).
In the members scope, each Google Calendar account connected to the Group adds the calendars it owns (Google `accessRole` `owner`).
Shared or subscribed calendars are not added. Members connect accounts through the bot's link or Connections.
There is no account or calendar count limit. Each enrollment pass lists calendars for at most eight new accounts and two accounts not listed for six hours.
An account without a meeting calendar (failed listing) is not a member and is listed again after ten minutes. A calendar that cannot sync is left out; the others stay.
The other accounts keep their last listing. A removed account's unit and projection are deleted on the next pass.
Enrollment runs beside the worker; a timed-out connect or account keeps the last enrollment.

Each account has its own Comma Calendar (`meeting_enrollment_member`), scan unit and projection.
A scan reads one page of `max_events` indexed items per pass (id order, after the last page), then starts over.
The projection holds at most `max_events` undispatched meetings; only a meeting missing from its own page counts as gone.
A member meeting's ID is its meeting URL and start, so a shared meeting is joined once.
The first unit that dispatches owns the meeting. Another unit takes it over only before dispatch or for a retry, and only when the owner's projection lost it.
A unit whose copy goes away drops the meeting without abandoning it.

The members scope joins and records its meetings unless `autojoin` is off (saved without it: on); off needs `personal_preparation`. It sends no channel notice, attendee reminder, or calendar writeback.
With `personal_preparation` on, one preparer researches each meeting; each member whose calendar holds it gets a direct message; others get none.
A preparer that is not a member or loses its copy hands over to the next unit that scans it; its plan is cancelled.

A Google source that applies changes marks its Calendar (`SalixMeet.CalendarChanges`); a scan pass reads marked calendars first, in at most three quarters of the pass.
A join pass first visits units with a meeting in its join window, then continues the rotation. Each due meeting (at most 25 per unit) is dispatched as its own timed task.

The `delivery` setting `organizer` sends the join notice, status, and minutes in a direct message.
The recipient is the organizer, else the member whose calendar holds the meeting when the organizer has no Slack account, else the team channel; with no team channel it is not joined.
A Feishu/Lark bot applies the same order with the bot's private chats, found by open_id or by email (`contact:user.id:readonly`), also when its notice chat is empty.
Only Slack's answer that the person does not exist moves to the next recipient; other failures retry on a later pass.
It needs the bot scopes `users:read.email`, `im:write`, and `chat:write`. The direct message chosen when the meeting is created stays its target.

## Feishu and Lark team preparation

A Feishu or Lark setting reads that platform's calendars (`LarkCalendarSource`): team calendars the app subscribed to or was added to, or in the members scope each signed-in person's primary calendar.
Sources sync by `sync_token` and are read again every five minutes. Meetings qualify as in [Meeting links](#meeting-links) and are joined only with `autojoin` on (saved without it: off).
These plans (`managed_calendar`) take the Slack system track; deployment `notify` entries keep Router publication.
The shared notice goes to one bot group chat and is optional (`channel_notice`).
Recipients are internal attendees who did not decline, by open_id, reminded in their bot chat (`receive_open_id`).
A Feishu/Lark bot can also take Google calendars (`calendar_source` `google`), selected or the members' own. Google attendees are found by email (`contact/v3/users/batch_get_id`); without that scope they get no reminder, and the team notice still goes. Feishu/Lark calendars cannot notify in Slack.

## Where notices go

The setting's bot (`connect_id`) gets reminders, join notices and minutes. `destination_confirmed_at` records an admin's choice: a page save or `meeting.settings.set_destination` (owner or admin through existing bindings). With Slack and Feishu/Lark bots and no choice, `get_destination` answers `choice_needed`, and the first notice says once, without a new revision, that the other platform can be chosen.

## Feishu/Lark joins

The destination's bot, else the oldest bot of the link's platform, joins by meeting number (`SalixMeet.LarkBot`); same tenant only, gray release on Lark.
A meeting not started (121014) stays pending each join pass until its end, spending no attempt. A refusal (settings, lock, password, permission, policy, a bare HTTP 403) tells the destination once why and retries at most every five minutes; passwords are unsupported. An ended or unknown meeting is given up. An invitation to the same meeting makes no second Meeting.
The minutes carry the meeting's Minutes and AI notes links, read once as the app or a signed-in person.
Research reads the notice chat and public groups; a personal report cites the notice chat only for its members.
Lark events have no version; copies on several calendars order by read send time plus a 1,000-value source suffix. Accepted risk: a tie with different facts stops its calendar's discovery until a copy changes.

## Dashboard meeting history

**Meetings > Upcoming** shows team preparation. The members scope lists each meeting once (up to 25 member projections) with its preparer's reminder state and recipients, marking any Slack cannot find.
**Past meetings** lists ended meetings and material links.
History uses the owner and admin boundary and Agent Swarm of the settings.
Each read checks membership and project ownership; preparation need not stay enabled.

History includes only the configured public Slack team channel of an active connection in the same tenant and Group; the rest is excluded before the browser. Unknown visibility denies the read.
Slack checks current access when a recording, Canvas, or thread link is opened.
The page returns no summaries, transcript bodies, content previews, bot tokens, or storage URLs.

A page is one indexed Group query, at most twenty state reads and one channel lookup, in meeting-ID order; an empty page can have a next one.

Recording and Canvas links are existing Slack permalinks with publication or sharing evidence, HTTPS only. Page actions change no recordings, Canvas, or sharing.

## Personal preparation

An ordinary Worker owns research and wording; Router starts the Task without rewriting its output.

Input is public Slack channels or Feishu/Lark notice/public chats. `read_shared_source` uses the fixed connect, checks visibility before/after reading, and supports `recent_meetings` (pointer-only `complete`|`partial`|`unavailable`, newest first) alongside `history`/`replies`/`search`/`file` (with `unexpanded_threads` and cursor provenance). Research covers intervening notice-channel meetings across titles and expands threads/pages. Private channels, DMs, email, memory, and other integrations are out of scope; missing or incomplete sources prove no absence of work.

Every eligible attendee gets the basic title, time, and links at reminder time; research adds advice only when supported and never suppresses the basic reminder. Model review requires a nonempty non-bot message or admitted file (identity and bot summaries alone fail); passing proves no claim.

## Draft and review sequence

Complete shared research; per attendee read bounded private context, draft privately, run source review before the first save, correct unsupported claims, and save.

Review gets the draft, UTC time, recipient, and deduplicated originals (up to 512 KB). `ifc.sources` (`src:` refs) must resolve to stored originals, even with IFC off. Private recipient lists never enter one report or Task final, and this grants no private-communication access ([IFC](verification.md)).

## Preparation completion

The roster is Calendar invitees, not subscribers.
One active Google Admin connection (custom OAuth with Directory group read scopes, through Composio's pinned proxy) lets the schedule read Google Group members.
Only active, unrestricted Slack users get DMs. Without Admin access, direct invitees still get them.
Connecting later needs a new preparation revision.
Each run scans at most twenty invitees; a failed scan stays retryable and blocks no known recipient.
After ten Directory pages per group, the reader fails instead of accepting a partial list.
It saves each member's source group and rechecks membership before a DM.
Removed invites or memberships, opt-outs, cancellation, and the meeting-start cutoff stop DMs.

Resolve every roster page, including empty pages, before research completes.
Each recipient needs a report or a no-action review (original sources, `report: ""`), which still sends the basic reminder.
Missing originals or failed reads and reviews leave research incomplete.
The first saved review is immutable for its revision.

`personal_reports_pending` covers discovered recipients awaiting reminders.
The meeting rejects `prepared` until shared and personal research complete.

The schedule discovers recipients apart from the Worker and rechecks at most twenty pending recipients per run.
The participant outbox uses a per-person idempotency key. Use one schedule per meeting, without per-person polling.
Return discovery errors for retry. Do not mark discovery complete before recovery or the deadline.
If advice loses source authorization, send only the basic reminder.
Do not reopen or resend settled rows.

## Meeting execution and notes

Automatic placement tries the Group's VMM Station, another connected meeting runtime, then the native runtime.
A Group with an authorized Agent VMM Host has its VMM Station made and woken for a join, and waits at most 15 seconds for it to connect with its meeting runtime.
The VMM Station runs meet-native beside the station, so the Group's meetings share it.
Comma and BFT use the same placement and dispatch rules.

Each join attempt keeps its selected target before dispatch. Chat, status, and termination follow that target.
Placement can try another target after a confirmed failure before acceptance, such as a readiness deadline before dispatch.
After a join request is sent, a timeout or unknown outcome keeps the original target.
An accepted join cannot move to another runtime. Explicit runtime selection keeps its named source.

A calendar read does not prove admission, nor a finished model request summary delivery; the owner status and error name the failed stage.

If the Google account cannot sign in, the Meet bot joins as a guest; a Meeting refusing guests fails.
One active bot per Group serves each Meet code: a join from another thread returns `already_in_meeting` instead of making a second Meeting, and a runtime session reused for another `meeting_id` is refused.
On node stop, bots leave and deliver results; a killed node loses unfinished recordings.
Live ASR (`meetings.live_asr`) adds a transcript section per provider without failing the meeting.

## Google Meet links in Comma chats

A person can ask the Router to join a Google Meet from a Comma chat the Router takes part in, such as Home.
The Router calls `meeting.join` ([CommaProvider](../systems/apps/salix_meet/lib/salix_meet/comma_provider.ex)); Worker and Task chats cannot join.

- The tool rereads the committed Comma user message; its text must hold the link, and a model `meet_url` must be one of them.
- The bot joins as a guest (`runtime_policy.join_as = guest`) on the selected runtime.
- One message makes one join. While a Meeting of the same Meet code runs for the same chat, a later request reuses it (a refused join retries; a dispatched one stays). A request from another chat of the same Group returns `already_in_meeting`. After it ends, a new request makes a new Meeting.
- Summary materials carry the chat's audience, and notes go back to that Conversation without transcript or audio files.
- A refusal before the join goes back to the Router as the tool error.
- After the join request, Router messages in the same chat report status in the sender's app language (`metadata.locale`): joining, waiting for a host, joined (only from `in_meeting`), and failure reason.

Keep online replay and provider checks off real meetings without owner approval.
A replay fixture proves no provider permission or deployed network access.

## Personal calendar subscription links

`calendar.issue_feed_link` mints the requesting human's private feed credential and returns its `feed_url`.
The model sends that URL to the requester with the normal send_message tools, on every provider.
Issuance is scoped to the sealed `principal_ref` of the requester. It fails closed without one and rejects a principal from another tenant.
A model-supplied subject cannot widen that scope.

The URL is a bearer credential to read the requester's whole calendar.
The runtime does not check the reply destination. An agent that answers in a group chat exposes the URL to that group.
An exposed URL is an exposed credential; reissue to invalidate it.
Reissue rotates the feed under its fence. A concurrent reissue fails with `calendar_feed_stale`.
Rotation stops the previous URL, so a resend by reissue breaks a link the user already added.
Returning a URL proves no receipt or use.

## Router-owned meeting summaries

No independent summary LLM runs. Failed or cancelled meetings and frozen or published notes keep their path.

The Router reads all pages through `meeting.read_summary_materials`, then submits with `meeting.submit_summary`.

Without a canonical transcript, each ASR line takes the speaker of the live caption matching its text near its time (offset from matched text), or `Unknown`; with too few matches it is the raw ASR.

Each materials page returns `participants`: live-caption speakers, incoming chat senders, and the native runtime's roster of everyone who joined, at most 100.
The recording ASR prompt asks for these names and the correct forms in the Router's `/memory/semantic/glossary.md` as written; a term without a misheard form is `- → Acme Cloud`.
Submission rejects an attendee or a nonempty owner that names no participant. A meeting without participants has no name check.
Each page also returns `reference_paths`: the Router's `/memory/semantic/people.md` and `glossary.md`.
The Router reads them with `memory.get`, so their labels apply to the summary.

The glossary is described in [DOMAIN_CONCEPTS](architecture/DOMAIN_CONCEPTS.md); meeting memory applies it and corrects at most 200 earlier meeting files.
Both need exact product event, Group, meeting, and request provenance. Transcripts are untrusted.
Submission is IFC egress to the sealed original destination. Request-triggered tools permit only context reads and submission.

CAS-protected submissions are immutable, and identical retries are idempotent. Changed inputs, expired or replaced requests, and stale claims are rejected.
Delivery keeps owner attribution and provider and Canvas publication checkpoints. Acceptance is not delivery.
After publication, `meeting.completed` stays passive context.

Three expired attempts produce `router_summary_timeout`, with no legacy-model fallback.
No exactly-once provider effect or progress under permanent service failure is promised.
