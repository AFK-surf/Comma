import { Button, Dropdown } from "@comma/ui";
import { useRef, useState, type CSSProperties, type ReactNode } from "react";
import type {
  BftTriageAgent,
  BftTriageContext,
  BftTriageItem,
  BftTriageMessage,
  BftTriageNav,
  BftTriageOutcome,
  BftTriageReveal,
} from "./api";
import { writeErrorMessage } from "./dialogs";
import { formatDateTime } from "./format";
import { DetailDialog } from "./MeetingsPage";
import { messages } from "./messages";
import { useApi, useResource } from "./resource";
import { FormSection } from "./settingsForm";
import { Skeleton } from "./states";
import {
  activityCounts,
  channelNames,
  companionLabel,
  contextKindLabel,
  contextStateLabel,
  contextTone,
  delegationLabel,
  durationText,
  effectSummary,
  evidenceText,
  heatmapView,
  outcomeBody,
  outcomeLabel,
  outcomeSettled,
  outcomeTone,
  processingDescription,
  processingLabel,
  processingTone,
  slackMs,
  threadGroups,
  type HeatmapRange,
} from "./triageModel";

const t = messages.triage;
const tl = messages.triage.timeline;
const kinds = ["all", "reply", "reaction", "silence", "investigation"] as const;
const allChannels = "all";

/** Revealed text by message ref, or the reason it stayed hidden. */
type Revealed = Record<string, BftTriageReveal[string] | { error: string }>;

/**
 * The selected Agent's replies, reactions, silence decisions and collected
 * context, grouped by Slack thread, one cursor page at a time.
 */
export function TriageTimeline({
  org,
  agent,
  refresh,
}: {
  org: string;
  agent: BftTriageAgent;
  refresh: number;
}) {
  const api = useApi();
  const [filters, setFilters] = useState({
    kind: "all",
    channel: null as string | null,
    before: null as number | null,
  });
  const [cursors, setCursors] = useState<string[]>([]);
  const nav: BftTriageNav = { ...filters, cursor: cursors[cursors.length - 1] ?? null };
  const page = `${org}:${agent.id}:${JSON.stringify(nav)}:${refresh}`;
  const [activity, retry] = useResource(`triage-activity:${page}`, (signal) =>
    api.triageActivity(org, agent.id, nav, signal)
  );
  const [heatmap] = useResource(
    `triage-heatmap:${org}:${agent.id}:${refresh}`,
    (signal) => api.triageHeatmap(org, agent.id, signal)
  );
  const [range, setRange] = useState<HeatmapRange | null>(null);
  const [expanded, setExpanded] = useState(false);
  const [open, setOpen] = useState<BftTriageItem | null>(null);
  // Reveals belong to the page they were made on; a late answer for an
  // earlier page is dropped.
  const [revealed, setRevealed] = useState<{ page: string; texts: Revealed }>({
    page,
    texts: {},
  });
  const current = useRef(page);
  current.current = page;
  const texts = revealed.page === page ? revealed.texts : {};

  const reveal = (refs: string[]) => {
    const asked = page;
    api.revealTriageText(org, agent.id, refs, nav).then(
      (shown) =>
        current.current === asked &&
        setRevealed((value) => ({
          page: asked,
          texts: {
            ...(value.page === asked ? value.texts : {}),
            ...Object.fromEntries(refs.map((ref) => [ref, { error: tl.messageGone }])),
            ...shown,
          },
        })),
      (error: unknown) =>
        current.current === asked &&
        setRevealed((value) => ({
          page: asked,
          texts: {
            ...(value.page === asked ? value.texts : {}),
            ...Object.fromEntries(
              refs.map((ref) => [ref, { error: writeErrorMessage(error) ?? "" }])
            ),
          },
        }))
    );
  };

  const filter = (patch: Partial<typeof filters>) => {
    setFilters((value) => ({ ...value, ...patch }));
    setCursors([]);
  };

  const names = channelNames(agent);
  const channels = [
    ...new Map([...names].map(([key, label]) => [key.split("/")[1] ?? key, label])),
  ].toSorted((a, b) => a[1].localeCompare(b[1]));
  const data = activity.state === "ready" ? activity.data : undefined;
  const threads = data ? threadGroups(data.items, names) : [];
  const counts = data ? activityCounts(data.items) : undefined;
  const view =
    heatmap.state === "ready"
      ? heatmapView(heatmap.data, names, range, expanded)
      : null;
  const filtered =
    filters.kind !== "all" || filters.channel !== null || filters.before !== null;

  return (
    <div className="bft-triage-grid">
      <div className="bft-triage-main">
        <div className="bft-triage-filters">
          <Dropdown
            ariaLabel={tl.show}
            items={kinds.map((kind) => ({ id: kind, label: tl.kinds[kind] }))}
            onChange={(kind) => filter({ kind })}
            size="sm"
            value={filters.kind}
            width="content"
          />
          {channels.length > 0 ? (
            <Dropdown
              ariaLabel={tl.channel}
              items={[
                { id: allChannels, label: tl.allChannels },
                ...channels.map(([id, label]) => ({ id, label })),
              ]}
              onChange={(channel) =>
                filter({ channel: channel === allChannels ? null : channel })
              }
              size="sm"
              value={filters.channel ?? allChannels}
              width="content"
            />
          ) : null}
          {counts && counts.total > 0 ? (
            <span className="bft-tag" id="triage-activity-summary">
              {[
                tl.visibleOutcomes(counts.total),
                `${tl.reply} ${counts.reply}`,
                `${tl.reaction} ${counts.reaction}`,
                `${tl.silent} ${counts.silence}`,
                counts.inProgress ? `${tl.inProgress} ${counts.inProgress}` : "",
                counts.failed ? `${tl.failed} ${counts.failed}` : "",
              ]
                .filter(Boolean)
                .join(" · ")}
            </span>
          ) : null}
        </div>

        {view ? (
          <Heatmap
            truncated={heatmap.state === "ready" && heatmap.data.truncated}
            expanded={expanded}
            nav={nav}
            onExpand={() => setExpanded((value) => !value)}
            onRange={setRange}
            onSelect={(channel, before) => filter({ channel, before })}
            view={view}
          />
        ) : null}

        {filters.before !== null ? (
          <p className="bft-row-title" id="triage-activity-time-filter">
            <span className="bft-tag">{tl.before(formatDateTime(filters.before))}</span>
            <button
              className="bft-btn bft-btn-sm"
              onClick={() => filter({ before: null })}
              type="button"
            >
              {tl.showLatest}
            </button>
          </p>
        ) : null}

        {activity.state === "loading" ? (
          <div className="bft-rows-skeleton bft-rows-skeleton-flush">
            <Skeleton height={14} width="40%" />
            <Skeleton height={48} />
            <Skeleton height={48} />
          </div>
        ) : activity.state === "error" ? (
          <output className="bft-quiet-row">
            <p className="bft-quiet bft-quiet-inline">
              {writeErrorMessage(activity.error)}
            </p>
            <button className="bft-btn bft-btn-sm" onClick={retry} type="button">
              {messages.states.retry}
            </button>
          </output>
        ) : data ? (
          <>
            {data.intake_status === "unavailable" ? (
              <p className="bft-notice">{tl.intakeUnavailable}</p>
            ) : null}
            {threads.length === 0 ? (
              <div className="bft-quiet bft-quiet-inline">
                <p>{filtered ? tl.noMatchTitle : tl.emptyTitle}</p>
                <p>{filtered ? tl.noMatchBody : tl.emptyBody}</p>
              </div>
            ) : (
              <ol className="bft-list bft-feed" id="triage-activity-feed">
                {threads.map((thread) => (
                  <li className="bft-thread" data-role="thread" key={thread.key}>
                    <div className="bft-thread-head">
                      <span className="bft-status" data-tone={thread.tone}>
                        <strong>{thread.channel}</strong>
                      </span>
                      <span className="bft-tag">
                        {tl.thread} {formatDateTime(thread.startedAt ?? thread.at)}
                      </span>
                      {thread.rows.length > 1 ? (
                        <span className="bft-tag">
                          {tl.activities(thread.rows.length)}
                        </span>
                      ) : null}
                      {thread.url ? (
                        <a
                          className="bft-link bft-thread-link"
                          href={thread.url}
                          rel="noopener noreferrer"
                          target="_blank"
                        >
                          {tl.openInSlack}
                        </a>
                      ) : null}
                    </div>
                    {thread.rows.map((row) => (
                      <div
                        className="bft-feed-row"
                        data-kind={row.kind}
                        id={row.id}
                        key={row.id}
                      >
                        <Messages
                          messages={row.messages}
                          onReveal={reveal}
                          texts={texts}
                        />
                        <Decision item={row} onOpen={() => setOpen(row)} />
                      </div>
                    ))}
                  </li>
                ))}
              </ol>
            )}
            {cursors.length > 0 || data.next_cursor ? (
              <nav aria-label={tl.pager} className="bft-form-actions">
                <span className="bft-tag">{tl.page(cursors.length + 1)}</span>
                <Button
                  disabled={cursors.length === 0}
                  hierarchy="secondary-gray"
                  onPress={() => setCursors((value) => value.slice(0, -1))}
                  size="sm"
                >
                  {tl.previous}
                </Button>
                <Button
                  disabled={!data.next_cursor}
                  hierarchy="secondary-gray"
                  onPress={() =>
                    setCursors((value) => [...value, data.next_cursor ?? ""])
                  }
                  size="sm"
                >
                  {tl.next}
                </Button>
              </nav>
            ) : null}
          </>
        ) : null}
      </div>

      <aside>
        <FormSection description={tl.followUpsHint} title={tl.followUps}>
          {!data ? (
            <Skeleton height={14} />
          ) : data.follow_ups === null ? (
            <p className="bft-notice">{tl.followUpsUnavailable}</p>
          ) : (
            <ContextList empty={tl.noFollowUps} entries={data.follow_ups} />
          )}
        </FormSection>
        <FormSection description={tl.contextHint} title={tl.contextTitle}>
          {data ? (
            <ContextList empty={tl.noContext} entries={data.context} />
          ) : (
            <Skeleton height={14} />
          )}
        </FormSection>
      </aside>

      {open?.kind === "outcome" ? (
        <OutcomeDialog
          channel={channelOf(open, names)}
          item={open}
          onClose={() => setOpen(null)}
          org={org}
          agent={agent.id}
        />
      ) : open ? (
        <ProcessingDialog
          agent={agent.id}
          channel={channelOf(open, names)}
          item={open}
          onClose={() => setOpen(null)}
          org={org}
          texts={texts}
        />
      ) : null}
    </div>
  );
}

const channelOf = (item: BftTriageItem, names: Map<string, string>) =>
  names.get(`${item.source.connect_id}/${item.source.channel_id}`) ??
  t.channelUnavailable;

/** A Slack member id is never shown as a name. */
function speakerName(label: string | null | undefined, kind: string | null) {
  if (label && !/^@?[UW][A-Z0-9]{2,31}$/.test(label))
    return label.startsWith("@") ? label : `@${label}`;
  return (tl.actors as Record<string, string>)[kind ?? ""] ?? tl.actors.unknown;
}

/** Revealed Slack text: plain runs, member mentions and http(s) links. */
export function SlackText({ parts }: { parts: BftTriageReveal[string]["parts"] }) {
  return (
    <p className="bft-report">
      {parts.map((part, index) =>
        part.kind === "link" && part.url ? (
          <a
            className="bft-link"
            href={part.url}
            key={index}
            rel="noopener noreferrer"
            target="_blank"
          >
            {part.text}
          </a>
        ) : part.kind === "mention" ? (
          <span className="bft-mention" key={index}>
            {part.text}
          </span>
        ) : (
          <span key={index}>{part.text}</span>
        )
      )}
    </p>
  );
}

/**
 * Source messages with their sender and time. The text is shown only after
 * an explicit reveal, which the server records in the audit log first.
 */
function Messages({
  messages: list,
  texts,
  onReveal,
}: {
  messages: BftTriageMessage[];
  texts: Revealed;
  onReveal: (refs: string[]) => void;
}) {
  if (list.length === 0) return null;
  const hidden = list
    .filter((message) => !texts[message.ref])
    .map((message) => message.ref);
  return (
    <div className="bft-messages" data-section="source-messages">
      {list.map((message) => {
        const text = texts[message.ref];
        return (
          <div className="bft-message" key={message.ref}>
            <p className="bft-row-title">
              <span className="bft-plugin-name">
                {speakerName(
                  text && "speaker" in text
                    ? (text.speaker ?? message.speaker)
                    : message.speaker,
                  message.actor_kind
                )}
              </span>
              {message.at ? (
                <time className="bft-tag">{formatDateTime(message.at)}</time>
              ) : null}
            </p>
            {text && "parts" in text ? (
              <SlackText parts={text.parts} />
            ) : text && "error" in text ? (
              <p className="bft-dialog-error">{text.error}</p>
            ) : null}
            {message.files ? (
              <p className="bft-tag" data-section="source-files">
                {[
                  tl.files(message.files.total),
                  ...message.files.items.map((file) => file.name || tl.unnamedFile),
                ].join(" · ")}{" "}
                — {message.files.truncated ? tl.filesShortened : tl.filesNamesOnly}
              </p>
            ) : null}
          </div>
        );
      })}
      {hidden.length > 0 ? (
        <button
          className="bft-btn bft-btn-sm"
          onClick={() => onReveal(hidden)}
          type="button"
        >
          {tl.reveal}
        </button>
      ) : null}
    </div>
  );
}

function Decision({ item, onOpen }: { item: BftTriageItem; onOpen: () => void }) {
  if (item.kind === "processing") {
    return (
      <button className="bft-plugin-row bft-decision" onClick={onOpen} type="button">
        <span className="bft-status" data-tone={processingTone(item)}>
          {processingLabel(item)}
        </span>
        <span className="bft-plugin-description">{processingDescription(item)}</span>
      </button>
    );
  }
  const effects = effectSummary(item);
  return (
    <button
      aria-label={tl.details}
      className="bft-plugin-row bft-decision"
      onClick={onOpen}
      type="button"
    >
      <span className="bft-row-title">
        <span className="bft-tag">{tl.agentDecision}</span>
        <span className="bft-status" data-tone={outcomeTone(item)}>
          {outcomeLabel(item)}
        </span>
        {(item.updated_at ?? item.at) ? (
          <time className="bft-tag">{formatDateTime(item.updated_at ?? item.at)}</time>
        ) : null}
      </span>
      <span className="bft-decision-body" data-role="decision-summary">
        {outcomeBody(item)}
      </span>
      <span className="bft-plugin-description">
        {[t.citedSources(item.evidence.total_sources ?? 0), effects]
          .filter(Boolean)
          .join(" · ")}
      </span>
    </button>
  );
}

function ContextList({
  entries,
  empty,
}: {
  entries: BftTriageContext[];
  empty: string;
}) {
  return entries.length === 0 ? (
    <p className="bft-quiet bft-quiet-inline">{empty}</p>
  ) : (
    <ul className="bft-list">
      {entries.map((entry, index) => (
        <li className="bft-setting-row" key={entry.id ?? index}>
          <span className="bft-setting-row-main">
            <span className="bft-row-title">
              <span className="bft-status" data-tone={contextTone(entry)}>
                {contextKindLabel(entry)}
              </span>
              <span className="bft-tag">{contextStateLabel(entry)}</span>
            </span>
            <span className="bft-plugin-name">{entry.subject}</span>
            <span>{entry.value}</span>
            {entry.basis ? (
              <span className="bft-setting-row-sub">{entry.basis}</span>
            ) : null}
            <span className="bft-setting-row-sub">
              {[
                evidenceText(entry),
                entry.next_check_at_ms
                  ? tl.recheckAfter(formatDateTime(entry.next_check_at_ms))
                  : "",
              ]
                .filter(Boolean)
                .join(" · ")}
            </span>
          </span>
        </li>
      ))}
    </ul>
  );
}

function Facts({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="bft-plugin-facts">
      {rows.map(([label, value]) => (
        <div key={label} style={{ display: "contents" }}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function OutcomeDialog({
  org,
  agent,
  item,
  channel,
  onClose,
}: {
  org: string;
  agent: string;
  item: BftTriageOutcome;
  channel: string;
  onClose: () => void;
}) {
  const evidence = (key: string) => item.evidence[key] ?? 0;
  const contextEffect =
    (item.context.candidates ?? 0) > 0
      ? tl.contextEffect(item.context.active ?? 0, item.context.proposed ?? 0)
      : undefined;
  const settled = outcomeSettled(item);
  const elapsed =
    item.at !== null && item.updated_at !== null && item.updated_at >= item.at
      ? durationText(item.updated_at - item.at)
      : undefined;

  return (
    <DetailDialog description={channel} onClose={onClose} title={tl.batchDetails}>
      <section data-section="decision">
        <h3 className="bft-field-label">
          <span className="bft-status" data-tone={outcomeTone(item)}>
            {outcomeLabel(item)}
          </span>
        </h3>
        <p className="bft-report">{outcomeBody(item)}</p>
      </section>
      <section data-section="source">
        <h3 className="bft-field-label">{tl.sourceTitle}</h3>
        <Facts
          rows={[
            [tl.channel, channel],
            ...(item.source.thread_ts
              ? [
                  [
                    tl.thread,
                    tl.threadStarted(formatDateTime(slackMs(item.source.thread_ts))),
                  ] as [string, string],
                ]
              : []),
            [tl.trigger, tl.triggerValue],
            [
              tl.observed,
              item.source.message_count === null
                ? tl.messageCountUnavailable
                : tl.messagesInEvaluation(item.source.message_count),
            ],
            ...(item.source.latest_activity_at_ms
              ? [
                  [
                    tl.latestActivity,
                    formatDateTime(item.source.latest_activity_at_ms),
                  ] as [string, string],
                ]
              : []),
          ]}
        />
      </section>
      <section data-section="evidence">
        <h3 className="bft-field-label">{tl.evidenceTitle}</h3>
        <Facts
          rows={[
            [tl.citedSourcesLabel, tl.verifiedSources(evidence("total_sources"))],
            ...(
              [
                ["communication_sources", tl.evidence.communication],
                ["companion_reaction_sources", tl.evidence.companion],
                ["context_sources", tl.evidence.context],
                ["delegation_sources", tl.evidence.delegation],
              ] as const
            )
              .filter(([key]) => evidence(key) > 0)
              .map(([key, label]): [string, string] => [
                label,
                t.citedSources(evidence(key)),
              ]),
          ]}
        />
      </section>
      <section data-section="context">
        <h3 className="bft-field-label">{tl.relatedContext}</h3>
        <ContextList empty={tl.noRelatedContext} entries={item.related_context} />
      </section>
      {companionLabel(item) || contextEffect || item.delegations.length > 0 ? (
        <section data-section="effects">
          <h3 className="bft-field-label">{tl.effectsTitle}</h3>
          {[companionLabel(item), contextEffect].filter(Boolean).map((line) => (
            <p className="bft-dialog-note" key={line}>
              {line}
            </p>
          ))}
          {item.delegations.map((delegation, position) => (
            <Delegation
              agent={agent}
              delegation={delegation}
              key={position}
              obligation={item.obligation_id}
              org={org}
            />
          ))}
        </section>
      ) : null}
      <section data-section="lifecycle">
        <h3 className="bft-field-label">{tl.lifecycle}</h3>
        <Facts
          rows={[
            [tl.decisionRecorded, item.at ? formatDateTime(item.at) : "—"],
            [
              settled ? tl.effectSettled : tl.inProgress,
              item.updated_at ? formatDateTime(item.updated_at) : "—",
            ],
            [
              tl.attempts(item.attempts ?? 0),
              elapsed ? (settled ? tl.total(elapsed) : tl.elapsed(elapsed)) : "—",
            ],
          ]}
        />
      </section>
    </DetailDialog>
  );
}

/**
 * One delegation of an outcome. Its Task is read only on request, so opening
 * a detail with delegations costs no Task lookups.
 */
function Delegation({
  org,
  agent,
  obligation,
  delegation,
}: {
  org: string;
  agent: string;
  obligation: string | null;
  delegation: BftTriageOutcome["delegations"][number];
}) {
  const api = useApi();
  // 0 until the user asks for the Task; each click reads it again.
  const [reload, setReload] = useState(0);
  const index = delegation.index;
  const lookup = obligation && (index === 0 || index === 1);
  const [task] = useResource(
    `triage-delegation:${org}:${agent}:${obligation}:${index}:${reload}`,
    () =>
      lookup && reload > 0
        ? api.triageDelegation(org, agent, obligation, index)
        : Promise.resolve(null)
  );
  const data = task.state === "ready" ? task.data : null;
  const preview = data?.preview;

  return (
    <div className="bft-details" data-delegation-index={index}>
      <div className="bft-details-body">
        <p className="bft-row-title">
          <span className="bft-plugin-name">{delegationLabel(delegation)}</span>
          {data?.href ? (
            <a className="bft-link" href={data.href}>
              {tl.openTask}
            </a>
          ) : null}
          {lookup ? (
            <button
              className="bft-btn bft-btn-sm"
              disabled={task.state === "loading"}
              onClick={() => setReload((value) => value + 1)}
              type="button"
            >
              {reload > 0 ? tl.refreshTask : tl.loadTask}
            </button>
          ) : null}
        </p>
        {task.state === "error" ? (
          <p className="bft-notice">{writeErrorMessage(task.error)}</p>
        ) : data?.state === "not_created" ? (
          <p className="bft-dialog-note">{tl.taskNotCreated}</p>
        ) : data?.state === "unavailable" ? (
          <p className="bft-dialog-note">{tl.taskUnavailable}</p>
        ) : data && !preview ? (
          <p className="bft-notice">{tl.taskContentUnavailable}</p>
        ) : preview ? (
          <>
            <p className="bft-row-title">
              <span className="bft-plugin-name">{preview.title}</span>
              <span className="bft-tag" data-role="task-status">
                {(tl.taskStatuses as Record<string, string>)[preview.status ?? ""] ??
                  preview.status ??
                  t.statusUnavailable}
              </span>
            </p>
            {preview.status === "ready_for_review" ? (
              <p className="bft-dialog-note">{tl.awaitingReview}</p>
            ) : null}
            {preview.delivery_error ? (
              <p className="bft-notice">{tl.deliveryUnconfirmed}</p>
            ) : null}
            {preview.participation ? (
              <p className="bft-dialog-note" data-role="participation-result">
                {tl.workerDecision(participation(preview.participation))}
              </p>
            ) : null}
            <p className="bft-form-section-note">{tl.taskActivity}</p>
            {preview.messages.length === 0 ? (
              <p className="bft-dialog-note">{tl.noTaskMessages}</p>
            ) : (
              preview.messages.map((message, position) => (
                <div
                  className="bft-message"
                  data-task-message={message.id}
                  key={message.id ?? position}
                >
                  <p className="bft-row-title">
                    <span className="bft-plugin-name">
                      {message.actor ?? tl.worker}
                    </span>
                    {message.at ? (
                      <time className="bft-tag">{formatDateTime(message.at)}</time>
                    ) : null}
                  </p>
                  <p className="bft-report">{message.text}</p>
                </div>
              ))
            )}
          </>
        ) : null}
      </div>
    </div>
  );
}

function participation(result: { kind: string | null; reason_code: string | null }) {
  const p = tl.participation;
  if (result.kind === "silence")
    return (
      (p.silence as Record<string, string>)[result.reason_code ?? ""] ??
      p.silenceUnclassified
    );
  return result.kind === "reply"
    ? tl.reply
    : result.kind === "reaction"
      ? tl.reaction
      : p.silenceUnclassified;
}

function ProcessingDialog({
  org,
  agent,
  item,
  channel,
  texts,
  onClose,
}: {
  org: string;
  agent: string;
  item: Extract<BftTriageItem, { kind: "processing" }>;
  channel: string;
  texts: Revealed;
  onClose: () => void;
}) {
  const api = useApi();
  const [detail] = useResource(
    `triage-processing:${org}:${agent}:${item.id}`,
    (signal) => api.triageProcessing(org, agent, item.id, signal)
  );
  const data = detail.state === "ready" ? detail.data : undefined;
  const shown = data ? { ...item, ...data } : item;
  const text = texts[item.id];
  const milestones = (
    [
      ["received_at_ms", tl.milestones.received],
      ["queued_at_ms", tl.milestones.queued],
      ["sealed_at_ms", tl.milestones.sealed],
      ["evaluation_started_at_ms", tl.milestones.started],
      ["settled_at_ms", tl.milestones.settled],
    ] as const
  ).flatMap(([key, label]) => {
    const at = data?.milestones[key];
    return typeof at === "number"
      ? [[label, formatDateTime(at)] as [string, string]]
      : [];
  });
  const first = data?.milestones.received_at_ms;
  const last = data?.milestones.settled_at_ms;
  const source = data?.source ?? {};
  const evaluator = data?.evaluator;

  return (
    <DetailDialog description={channel} onClose={onClose} title={tl.batchDetails}>
      {text && "parts" in text ? <SlackText parts={text.parts} /> : null}
      <section>
        <h3 className="bft-field-label">
          <span className="bft-status" data-tone={processingTone(shown)}>
            {processingLabel(shown)}
          </span>
        </h3>
        <p className="bft-dialog-note">{processingDescription(shown)}</p>
      </section>
      {detail.state === "loading" ? (
        <Skeleton height={14} />
      ) : detail.state === "error" ? (
        <p className="bft-notice">{writeErrorMessage(detail.error)}</p>
      ) : data ? (
        <Facts
          rows={[
            [
              tl.sourceTitle,
              [
                (tl.addressing as Record<string, string>)[
                  source.addressing_kind ?? ""
                ] ?? tl.addressing.unknown,
                (tl.sourceModes as Record<string, string>)[source.source_mode ?? ""] ??
                  tl.sourceModes.unknown,
                (tl.triggers as Record<string, string>)[source.trigger_kind ?? ""],
              ]
                .filter(Boolean)
                .join(" · "),
            ],
            ...milestones,
            ...(typeof first === "number" && typeof last === "number" && last >= first
              ? [[tl.totalLabel, durationText(last - first)] as [string, string]]
              : []),
            [
              tl.evaluator,
              evaluator
                ? [
                    [evaluator.model, evaluator.provider].filter(Boolean).join(" · "),
                    tl.modelRequests(evaluator.request_count ?? 0),
                    evaluator.tool_names?.length
                      ? tl.tools(evaluator.tool_names.join(", "))
                      : "",
                  ]
                    .filter(Boolean)
                    .join(" · ")
                : shown.terminal_status === "failed"
                  ? tl.noEvaluator
                  : "—",
            ],
            [
              tl.processingEvidence,
              [
                (tl.decisionReasons as Record<string, string>)[
                  data.decision_reason ?? ""
                ],
                processingLabel(shown),
              ]
                .filter(Boolean)
                .join(" · "),
            ],
          ]}
        />
      ) : null}
    </DetailDialog>
  );
}

function Heatmap({
  view,
  nav,
  expanded,
  truncated,
  onRange,
  onExpand,
  onSelect,
}: {
  view: NonNullable<ReturnType<typeof heatmapView>>;
  truncated: boolean;
  nav: BftTriageNav;
  expanded: boolean;
  onRange: (range: HeatmapRange) => void;
  onExpand: () => void;
  onSelect: (channel: string, before: number) => void;
}) {
  const h = tl.heatmap;
  const summary = (cell: (typeof view.rows)[number]["cells"][number]) =>
    [
      h.outcomes(cell.total),
      `${tl.reply} ${cell.reply}`,
      `${tl.reaction} ${cell.reaction}`,
      `${tl.silent} ${cell.silence}`,
    ].join(" · ");
  return (
    <section aria-label={h.title} className="bft-heatmap" id="triage-activity-heatmap">
      <div className="bft-row-title">
        <span className="bft-field-label">{h.title}</span>
        {(["24h", "7d"] as const).map((range) => (
          <button
            aria-pressed={view.range === range}
            className="bft-btn bft-btn-sm"
            data-role="heatmap-range"
            key={range}
            onClick={() => onRange(range)}
            type="button"
          >
            {h.ranges[range]}
          </button>
        ))}
        <span className="bft-heatmap-legend">
          <span data-level="2" />
          {tl.silent}
          <span data-acted="true" />
          {h.acted}
        </span>
      </div>
      {view.rows.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{h.empty}</p>
      ) : (
        <div
          className="bft-heatmap-grid"
          style={{ "--bft-heatmap-columns": view.columns } as CSSProperties}
        >
          <span />
          <span />
          <span className="bft-heatmap-num">{h.total}</span>
          <span className="bft-heatmap-num">{h.replied}</span>
          <span className="bft-heatmap-num">{h.silentShare}</span>
          {view.rows.map((row) => (
            <div key={row.channel} style={{ display: "contents" }}>
              <span
                className="bft-truncate"
                data-role="heatmap-channel"
                title={row.label}
              >
                {row.label}
              </span>
              <span className="bft-heatmap-cells">
                {row.cells.map((cell) =>
                  row.filterable && cell.total > 0 ? (
                    <button
                      aria-label={`${row.label} ${formatDateTime(cell.start)} · ${summary(cell)}`}
                      aria-pressed={
                        nav.channel === row.channel && nav.before === cell.end
                      }
                      data-acted={cell.acted}
                      data-level={cell.level}
                      key={cell.start}
                      onClick={() => onSelect(row.channel, cell.end)}
                      title={`${formatDateTime(cell.start)} · ${summary(cell)}`}
                      type="button"
                    />
                  ) : (
                    <span
                      data-acted={cell.acted}
                      data-level={cell.level}
                      key={cell.start}
                      {...(cell.total > 0
                        ? { title: `${formatDateTime(cell.start)} · ${summary(cell)}` }
                        : {})}
                    />
                  )
                )}
              </span>
              <span className="bft-heatmap-num" data-role="heatmap-total">
                {row.total}
              </span>
              <span className="bft-heatmap-num" data-role="heatmap-replied">
                {row.replied}
              </span>
              <span className="bft-heatmap-num" data-role="heatmap-silent">
                {row.silentPercent}%
              </span>
            </div>
          ))}
          <span />
          <span
            className="bft-heatmap-ticks"
            style={{ "--bft-heatmap-ticks": view.ticks.length } as CSSProperties}
          >
            {view.ticks.map((tick) => (
              <time key={tick}>{formatDateTime(tick)}</time>
            ))}
          </span>
        </div>
      )}
      {view.hidden > 0 || view.canCollapse || truncated ? (
        <p className="bft-row-title">
          {view.hidden > 0 || view.canCollapse ? (
            <button className="bft-btn bft-btn-sm" onClick={onExpand} type="button">
              {expanded && view.canCollapse ? h.fewer : h.more(view.hidden)}
            </button>
          ) : null}
          {truncated ? <span className="bft-tag">{h.truncated}</span> : null}
        </p>
      ) : null}
    </section>
  );
}
