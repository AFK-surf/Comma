import { Button, Checkbox, InputField } from "@comma/ui";
import { useEffect, useState, type FormEvent } from "react";
import {
  BftUnauthenticatedError,
  type BftCliLogin,
  type BftCliLoginStatus,
} from "./api";
import { DialogError } from "./dialogs";
import { FlashNotice } from "./flash";
import { formatRelative } from "./format";
import { messages } from "./messages";
import { useApi, useResource } from "./resource";
import { navigate, spaLinkClick } from "./router";
import { useWrite } from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.cliLogin;

const time = (iso: string | null) => (iso ? (formatRelative(iso) ?? iso) : "—");

const statusTones: Partial<Record<BftCliLoginStatus, string>> = {
  pending: "warn",
  approved: "ok",
  expired: "warn",
};

/** The code as the server stores it: upper case letters and digits only. */
export const normalizeUserCode = (value: string) =>
  value
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");

/**
 * The BFT CLI device-login approval page. It belongs to no organization, so
 * it has no sidebar. Phoenix serves it only to owners and admins; anyone else
 * is redirected to `/orgs` with an error flash.
 */
export function CliLoginPage({
  code,
  pathname,
}: {
  code: string | undefined;
  pathname: string;
}) {
  useEffect(() => {
    document.title = `${t.title} · ${messages.productName}`;
  }, []);

  return (
    <div className="bft-standalone">
      <header className="bft-standalone-head">
        <a className="bft-standalone-brand" href="/orgs" onClick={spaLinkClick}>
          {messages.productName}
        </a>
      </header>
      <main className="bft-standalone-main">
        <FlashNotice pathname={pathname} />
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{t.description}</p>
        </div>
        {code === undefined ? <CodeForm /> : <Request code={code} />}
      </main>
    </div>
  );
}

function CodeForm({ notFound = false }: { notFound?: boolean }) {
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | undefined>();
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const code = normalizeUserCode(value);
    if (code) navigate(`/cli/device-login/${encodeURIComponent(code)}`);
    else setError(t.enterCode);
  };
  return (
    <form className="bft-form bft-standalone-section" noValidate onSubmit={submit}>
      {notFound ? (
        <p className="bft-notice" role="alert">
          {t.notFound}
        </p>
      ) : null}
      <InputField
        autoComplete="one-time-code"
        className="w-full"
        fieldSize="sm"
        hint={t.codeHint}
        label={t.userCode}
        onChange={(event) => {
          setValue(event.target.value);
          setError(undefined);
        }}
        value={value}
        wrapperClassName="bft-form-field"
        {...(error ? { errorMessage: error } : {})}
      />
      <div className="bft-form-actions">
        <Button hierarchy="primary" size="sm" type="submit">
          {t.continue}
        </Button>
      </div>
    </form>
  );
}

function Request({ code }: { code: string }) {
  const api = useApi();
  const [resource, retry] = useResource(`cli-login:${code}`, (signal) =>
    api.cliLogin(code, signal)
  );
  // A write answers with the request as it is now; it replaces the loaded one.
  const [written, setWritten] = useState<BftCliLogin | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const write = useWrite();

  if (resource.state === "error") {
    return resource.error instanceof BftUnauthenticatedError ? (
      <Skeleton height={120} />
    ) : (
      <ErrorState onRetry={retry} />
    );
  }
  if (resource.state === "loading") {
    return (
      <div className="bft-rows-skeleton bft-rows-skeleton-flush">
        <Skeleton height={14} width="40%" />
        <Skeleton height={14} width="60%" />
        <Skeleton height={14} width="50%" />
      </div>
    );
  }

  const data = written ?? resource.data;
  const request = data.request;
  if (!request) return <CodeForm notFound />;

  // A refused write shows its reason next to the request as it is now.
  const run = (action: () => Promise<BftCliLogin>) =>
    write.run(
      () =>
        action().catch((error: unknown) => {
          setWritten(null);
          retry();
          throw error;
        }),
      (next) => {
        setWritten(next);
        setSelected([]);
      }
    );

  return (
    <>
      <dl className="bft-kv bft-standalone-section">
        <dt>{t.userCode}</dt>
        <dd className="bft-mono">{request.user_code}</dd>
        <dt>{t.status}</dt>
        <dd>
          <span className="bft-status" data-tone={statusTones[request.status]}>
            {t.statuses[request.status]}
          </span>
        </dd>
        <dt>{t.client}</dt>
        <dd className="bft-truncate">{request.client_name ?? t.defaultClient}</dd>
        <dt>{t.requested}</dt>
        <dd title={request.created_at ?? undefined}>{time(request.created_at)}</dd>
        <dt>{t.expires}</dt>
        <dd title={request.expires_at ?? undefined}>{time(request.expires_at)}</dd>
      </dl>
      {request.status === "pending" ? (
        <section aria-labelledby="cli-orgs" className="bft-form-section">
          <div className="bft-form-section-head">
            <h2 id="cli-orgs">{t.orgsTitle}</h2>
          </div>
          <p className="bft-form-section-note">{t.orgsHint}</p>
          <div className="bft-checklist">
            {data.orgs.map((org) => (
              <Checkbox
                checked={selected.includes(org.id)}
                key={org.id}
                label={org.name}
                onChange={(event) =>
                  setSelected((ids) =>
                    event.target.checked
                      ? [...ids, org.id]
                      : ids.filter((id) => id !== org.id)
                  )
                }
                size="sm"
              />
            ))}
          </div>
          <div className="bft-form-actions">
            <DialogError message={write.error} />
            <Button
              hierarchy="secondary-gray"
              disabled={write.busy}
              onPress={() => run(() => api.denyCliLogin(code))}
              size="sm"
            >
              {t.deny}
            </Button>
            <Button
              hierarchy="primary"
              disabled={write.busy || selected.length === 0}
              onPress={() => run(() => api.approveCliLogin(code, selected))}
              size="sm"
            >
              {write.busy ? messages.common.working : t.approve}
            </Button>
          </div>
        </section>
      ) : (
        <section className="bft-form-section">
          <DialogError message={write.error} />
          <p className="bft-dialog-note">{t[request.status]}</p>
          {request.granted_orgs.length > 0 ? (
            <>
              <h2 className="bft-field-label">{t.grantedTitle}</h2>
              <ul className="bft-list bft-setting-rows">
                {request.granted_orgs.map((org) => (
                  <li className="bft-setting-row" key={org.id}>
                    <span className="bft-truncate">{org.name}</span>
                  </li>
                ))}
              </ul>
            </>
          ) : null}
          <a className="bft-link" href="/orgs" onClick={spaLinkClick}>
            {t.backToDashboard}
          </a>
        </section>
      )}
    </>
  );
}
