import type { TrajectoryStep } from "@evalens/core/message";
import {
  AlertTriangle,
  Check,
  ChevronDown,
  Clipboard,
  Code2,
  Search,
  Wrench,
} from "lucide-react";
import { useRef, useState, type CSSProperties, type ReactNode } from "react";
import { JSONTree } from "react-json-tree";
import ReactMarkdown from "react-markdown";
import rehypeExternalLinks from "rehype-external-links";
import remarkGfm from "remark-gfm";
import { formatDateTitle, formatDuration, formatTime } from "../lib/format";
import { useLocale } from "../i18n/locale";
import { m } from "../paraglide/messages.js";
import {
  eventMatches,
  hasTimestampRegression,
  mergeTrajectoryEvents,
  type ParsedTrajectories,
  type ToolWarning,
  type TrajectoryEvent,
} from "./model";

export type TrajectoryMode = "grouped" | "merged";

export type TrajectoryViewState = {
  mode: TrajectoryMode;
  lanes: string[];
  query: string;
  matchesOnly: boolean;
  raw: boolean;
};

type Props = {
  parsed: ParsedTrajectories;
  rawValue: unknown;
  state: TrajectoryViewState;
  onStateChange: (state: TrajectoryViewState) => void;
};

export function TrajectoryViewer({ parsed, rawValue, state, onStateChange }: Props) {
  useLocale();
  const laneIds = parsed.trajectories.map(({ id }) => id);
  const selectedLanes = state.lanes.filter((id) => laneIds.includes(id)).slice(0, 4);
  const effectiveLanes = selectedLanes.length
    ? selectedLanes
    : laneIds.slice(0, Math.min(4, laneIds.length));
  const update = (patch: Partial<TrajectoryViewState>) =>
    onStateChange({ ...state, lanes: effectiveLanes, ...patch });

  if (state.raw) {
    return (
      <section className="trajectory-raw-view">
        <button className="secondary-button" onClick={() => update({ raw: false })}>
          <Code2 size={14} /> {m.trajectory_structured()}
        </button>
        <pre className="data-preview">{JSON.stringify(rawValue, null, 2)}</pre>
      </section>
    );
  }

  return (
    <>
      <section className="trajectory-controls" aria-label={m.trajectory_mode_label()}>
        <div className="segmented-control">
          <button
            className={state.mode === "grouped" ? "active" : ""}
            onClick={() => update({ mode: "grouped" })}
          >
            {m.trajectory_grouped()}
          </button>
          <button
            className={state.mode === "merged" ? "active" : ""}
            onClick={() => update({ mode: "merged" })}
          >
            {m.trajectory_merged()}
          </button>
        </div>
        <label className="trajectory-search">
          <Search size={15} />
          <input
            aria-label={m.trajectory_search()}
            placeholder={m.trajectory_search()}
            value={state.query}
            onChange={(event) => update({ query: event.target.value })}
          />
        </label>
        <label className="toggle-field">
          <input
            type="checkbox"
            checked={state.matchesOnly}
            onChange={(event) => update({ matchesOnly: event.target.checked })}
          />
          {m.trajectory_matches_only()}
        </label>
        <button className="secondary-button" onClick={() => update({ raw: true })}>
          <Code2 size={14} /> {m.trajectory_raw()}
        </button>
      </section>

      {state.mode === "merged" && (
        <LaneSelector
          parsed={parsed}
          query={state.query}
          selected={effectiveLanes}
          onChange={(lanes) => update({ lanes })}
        />
      )}

      {state.mode === "grouped" ? (
        <GroupedView
          parsed={parsed}
          query={state.query}
          matchesOnly={state.matchesOnly}
        />
      ) : (
        <MergedView
          parsed={parsed}
          lanes={effectiveLanes}
          query={state.query}
          matchesOnly={state.matchesOnly}
        />
      )}
    </>
  );
}

function LaneSelector({
  parsed,
  query,
  selected,
  onChange,
}: {
  parsed: ParsedTrajectories;
  query: string;
  selected: string[];
  onChange: (lanes: string[]) => void;
}) {
  return (
    <section className="lane-selector">
      <div>
        <b>{m.trajectory_lanes()}</b>
        <span>{m.trajectory_lane_limit()}</span>
      </div>
      {parsed.trajectories.map((trajectory) => {
        const checked = selected.includes(trajectory.id);
        const count = (parsed.eventsByTrajectory.get(trajectory.id) ?? []).filter(
          (event) => eventMatches(event, query)
        ).length;
        return (
          <label key={trajectory.id}>
            <input
              type="checkbox"
              checked={checked}
              disabled={!checked && selected.length >= 4}
              onChange={() =>
                onChange(
                  checked
                    ? selected.filter((id) => id !== trajectory.id)
                    : [...selected, trajectory.id]
                )
              }
            />
            <span className="mono">{trajectory.id}</span>
            <small>{m.trajectory_lane_matches({ count })}</small>
          </label>
        );
      })}
    </section>
  );
}

function GroupedView({
  parsed,
  query,
  matchesOnly,
}: {
  parsed: ParsedTrajectories;
  query: string;
  matchesOnly: boolean;
}) {
  return (
    <div className="trajectory-groups">
      {parsed.trajectories.map((trajectory) => {
        const events = parsed.eventsByTrajectory.get(trajectory.id) ?? [];
        const visible = matchesOnly
          ? events.filter((event) => eventMatches(event, query))
          : events;
        return (
          <section className="trajectory-group" key={trajectory.id}>
            <header>
              <h2 className="mono">{trajectory.id}</h2>
              <span>
                {m.trajectory_lane_matches({
                  count: events.filter((event) => eventMatches(event, query)).length,
                })}
              </span>
            </header>
            {hasTimestampRegression(events) && (
              <p className="trajectory-warning">
                <AlertTriangle size={14} /> {m.trajectory_timestamp_warning()}
              </p>
            )}
            <EventList
              events={visible}
              allEvents={events}
              query={query}
              empty={events.length === 0}
            />
          </section>
        );
      })}
    </div>
  );
}

function MergedView({
  parsed,
  lanes,
  query,
  matchesOnly,
}: {
  parsed: ParsedTrajectories;
  lanes: string[];
  query: string;
  matchesOnly: boolean;
}) {
  const headerViewport = useRef<HTMLDivElement>(null);
  const events = mergeTrajectoryEvents(parsed.eventsByTrajectory, lanes);
  const previousByKey = previousEvents(events);
  const visible = matchesOnly
    ? events.filter((event) => eventMatches(event, query))
    : events;
  return (
    <div className="merged-shell">
      <div className="merged-header-viewport" ref={headerViewport}>
        <div
          className="merged-header"
          style={{ "--lane-count": lanes.length } as CSSProperties}
        >
          <b>{m.common_created()}</b>
          {lanes.map((lane) => (
            <span className="mono" key={lane} title={lane}>
              {lane}
              <small>
                {m.trajectory_lane_matches({
                  count: (parsed.eventsByTrajectory.get(lane) ?? []).filter((event) =>
                    eventMatches(event, query)
                  ).length,
                })}
              </small>
            </span>
          ))}
        </div>
      </div>
      <div
        className="merged-scroll"
        onScroll={(event) => {
          if (headerViewport.current) {
            headerViewport.current.scrollLeft = event.currentTarget.scrollLeft;
          }
        }}
      >
        <div
          className="merged-timeline"
          style={{ "--lane-count": lanes.length } as CSSProperties}
        >
          {visible.length === 0 ? (
            <p className="empty-inline">{m.trajectory_no_matches()}</p>
          ) : (
            visible.map((event) => (
              <div className="merged-row" key={event.key}>
                <TimeMeta event={event} previous={previousByKey.get(event.key)} />
                {lanes.map((lane) => (
                  <div className="merged-lane" data-lane={lane} key={lane}>
                    {event.trajectoryId === lane && (
                      <EventCard event={event} query={query} />
                    )}
                  </div>
                ))}
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

function EventList({
  events,
  allEvents,
  query,
  empty,
}: {
  events: readonly TrajectoryEvent[];
  allEvents: readonly TrajectoryEvent[];
  query: string;
  empty: boolean;
}) {
  if (!events.length)
    return (
      <p className="empty-inline">
        {empty ? m.trajectory_empty() : m.trajectory_no_matches()}
      </p>
    );
  const previousByKey = previousEvents(allEvents);
  return (
    <ol className="grouped-events">
      {events.map((event) => (
        <li key={event.key}>
          <TimeMeta event={event} previous={previousByKey.get(event.key)} />
          <EventCard event={event} query={query} />
        </li>
      ))}
    </ol>
  );
}

function TimeMeta({
  event,
  previous,
}: {
  event: TrajectoryEvent;
  previous?: TrajectoryEvent;
}) {
  const delta = previous
    ? event.timestamp.getTime() - previous.timestamp.getTime()
    : undefined;
  return (
    <div className="event-time">
      <CopyButton
        label={m.trajectory_copy_timestamp()}
        value={event.timestamp.toISOString()}
      >
        <time title={formatDateTitle(event.timestamp.toISOString())}>
          {formatTime(event.timestamp)}
        </time>
      </CopyButton>
      <span>
        {delta === undefined
          ? "—"
          : m.trajectory_relative({ duration: formatDuration(delta) })}
      </span>
    </div>
  );
}

function EventCard({ event, query }: { event: TrajectoryEvent; query: string }) {
  const [raw, setRaw] = useState(false);
  const matched = eventMatches(event, query);
  const step = event.step;
  const kind =
    step.type === "tool_call" || step.type === "tool_result" ? "tool" : step.type;
  return (
    <article
      className={`trajectory-event event-${kind} ${matched ? "matched" : "unmatched"} ${query && matched ? "search-hit" : ""}`}
      data-step-type={step.type}
    >
      <header>
        <span className="event-kind">
          {kind === "tool" && <Wrench size={14} />}
          {stepLabel(step)}
        </span>
        <span className="event-header-meta">
          {step.type === "assistant" && step.model && (
            <span className="trajectory-model">
              {m.trajectory_model({ model: step.model })}
            </span>
          )}
          <span>{m.trajectory_step({ index: event.stepIndex + 1 })}</span>
          <button
            className="text-icon-button"
            title={raw ? m.trajectory_hide_raw() : m.trajectory_view_raw()}
            aria-label={raw ? m.trajectory_hide_raw() : m.trajectory_view_raw()}
            onClick={() => setRaw((value) => !value)}
          >
            <Code2 size={13} />
          </button>
        </span>
      </header>
      {!matched && query ? (
        <p className="event-collapsed">{m.trajectory_unmatched()}</p>
      ) : raw ? (
        <RawEvent event={event} />
      ) : (
        <EventBody event={event} forceExpand={Boolean(query && matched)} />
      )}
      <Warnings warnings={event.warnings} />
    </article>
  );
}

function EventBody({
  event,
  forceExpand,
}: {
  event: TrajectoryEvent;
  forceExpand: boolean;
}) {
  const step = event.step;
  if (step.type === "system") {
    return (
      <details open={forceExpand} className="system-message">
        <summary>
          <ChevronDown size={13} /> {step.content.split("\n", 1)[0]} ·{" "}
          {step.content.length}
        </summary>
        <p>{step.content}</p>
      </details>
    );
  }
  if (step.type === "user" || step.type === "assistant") {
    return <Markdown content={step.content ?? ""} />;
  }
  if (step.type === "tool_result") {
    return (
      <JsonSection
        label={m.trajectory_output()}
        value={step.output}
        forceExpand={forceExpand}
      />
    );
  }
  return (
    <div className="tool-execution">
      <CopyButton label={m.trajectory_copy_call_id()} value={step.id}>
        <span className="call-id mono" title={step.id}>
          {step.id}
        </span>
      </CopyButton>
      <JsonSection
        label={m.trajectory_arguments()}
        value={step.arguments}
        forceExpand={forceExpand}
      />
      {event.result ? (
        <>
          <div className="tool-result-meta">
            <span>
              {m.trajectory_result_at({ time: formatTime(event.result.timestamp) })}
            </span>
            {event.durationMs !== undefined && (
              <span>
                {m.trajectory_duration({ duration: formatDuration(event.durationMs) })}
                {event.durationDerived && ` (${m.trajectory_duration_derived()})`}
              </span>
            )}
          </div>
          <JsonSection
            label={m.trajectory_output()}
            value={event.result.output}
            forceExpand={forceExpand}
          />
        </>
      ) : (
        <p className="trajectory-warning">{m.trajectory_pending()}</p>
      )}
    </div>
  );
}

function Markdown({ content }: { content: string }) {
  return (
    <div className="markdown-content">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[
          [rehypeExternalLinks, { target: "_blank", rel: ["noopener", "noreferrer"] }],
        ]}
        components={{
          pre({ children }) {
            const text = reactText(children);
            return (
              <div className="code-block">
                <CopyButton label={m.trajectory_copy_code()} value={text} />
                <pre>{children}</pre>
              </div>
            );
          },
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}

function JsonSection({
  label,
  value,
  forceExpand,
}: {
  label: string;
  value: unknown;
  forceExpand: boolean;
}) {
  const small = jsonComplexity(value) <= 8;
  return (
    <section className="json-section">
      <header>
        <b>{label}</b>
        <CopyButton
          label={m.trajectory_copy_json({ label })}
          value={JSON.stringify(value, null, 2)}
        />
      </header>
      <JSONTree
        data={value as object}
        hideRoot
        shouldExpandNodeInitially={() => forceExpand || small}
        theme={jsonTheme}
        invertTheme={false}
        valueRenderer={(display, raw) =>
          typeof raw === "string" && raw.length > 180 ? (
            <ExpandableString value={raw} />
          ) : (
            (display as ReactNode)
          )
        }
      />
    </section>
  );
}

function ExpandableString({ value }: { value: string }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <span>
      {JSON.stringify(expanded ? value : `${value.slice(0, 180)}…`)}{" "}
      <button
        className="inline-action"
        onClick={() => setExpanded((current) => !current)}
      >
        {expanded ? m.trajectory_collapse_string() : m.trajectory_expand_string()}
      </button>
    </span>
  );
}

function RawEvent({ event }: { event: TrajectoryEvent }) {
  return (
    <div className="raw-event">
      <JsonSection label={m.trajectory_raw_call()} value={event.step} forceExpand />
      {event.result && (
        <JsonSection
          label={m.trajectory_raw_result()}
          value={event.result}
          forceExpand
        />
      )}
    </div>
  );
}

function Warnings({ warnings }: { warnings: ToolWarning[] }) {
  if (!warnings.length) return null;
  return (
    <ul className="event-warnings">
      {warnings.map((warning) => (
        <li key={warning}>
          <AlertTriangle size={13} /> {warningLabel(warning)}
        </li>
      ))}
    </ul>
  );
}

function CopyButton({
  label,
  value,
  children,
}: {
  label: string;
  value: string;
  children?: ReactNode;
}) {
  const [copied, setCopied] = useState(false);
  return (
    <span className="copy-control">
      {children}
      <button
        className="text-icon-button"
        title={copied ? m.trajectory_copied() : label}
        aria-label={copied ? m.trajectory_copied() : label}
        onClick={() => {
          void navigator.clipboard.writeText(value).then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1200);
          });
        }}
      >
        {copied ? <Check size={13} /> : <Clipboard size={13} />}
      </button>
    </span>
  );
}

function stepLabel(step: TrajectoryStep): string {
  switch (step.type) {
    case "system":
      return m.trajectory_system();
    case "user":
      return m.trajectory_user();
    case "assistant":
      return m.trajectory_assistant();
    case "tool_call":
      return `${m.trajectory_tool()}: ${step.name}`;
    case "tool_result":
      return `${m.trajectory_tool_result()}: ${step.name}`;
  }
}

function warningLabel(warning: ToolWarning): string {
  switch (warning) {
    case "pending":
      return m.trajectory_pending();
    case "orphan-result":
      return m.trajectory_warning_orphan();
    case "duplicate-result":
      return m.trajectory_warning_duplicate();
    case "name-mismatch":
      return m.trajectory_warning_name();
  }
}

function jsonComplexity(value: unknown): number {
  if (!value || typeof value !== "object") return 1;
  if (Array.isArray(value))
    return value.length + value.reduce((sum, entry) => sum + jsonComplexity(entry), 0);
  return (
    Object.values(value).length +
    Object.values(value).reduce((sum, entry) => sum + jsonComplexity(entry), 0)
  );
}

function reactText(node: ReactNode): string {
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(reactText).join("");
  if (node && typeof node === "object" && "props" in node) {
    return reactText((node as { props: { children?: ReactNode } }).props.children);
  }
  return "";
}

function previousEvents(events: readonly TrajectoryEvent[]) {
  return new Map(events.map((event, index) => [event.key, events[index - 1]] as const));
}

const jsonTheme = {
  scheme: "evalens",
  author: "evalens",
  base00: "transparent",
  base01: "#eef1f2",
  base02: "#dfe3e6",
  base03: "#66717a",
  base04: "#66717a",
  base05: "#30383e",
  base06: "#202428",
  base07: "#15191c",
  base08: "#a33b32",
  base09: "#95620e",
  base0A: "#95620e",
  base0B: "#24724c",
  base0C: "#126e75",
  base0D: "#246ab3",
  base0E: "#6c4aa0",
  base0F: "#8a4b2a",
};
