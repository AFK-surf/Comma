import { Button } from "@comma/ui/components/Button";
import type { BftDailyBrief, BftDailyBriefRun } from "./api";
import { formatCompact, formatRelative, formatTime } from "./format";
import { messages } from "./messages";
import { FormSection, useWrite } from "./settingsForm";

/*
 * The daily brief's operations: today's state and the latest runs. The
 * server sends only counts, states and dates; no brief text.
 */

const t = messages.dailyBrief;

type Tone = "ok" | "warn" | "error" | undefined;

function Chip({ tone, children }: { tone: Tone; children: string }) {
  return (
    <span className="bft-status" data-tone={tone}>
      <span className="bft-truncate">{children}</span>
    </span>
  );
}

const passTones: Record<string, Tone> = {
  completed: "ok",
  running: "warn",
  failed: "error",
};

export function Today({ today }: { today: NonNullable<BftDailyBrief["today"]> }) {
  const pass = today.team_pass;
  const next = today.next_brief_at ? formatTime(today.next_brief_at) : undefined;
  return (
    <section aria-label={t.todayTitle} className="bft-daily-brief-today">
      <h2 className="bft-field-label">{t.todayTitle}</h2>
      <div className="bft-daily-brief-chips">
        <Chip tone={pass ? passTones[pass.status] : undefined}>
          {pass ? (t.teamPassStatus[pass.status] ?? t.teamPass) : t.teamPassNone}
        </Chip>
        <Chip tone={today.sent > 0 ? "ok" : undefined}>
          {t.sentOf(today.sent, today.members)}
        </Chip>
        {today.pending > 0 ? <Chip tone="warn">{t.waiting(today.pending)}</Chip> : null}
        {today.failed > 0 ? (
          <Chip tone="error">{t.failedBriefs(today.failed)}</Chip>
        ) : null}
        {today.requested > 0 ? (
          <Chip tone={undefined}>{t.requestedBriefs(today.requested)}</Chip>
        ) : null}
        {next ? (
          <span className="bft-daily-brief-muted">{t.nextBrief(next)}</span>
        ) : null}
      </div>
    </section>
  );
}

const runTones: Record<BftDailyBriefRun["status"], Tone> = {
  running: "warn",
  pending: "warn",
  completed: "ok",
  failed: "error",
};

export function Runs({
  runs,
  onRequest,
}: {
  runs: BftDailyBrief["runs"];
  onRequest: (member: string) => Promise<unknown>;
}) {
  return (
    <FormSection title={t.runsTitle}>
      {runs.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.runsEmpty}</p>
      ) : (
        <table className="bft-table bft-daily-brief-runs">
          <thead>
            <tr>
              <th scope="col">{t.columnWhen}</th>
              <th scope="col">{t.columnRun}</th>
              <th scope="col">{t.columnStatus}</th>
              <th className="bft-col-tokens" scope="col">
                {t.columnTokens}
              </th>
              <th scope="col">{t.columnNote}</th>
            </tr>
          </thead>
          <tbody>
            {runs.map((run) => (
              <RunRow key={run.id} onRequest={onRequest} run={run} />
            ))}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}

function RunRow({
  run,
  onRequest,
}: {
  run: BftDailyBriefRun;
  onRequest: (member: string) => Promise<unknown>;
}) {
  const write = useWrite();
  const member = run.member_id;
  // A brief Slack did not take: its member can be sent one again.
  const resend = run.retryable && member !== null;
  const note = [run.error, run.complete ? null : t.partial].filter(Boolean).join(" · ");
  return (
    <tr>
      <td className="bft-truncate" title={run.at}>
        {formatRelative(run.at) ?? "—"}
      </td>
      <td className="bft-truncate">
        {t.runKinds[run.kind]}
        {run.member ? (
          <span className="bft-daily-brief-muted"> · {run.member}</span>
        ) : null}
      </td>
      <td>
        <Chip tone={runTones[run.status]}>{t.runStatuses[run.status]}</Chip>
      </td>
      <td className="bft-col-tokens bft-daily-brief-number">
        {run.tokens > 0 ? formatCompact(run.tokens) : "—"}
      </td>
      <td className="bft-truncate">
        {resend ? (
          <Button
            disabled={write.busy || write.saved}
            hierarchy="secondary-gray"
            onPress={() =>
              write.run(
                () => onRequest(member),
                () => undefined
              )
            }
            size="sm"
          >
            {write.saved ? t.requested : t.sendAgain}
          </Button>
        ) : null}
        {write.error ? (
          <span className="bft-dialog-error" role="alert">
            {t.requestFailed}
          </span>
        ) : (
          <span className="bft-daily-brief-muted" title={note}>
            {note ? ` ${note}` : ""}
          </span>
        )}
      </td>
    </tr>
  );
}
