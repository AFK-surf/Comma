import { Dropdown, InputField } from "@comma/ui";
import { useState } from "react";
import type { BftTriageAgent, BftTriageKnowledge, BftTriageReveal } from "./api";
import { writeErrorMessage } from "./dialogs";
import { formatDateTime, formatInteger } from "./format";
import { DetailDialog } from "./MeetingsPage";
import { messages } from "./messages";
import { MetricCards } from "./MetricCards";
import { SlackText } from "./TriageTimeline";
import { useApi, useResource } from "./resource";
import { FormSection } from "./settingsForm";
import { Skeleton } from "./states";
import {
  evidenceText,
  knowledgeCounts,
  knowledgeRows,
  matches,
  type KnowledgeKind,
} from "./triageModel";

const t = messages.triage;
const tk = messages.triage.knowledge;
const kinds = ["all", "person", "project", "decision", "context"] as const;
type Assertion = BftTriageKnowledge["assertions"][number];

/**
 * People, projects, decisions and context the selected Agent's project keeps,
 * each with its source, and the sourced assertions by day.
 */
export function TriageKnowledge({
  org,
  agent,
}: {
  org: string;
  agent: BftTriageAgent;
}) {
  const api = useApi();
  const [knowledge] = useResource(`triage-knowledge:${org}:${agent.id}`, (signal) =>
    api.triageKnowledge(org, agent.id, signal)
  );
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<(typeof kinds)[number]>("all");
  const [open, setOpen] = useState<Assertion | null>(null);

  if (knowledge.state === "loading") {
    return (
      <>
        <MetricCards cards={undefined} />
        <Skeleton height={14} />
      </>
    );
  }
  if (knowledge.state === "error")
    return <p className="bft-notice">{writeErrorMessage(knowledge.error)}</p>;

  const data = knowledge.data;
  const counts = knowledgeCounts(data);
  const ofKind = (value: string) => kind === "all" || value === kind;
  const rows = knowledgeRows(data).filter(
    (row) =>
      ofKind(row.kind) &&
      matches(query, row.name, row.summary, ...row.assertions.map((a) => a.content))
  );
  const retained = data.retained.filter(
    (row) => ofKind(row.kind) && matches(query, row.name, row.content)
  );
  const imported = data.imported.items.filter(
    (row) => ofKind(row.kind) && matches(query, row.name, ...row.aliases)
  );
  const assertions = data.assertions.filter((assertion) =>
    matches(query, assertion.content)
  );
  const usageUnavailable = data.usage === "unavailable";

  return (
    <>
      <MetricCards
        cards={(["person", "project", "decision", "context"] as const).map((key) => ({
          label: tk.kinds[key],
          value: formatInteger(counts[key]),
          detail: tk.countDetails[key],
        }))}
      />
      {data.status === "unavailable" ? (
        <p className="bft-notice">{tk.unavailable}</p>
      ) : null}
      {data.status === "ok" && usageUnavailable ? (
        <p className="bft-notice">{tk.usageUnavailable}</p>
      ) : null}
      {data.status === "ok" && !usageUnavailable && !data.usage_complete ? (
        <p className="bft-notice">{tk.usagePartial}</p>
      ) : null}
      {data.status === "ok" && data.retained_status === "unavailable" ? (
        <p className="bft-notice">{tk.retainedUnavailable}</p>
      ) : null}
      {data.incomplete ? <p className="bft-notice">{tk.incomplete}</p> : null}
      {data.imported.status === "unavailable" ? (
        <p className="bft-notice">{tk.importedUnavailable}</p>
      ) : null}

      <div className="bft-triage-filters">
        <InputField
          aria-label={tk.search}
          fieldSize="sm"
          onChange={(event) => setQuery(event.target.value)}
          placeholder={tk.searchHint}
          type="search"
          value={query}
          wrapperClassName="bft-triage-search"
        />
        <Dropdown
          ariaLabel={tk.type}
          items={kinds.map((value) => ({ id: value, label: tk.filter[value] }))}
          onChange={(value) => setKind(value as (typeof kinds)[number])}
          size="sm"
          value={kind}
          width="content"
        />
      </div>

      <div className="bft-settings-grid">
        <div>
          {retained.length > 0 ? (
            <FormSection
              description={tk.recordedHint}
              id="triage-recorded-context-knowledge"
              title={tk.recorded}
            >
              <ul className="bft-list">
                {retained.map((row) => (
                  <li
                    className="bft-setting-row"
                    id={`triage-context-knowledge-row-${row.id}`}
                    key={row.id}
                  >
                    <span className="bft-setting-row-main">
                      <span className="bft-row-title">
                        <span className="bft-plugin-name">{row.name}</span>
                        <span className="bft-tag">{tk.kind[row.kind]}</span>
                      </span>
                      <span>{row.content}</span>
                      <span className="bft-setting-row-sub">
                        {[
                          evidenceText(row),
                          row.updated_at_ms
                            ? tk.updated(formatDateTime(row.updated_at_ms))
                            : "",
                        ]
                          .filter(Boolean)
                          .join(" · ")}
                      </span>
                    </span>
                  </li>
                ))}
              </ul>
            </FormSection>
          ) : null}
          {imported.length > 0 ? (
            <FormSection
              description={
                data.imported.grounding
                  ? tk.importedHint
                  : `${tk.importedHint} ${tk.groundingOff}`
              }
              title={tk.imported}
            >
              <ul className="bft-list">
                {imported.map((row) => (
                  <li className="bft-setting-row" key={row.id}>
                    <span className="bft-setting-row-main">
                      <span className="bft-row-title">
                        <span className="bft-plugin-name">{row.name}</span>
                        <span className="bft-tag">{tk.kind[row.kind]}</span>
                      </span>
                      {row.aliases.length ? (
                        <span>{row.aliases.join(" · ")}</span>
                      ) : null}
                      <span className="bft-setting-row-sub bft-mono-ref">
                        {row.source_refs.join(" ")}
                      </span>
                    </span>
                  </li>
                ))}
              </ul>
            </FormSection>
          ) : null}
          <FormSection title={tk.entities}>
            {rows.length === 0 && retained.length === 0 && imported.length === 0 ? (
              <div className="bft-quiet bft-quiet-inline">
                <p>{tk.noMatchTitle}</p>
                <p>{tk.noMatchBody}</p>
              </div>
            ) : (
              <ul className="bft-list">
                {rows.map((row) => (
                  <li id={`knowledge-row-${row.id}`} key={row.id}>
                    <details className="bft-entity">
                      <summary className="bft-setting-row">
                        <span className="bft-setting-row-main">
                          <span className="bft-plugin-name">{row.name}</span>
                          <span className="bft-setting-row-sub">{row.summary}</span>
                        </span>
                        <span className="bft-tag">
                          {tk.kind[row.kind as KnowledgeKind]}
                        </span>
                      </summary>
                      <div className="bft-form">
                        {row.role ? (
                          <p className="bft-dialog-note">
                            {tk.member(row.role)}{" "}
                            <span className="bft-mono-ref">{row.sourceRef}</span>
                          </p>
                        ) : null}
                        {row.assertions.map((assertion) => (
                          <p className="bft-dialog-note" key={assertion.id}>
                            {assertion.content}{" "}
                            <span className="bft-mono-ref">{assertion.source.ref}</span>
                          </p>
                        ))}
                        {row.assertions.length > 0 ? (
                          <Uses uses={row.uses} unavailable={usageUnavailable} />
                        ) : null}
                      </div>
                    </details>
                  </li>
                ))}
              </ul>
            )}
          </FormSection>
        </div>
        <FormSection description={tk.assertionsHint} title={tk.assertions}>
          {assertions.length === 0 ? (
            <div className="bft-quiet bft-quiet-inline">
              <p>{tk.noAssertionsTitle}</p>
              <p>{tk.noAssertionsBody}</p>
            </div>
          ) : (
            <ul className="bft-list">
              {assertions.map((assertion) => (
                <li key={assertion.id}>
                  <button
                    className="bft-plugin-row"
                    onClick={() => setOpen(assertion)}
                    type="button"
                  >
                    <span className="bft-row-title">
                      <span className="bft-tag">
                        {assertion.observed_at
                          ? formatDateTime(Date.parse(assertion.observed_at))
                          : ""}
                      </span>
                      <span className="bft-status" data-tone="ok">
                        {tk.assertionKinds[assertion.kind]}
                      </span>
                      {assertion.uses.length ? (
                        <span className="bft-tag">
                          {tk.used(assertion.uses.length)}
                        </span>
                      ) : null}
                    </span>
                    <span className="bft-plugin-name">{assertion.content}</span>
                    <span className="bft-plugin-description">
                      {assertion.subjects.map((subject) => subject.name).join(" · ")}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </FormSection>
      </div>
      {open ? (
        <AssertionDialog
          agent={agent.id}
          assertion={open}
          onClose={() => setOpen(null)}
          org={org}
          usageUnavailable={usageUnavailable}
        />
      ) : null}
    </>
  );
}

function Uses({
  uses,
  unavailable,
}: {
  uses: Assertion["uses"];
  unavailable: boolean;
}) {
  if (unavailable) return <p className="bft-notice">{tk.usageUnavailable}</p>;
  if (uses.length === 0) return <p className="bft-dialog-note">{tk.noUse}</p>;
  return (
    <>
      {uses.map((use) => (
        <p className="bft-dialog-note" key={use.id}>
          <span className="bft-plugin-name">{tk.usedIn(use.session_id ?? "")}</span>
          {use.excerpt ? ` ${use.excerpt}` : ""}
          {use.used_at ? (
            <span className="bft-tag"> · {formatDateTime(use.used_at * 1000)}</span>
          ) : null}
        </p>
      ))}
    </>
  );
}

/** How one assertion was formed and used; its Slack text opens only on request. */
function AssertionDialog({
  org,
  agent,
  assertion,
  usageUnavailable,
  onClose,
}: {
  org: string;
  agent: string;
  assertion: Assertion;
  usageUnavailable: boolean;
  onClose: () => void;
}) {
  const api = useApi();
  const [text, setText] = useState<BftTriageReveal[string] | { error: string }>();
  const ref = assertion.source.ref;
  const slack = assertion.source.type === "slack_receipt" && ref;

  const reveal = () => {
    if (!ref) return;
    api.revealTriageText(org, agent, [ref], null).then(
      (shown) => setText(shown[ref] ?? { error: t.timeline.messageGone }),
      (error: unknown) => setText({ error: writeErrorMessage(error) ?? "" })
    );
  };

  return (
    <DetailDialog
      description={[
        tk.assertionKinds[assertion.kind],
        assertion.observed_at ? formatDateTime(Date.parse(assertion.observed_at)) : "",
      ]
        .filter(Boolean)
        .join(" · ")}
      onClose={onClose}
      title={assertion.content}
    >
      <section>
        <h3 className="bft-field-label">{tk.steps.entered}</h3>
        <p className="bft-dialog-note">
          {slack ? tk.slackSource : tk.otherSource(assertion.source.type ?? "")}
        </p>
        {text && "parts" in text ? (
          <SlackText parts={text.parts} />
        ) : text ? (
          <p className="bft-dialog-error">{text.error}</p>
        ) : slack ? (
          <button className="bft-btn bft-btn-sm" onClick={reveal} type="button">
            {t.timeline.reveal}
          </button>
        ) : null}
        <p className="bft-mono-ref">{ref ?? "—"}</p>
      </section>
      <section>
        <h3 className="bft-field-label">{tk.steps.recorded}</h3>
        <p className="bft-dialog-note">{tk.recordedBody}</p>
      </section>
      <section>
        <h3 className="bft-field-label">{tk.steps.formed}</h3>
        <p className="bft-dialog-note">
          {assertion.subjects
            .map((subject) => `${tk.kind[subject.kind]} · ${subject.name}`)
            .join(", ")}
        </p>
      </section>
      <section>
        <h3 className="bft-field-label">{tk.steps.use}</h3>
        <Uses unavailable={usageUnavailable} uses={assertion.uses} />
      </section>
    </DetailDialog>
  );
}
