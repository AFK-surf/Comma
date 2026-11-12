import { useState } from "react";
import type { BftSwarmStillfail } from "./api";
import { CodeBlock, CopyButton, writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatCompact, formatInteger, formatRelative } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi, useLastReady, type Resource } from "./resource";
import { FormSection, SettingsPage } from "./settingsForm";
import { StaleNotice } from "./states";

const t = messages.swarmStillfail;

const money = new Intl.NumberFormat(undefined, {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 2,
});

/**
 * An Agent Swarm's still.fail stations: each connected through its Comma
 * connect with a line this page gives, whether it is connected now, and what
 * still.fail's agents spent by person. Admins make a line and remove the
 * stations.
 */
export function SwarmStillfailPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<BftSwarmStillfail>;
  onRetry: () => void;
}) {
  const api = useApi();
  const { data, resource, stale } = useLastReady(first);
  const [busy, setBusy] = useState(false);
  // The line made last, shown until the page is left: it is not given again.
  const [line, setLine] = useState<string | null>(null);
  const path = projectHref(org, project, "/stillfail");

  const fail = (error: unknown) => {
    setBusy(false);
    showFlash({ kind: "error", text: writeErrorMessage(error) ?? "" }, path);
    onRetry();
  };

  const makeLine = () => {
    setBusy(true);
    api.stillfailLine(org, project).then((made) => {
      setBusy(false);
      setLine(made.line);
    }, fail);
  };

  const remove = () => {
    setBusy(true);
    api.removeStillfail(org, project).then(({ notice }) => {
      setBusy(false);
      setLine(null);
      showFlash({ kind: "info", text: notice }, path);
      onRetry();
    }, fail);
  };

  return (
    <SettingsPage
      description={data ? t.description(data.project.name) : undefined}
      onRetry={onRetry}
      resource={resource}
      title={t.title}
      wide
    >
      {(page) => (
        <>
          {stale ? <StaleNotice onRetry={onRetry} /> : null}
          <Stations
            busy={busy}
            line={line}
            manage={page.project.role === "admin"}
            onLine={makeLine}
            onRemove={remove}
            page={page}
          />
          <Usage page={page} />
        </>
      )}
    </SettingsPage>
  );
}

function Stations({
  page,
  manage,
  busy,
  line,
  onLine,
  onRemove,
}: {
  page: BftSwarmStillfail;
  manage: boolean;
  busy: boolean;
  line: string | null;
  onLine: () => void;
  onRemove: () => void;
}) {
  const { stations } = page;

  return (
    <FormSection title={t.stations}>
      {stations.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">
          {manage ? t.noStations : t.noStationsMember}
        </p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.name}</th>
              <th scope="col">{t.state}</th>
              <th scope="col">{t.since}</th>
            </tr>
          </thead>
          <tbody>
            {stations.map((station) => (
              <tr key={station.id}>
                <td>{station.name ?? "still.fail"}</td>
                <td>{station.connected ? t.connected : t.offline}</td>
                <td>
                  {station.connected_at
                    ? formatRelative(new Date(station.connected_at).toISOString())
                    : t.never}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {manage && line !== null ? (
        <div>
          <p className="bft-quiet bft-quiet-inline">{t.lineHint}</p>
          <CodeBlock label={t.line} text={line} />
          <CopyButton label={t.line} text={line} />
        </div>
      ) : null}
      {manage ? (
        <div className="bft-inline-actions">
          <button className="bft-btn" disabled={busy} onClick={onLine} type="button">
            {busy ? t.working : t.addStation}
          </button>
          {stations.length > 0 ? (
            <button
              className="bft-btn"
              disabled={busy}
              onClick={onRemove}
              type="button"
            >
              {t.remove}
            </button>
          ) : null}
        </div>
      ) : null}
    </FormSection>
  );
}

function Usage({ page }: { page: BftSwarmStillfail }) {
  return (
    <FormSection title={t.usage(page.days)}>
      {page.usage.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noUsage}</p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.person}</th>
              <th scope="col">{t.calls}</th>
              <th scope="col">{t.tokens}</th>
              <th scope="col">{t.cost}</th>
            </tr>
          </thead>
          <tbody>
            {page.usage.map((row) => (
              <tr key={row.key ?? ""}>
                <td>{row.key ?? t.unknownPerson}</td>
                <td>{formatInteger(row.calls)}</td>
                <td
                  title={formatInteger(
                    row.input + row.cache_read + row.cache_write + row.output
                  )}
                >
                  {formatCompact(
                    row.input + row.cache_read + row.cache_write + row.output
                  )}
                </td>
                <td>{row.cost === null ? "—" : money.format(row.cost)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}
