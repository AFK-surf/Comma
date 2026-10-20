import { Button } from "@comma/ui/components/Button";
import { Checkbox } from "@comma/ui/components/checkbox";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useEffect, useId, useState, type ReactNode } from "react";
import {
  BftUnauthenticatedError,
  wizardSteps,
  type BftToolkitState,
  type BftWizard,
  type BftWizardFinish,
  type BftWizardIntegrations,
  type BftWizardStep,
} from "./api";
import { ConfirmDialog, DialogError } from "./dialogs";
import { FlashNotice, showFlash } from "./flash";
import { messages } from "./messages";
import { orgHref, projectHref, settingsPaths } from "./navSpec";
import { dataKey, useApi, useResource, type Resource } from "./resource";
import { navigate, spaLinkClick } from "./router";
import { useWrite } from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.onboardingWizard;

export const wizardPath = (step: BftWizardStep) =>
  step === "capabilities" ? "/onboarding" : `/onboarding/${step}`;

// A bare `/onboarding` resumes on the step reached before, once per page load,
// so Back to the first step stays there.
let resumeChecked = false;

/**
 * The first-run onboarding wizard: capabilities, profile, integrations. It
 * lives outside any organization, since a new user may have none. Phoenix
 * serves it only to users who have not finished it, and the dashboard sends
 * those users here first.
 */
export function OnboardingWizard({
  step,
  pathname,
}: {
  step: BftWizardStep;
  pathname: string;
}) {
  const api = useApi();
  const [resource, retry] = useResource("onboarding-wizard", (signal) =>
    api.wizard(signal)
  );
  // A saved step answers with the wizard as it is now.
  const [written, setWritten] = useState<BftWizard | null>(null);
  const data = written ?? (resource.state === "ready" ? resource.data : undefined);
  const finished = data !== undefined && data.status !== "in_progress";
  const resumeTo =
    data && !resumeChecked && step === "capabilities" && data.step !== step
      ? data.step
      : undefined;

  useEffect(() => {
    document.title = `${t.pageTitle} · ${messages.productName}`;
  }, []);

  useEffect(() => {
    if (!data) return;
    resumeChecked = true;
    if (finished) navigate("/", { replace: true });
    else if (resumeTo) navigate(wizardPath(resumeTo), { replace: true });
  }, [data, finished, resumeTo]);

  const index = wizardSteps.indexOf(step);

  return (
    <div className="bft-standalone bft-wizard-page">
      <header className="bft-standalone-head">
        <span className="bft-standalone-brand">{messages.productName}</span>
      </header>
      <ScrollArea
        className="bft-wizard-scroll"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-scroll-viewport"
      >
        <main className="bft-standalone-main bft-wizard">
          <FlashNotice pathname={pathname} />
          <p className="bft-wizard-progress">
            {t.stepOf(index + 1, wizardSteps.length)}
          </p>
          {resource.state === "error" && !written ? (
            resource.error instanceof BftUnauthenticatedError ? (
              <WizardSkeleton />
            ) : (
              <ErrorState onRetry={retry} />
            )
          ) : !data || finished || resumeTo ? (
            <WizardSkeleton />
          ) : (
            <Step data={data} key={dataKey(data)} onSaved={setWritten} step={step} />
          )}
        </main>
      </ScrollArea>
    </div>
  );
}

function Step({
  step,
  data,
  onSaved,
}: {
  step: BftWizardStep;
  data: BftWizard;
  onSaved: (data: BftWizard) => void;
}) {
  switch (step) {
    case "capabilities":
      return <CapabilitiesStep data={data} onSaved={onSaved} />;
    case "profile":
      return <ProfileStep data={data} onSaved={onSaved} />;
    case "integrations":
      return <IntegrationsStep data={data} />;
  }
}

function Heading({ title, description }: { title: string; description: string }) {
  return (
    <div className="bft-page-heading">
      <h1>{title}</h1>
      <p>{description}</p>
    </div>
  );
}

/**
 * Back, Skip onboarding and the step's one primary action. Skipping asks
 * first; both skipping and finishing open the dashboard.
 */
function Actions({
  back,
  primaryLabel,
  busy,
  error,
  onPrimary,
}: {
  back: BftWizardStep | null;
  primaryLabel: string;
  busy: boolean;
  error: string | undefined;
  onPrimary: () => void;
}) {
  const api = useApi();
  const [asking, setAsking] = useState(false);
  const skip = useWrite();
  return (
    <>
      <DialogError message={error} />
      <div className="bft-wizard-actions">
        {back ? (
          <Button
            disabled={busy}
            hierarchy="secondary-gray"
            onPress={() => navigate(wizardPath(back))}
            size="sm"
          >
            {t.back}
          </Button>
        ) : null}
        <Button
          disabled={busy}
          hierarchy="tertiary-gray"
          onPress={() => setAsking(true)}
          size="sm"
        >
          {t.skip}
        </Button>
        <span className="bft-wizard-spacer" />
        <Button disabled={busy} hierarchy="primary" onPress={onPrimary} size="sm">
          {busy ? messages.common.working : primaryLabel}
        </Button>
      </div>
      {asking ? (
        <ConfirmDialog
          busy={skip.busy}
          confirmLabel={t.skip}
          description={t.skipBody}
          error={skip.error}
          onClose={() => {
            setAsking(false);
            skip.reset();
          }}
          onConfirm={() => skip.run(() => api.skipWizard(), leave)}
          title={t.skipTitle}
        />
      ) : null}
    </>
  );
}

/** Opens the dashboard after the wizard ends, with its notice when it has one. */
function leave(finish: BftWizardFinish) {
  if (finish.notice) showFlash({ kind: "info", text: finish.notice }, finish.redirect);
  navigate(finish.redirect, { replace: true });
}

function CapabilitiesStep({
  data,
  onSaved,
}: {
  data: BftWizard;
  onSaved: (data: BftWizard) => void;
}) {
  const api = useApi();
  const [grants, setGrants] = useState(data.capabilities);
  const write = useWrite();
  const c = t.capabilities;

  const set = (keys: string[], on: boolean) =>
    setGrants((current) => ({
      ...current,
      ...Object.fromEntries(keys.map((key) => [key, on])),
    }));

  return (
    <>
      <Heading description={c.description} title={c.title} />
      <div className="bft-wizard-sections">
        {data.capability_groups.map((group) => {
          const copy = c.groups[group.key];
          const on = group.capabilities.filter((key) => grants[key]).length;
          return (
            <section className="bft-wizard-group" key={group.key}>
              <Checkbox
                checked={on === group.capabilities.length}
                {...(copy ? { hint: copy.description } : {})}
                indeterminate={on > 0 && on < group.capabilities.length}
                label={<strong>{copy?.title ?? group.key}</strong>}
                onChange={(event) => set(group.capabilities, event.target.checked)}
                size="sm"
              />
              <div className="bft-wizard-items">
                {group.capabilities.map((key) => {
                  const item = c.items[key];
                  return (
                    <Checkbox
                      checked={grants[key] === true}
                      {...(item ? { hint: item.description } : {})}
                      key={key}
                      label={item?.label ?? key}
                      onChange={(event) => set([key], event.target.checked)}
                      size="sm"
                    />
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>
      <Actions
        back={null}
        busy={write.busy}
        error={write.error}
        onPrimary={() =>
          write.run(
            () => api.saveWizardCapabilities(grants),
            (saved) => {
              onSaved(saved);
              navigate(wizardPath("profile"));
            }
          )
        }
        primaryLabel={t.continue}
      />
    </>
  );
}

function ProfileStep({
  data,
  onSaved,
}: {
  data: BftWizard;
  onSaved: (data: BftWizard) => void;
}) {
  const api = useApi();
  const [integrations] = useResource("onboarding-integrations", (signal) =>
    api.wizardIntegrations(signal)
  );
  const write = useWrite();
  const p = t.profile;
  const { user, org, teammates } = data;
  const more = teammates.total - teammates.sample.length;

  return (
    <>
      <Heading description={p.description} title={p.title} />
      <div className="bft-wizard-sections">
        <Section title={p.identityTitle}>
          <dl className="bft-kv">
            <div>
              <dt>{p.name}</dt>
              <dd>{user.name ?? user.email ?? "—"}</dd>
            </div>
            {user.email ? (
              <div>
                <dt>{p.email}</dt>
                <dd>{user.email}</dd>
              </div>
            ) : null}
            {org ? (
              <>
                <div>
                  <dt>{p.organization}</dt>
                  <dd>{org.name}</dd>
                </div>
                <div>
                  <dt>{p.role}</dt>
                  <dd>{p.roles[org.role ?? "member"]}</dd>
                </div>
                <div>
                  <dt>{p.teammates}</dt>
                  <dd>{teammates.total}</dd>
                </div>
              </>
            ) : null}
          </dl>
        </Section>
        <Section note={p.contactsNote} title={p.contactsTitle}>
          {teammates.sample.length === 0 ? (
            <p className="bft-wizard-quiet">{p.contactsEmpty}</p>
          ) : (
            <ul className="bft-list">
              {teammates.sample.map((member, position) => (
                <Row
                  aside={<span className="bft-muted">{p.roles[member.role]}</span>}
                  key={`${member.email ?? ""}:${position}`}
                  sub={member.name ? member.email : null}
                  title={member.name ?? member.email ?? "—"}
                />
              ))}
              {more > 0 ? (
                <li className="bft-wizard-row bft-wizard-quiet">
                  {p.contactsMore(more)}
                </li>
              ) : null}
            </ul>
          )}
        </Section>
        <Section title={p.plansTitle}>
          <Plans integrations={integrations} />
        </Section>
        <p className="bft-wizard-quiet">{p.editLater}</p>
      </div>
      <Actions
        back="capabilities"
        busy={write.busy}
        error={write.error}
        onPrimary={() =>
          write.run(
            () => api.saveWizardProfile(),
            (saved) => {
              onSaved(saved);
              navigate(wizardPath("integrations"));
            }
          )
        }
        primaryLabel={t.continue}
      />
    </>
  );
}

/**
 * The behavioral sections are plans: "Learning" only once Google is really
 * connected. When the connections cannot be read, they stay plans.
 */
function Plans({ integrations }: { integrations: Resource<BftWizardIntegrations> }) {
  const p = t.profile;
  if (integrations.state === "loading") return <RowsSkeleton rows={3} />;
  const learning =
    integrations.state === "ready" &&
    integrations.data.connected_providers.includes("google");
  return (
    <ul className="bft-list">
      {(["work_patterns", "communication_style", "writing_style"] as const).map(
        (key) => {
          const plan = p.plans[key];
          return (
            <Row
              aside={
                <span className="bft-status" data-tone={learning ? "ok" : undefined}>
                  {learning ? p.learning : p.planned}
                </span>
              }
              key={key}
              sub={learning ? plan.learning : plan.planned}
              title={plan.title}
            />
          );
        }
      )}
    </ul>
  );
}

function IntegrationsStep({ data }: { data: BftWizard }) {
  const api = useApi();
  const [integrations, retry] = useResource("onboarding-integrations", (signal) =>
    api.wizardIntegrations(signal)
  );
  const finish = useWrite();
  const i = t.integrations;

  return (
    <>
      <Heading description={i.description} title={i.title} />
      {integrations.state === "loading" ? (
        <RowsSkeleton rows={5} />
      ) : integrations.state === "error" ? (
        integrations.error instanceof BftUnauthenticatedError ? (
          <RowsSkeleton rows={5} />
        ) : (
          <ErrorState onRetry={retry} />
        )
      ) : (
        <Integrations data={integrations.data} org={data.org?.slug ?? null} />
      )}
      <Actions
        back="profile"
        busy={finish.busy}
        error={finish.error}
        onPrimary={() => finish.run(() => api.completeWizard(), leave)}
        primaryLabel={t.finish}
      />
    </>
  );
}

function Integrations({
  data,
  org,
}: {
  data: BftWizardIntegrations;
  org: string | null;
}) {
  const api = useApi();
  const connect = useWrite();
  const i = t.integrations;
  const toolkits = messages.swarmConnections.toolkits;
  const project = data.project;

  if (!project || !org) {
    return (
      <div className="bft-wizard-sections">
        <Section note={i.noSwarmBody} title={i.noSwarmTitle}>
          {null}
        </Section>
      </div>
    );
  }

  const start = (toolkit: string) =>
    connect.run(
      () => api.connectWizardToolkit(toolkit),
      ({ redirect_url }) => window.location.assign(redirect_url)
    );

  return (
    <div className="bft-wizard-sections">
      <Section note={i.swarmNote(project.name)} title={i.appsTitle}>
        {data.composio.status === "unavailable" ? (
          <output className="bft-notice">{i.unavailable}</output>
        ) : null}
        <DialogError message={connect.error} />
        <ul className="bft-list">
          {data.toolkits.map(({ toolkit, state }) => {
            const copy = toolkits[toolkit];
            const label = copy?.label ?? toolkit;
            return (
              <Row
                aside={
                  <ToolkitAction
                    busy={connect.busy}
                    label={label}
                    onConnect={() => start(toolkit)}
                    state={state}
                  />
                }
                key={toolkit}
                sub={copy?.description ?? null}
                title={label}
              />
            );
          })}
        </ul>
        {data.can_connect && !data.composio.configured ? (
          <p className="bft-wizard-quiet">
            {i.notConfigured}{" "}
            {data.org_admin ? (
              <a
                className="bft-link"
                href={`${orgHref(org, settingsPaths.integrations)}#composio`}
                onClick={spaLinkClick}
              >
                {i.configure}
              </a>
            ) : (
              i.askOrgAdmin
            )}
          </p>
        ) : null}
      </Section>
      <Section note={i.messagingNote} title={i.messagingTitle}>
        <ul className="bft-list">
          {data.messaging.map(({ provider, connected }) => {
            const label = i.messaging[provider] ?? provider;
            return (
              <Row
                aside={
                  connected ? (
                    <span className="bft-status" data-tone="ok">
                      {i.connected}
                    </span>
                  ) : (
                    <a
                      aria-label={i.setUpFor(label)}
                      className="bft-link bft-setting-row-link"
                      href={`${projectHref(org, project.id, "/connections")}?provider=${encodeURIComponent(provider)}`}
                      onClick={spaLinkClick}
                    >
                      {i.setUp}
                    </a>
                  )
                }
                key={provider}
                sub={null}
                title={label}
              />
            );
          })}
        </ul>
      </Section>
    </div>
  );
}

function ToolkitAction({
  state,
  label,
  busy,
  onConnect,
}: {
  state: BftToolkitState;
  label: string;
  busy: boolean;
  onConnect: () => void;
}) {
  const i = t.integrations;
  switch (state) {
    case "connected":
      return (
        <span className="bft-status" data-tone="ok">
          {i.connected}
        </span>
      );
    case "ask_admin":
      return <span className="bft-muted">{i.askOwner}</span>;
    case "connectable":
    case "unconfigured":
      return (
        <Button
          aria-label={i.connectFor(label)}
          disabled={busy || state === "unconfigured"}
          hierarchy="secondary-gray"
          onPress={onConnect}
          size="xs"
        >
          {i.connect}
        </Button>
      );
  }
}

function Section({
  title,
  note,
  children,
}: {
  title: string;
  note?: string;
  children: ReactNode;
}) {
  const id = useId();
  return (
    <section aria-labelledby={id} className="bft-wizard-section">
      <h2 id={id}>{title}</h2>
      {note ? <p className="bft-wizard-quiet">{note}</p> : null}
      {children}
    </section>
  );
}

function Row({
  title,
  sub,
  aside,
}: {
  title: string;
  sub: string | null;
  aside: ReactNode;
}) {
  return (
    <li className="bft-wizard-row">
      <span className="bft-setting-row-main">
        <span className="bft-truncate">{title}</span>
        {sub ? <span className="bft-setting-row-sub">{sub}</span> : null}
      </span>
      <span className="bft-wizard-aside">{aside}</span>
    </li>
  );
}

function RowsSkeleton({ rows }: { rows: number }) {
  return (
    <div className="bft-rows-skeleton bft-rows-skeleton-flush">
      {Array.from({ length: rows }, (_, row) => (
        <Skeleton height={14} key={row} width={`${60 - row * 6}%`} />
      ))}
    </div>
  );
}

function WizardSkeleton() {
  return (
    <div aria-busy="true">
      <span className="bft-sr-only">{messages.states.loading}</span>
      <RowsSkeleton rows={4} />
    </div>
  );
}
