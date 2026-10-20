import { messages } from "./messages";
import { orgHref } from "./navSpec";
import { spaLinkClick } from "./router";

const t = messages.states;

export function ErrorState({ onRetry }: { onRetry: () => void }) {
  return (
    <div className="bft-state" role="alert">
      <h2>{t.errorTitle}</h2>
      <p>{t.errorBody}</p>
      <button className="bft-btn" onClick={onRetry} type="button">
        {t.retry}
      </button>
    </div>
  );
}

/** A reload after a write failed: the data above it is the last one read. */
export function StaleNotice({ onRetry }: { onRetry: () => void }) {
  return (
    <div className="bft-quiet-row bft-quiet-row-flush" role="alert">
      <p className="bft-quiet bft-quiet-inline">{t.staleBody}</p>
      <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
        {t.retry}
      </button>
    </div>
  );
}

export function OrgNotFound() {
  return (
    <div className="bft-state">
      <h2>{t.orgNotFoundTitle}</h2>
      <p>{t.orgNotFoundBody}</p>
      <a className="bft-btn" href="/orgs">
        {t.backToOrganizations}
      </a>
    </div>
  );
}

export function ProjectNotFound({ org }: { org: string }) {
  return (
    <div className="bft-state">
      <h2>{t.projectNotFoundTitle}</h2>
      <p>{t.projectNotFoundBody}</p>
      <a className="bft-btn" href={orgHref(org, "/projects")} onClick={spaLinkClick}>
        {t.backToAgentSwarms}
      </a>
    </div>
  );
}

/** An owner/admin page answered 403 for this member. */
export function Forbidden({ org }: { org: string }) {
  return (
    <div className="bft-state">
      <h2>{t.forbiddenTitle}</h2>
      <p>{t.forbiddenBody}</p>
      <a className="bft-btn" href={orgHref(org)}>
        {t.backToOverview}
      </a>
    </div>
  );
}

export function PageNotFound() {
  return (
    <div className="bft-state bft-state-page">
      <h2>{t.pageNotFoundTitle}</h2>
      <p>{t.pageNotFoundBody}</p>
      <a className="bft-btn" href="/orgs">
        {t.backToOrganizations}
      </a>
    </div>
  );
}

export function Skeleton({
  width,
  height,
}: {
  width?: number | string;
  height?: number;
}) {
  return (
    <span
      aria-hidden="true"
      className="bft-skeleton"
      style={{ width: width ?? "100%", height: height ?? 12 }}
    />
  );
}
