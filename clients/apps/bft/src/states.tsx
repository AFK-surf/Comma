import { messages } from "./messages";

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
