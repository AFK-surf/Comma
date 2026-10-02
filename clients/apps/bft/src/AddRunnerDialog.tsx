import { Button, Dialog, ScrollArea } from "@comma/ui";
import { useState } from "react";
import { BftApiError, type BftInstallCommand, type BftRunnerOnboarding } from "./api";
import { CodeBlock, CopyButton, DialogError, writeErrorMessage } from "./dialogs";
import { formatRelative, formatTime } from "./format";
import { messages } from "./messages";
import { useResource } from "./resource";
import { Skeleton } from "./states";

const t = messages.runners;

export const releaseUnavailableCode = "server_release_unavailable";

/** The 503 for a missing Server release gets a clearer line than the server's. */
export function installErrorMessage(error: unknown) {
  return error instanceof BftApiError && error.code === releaseUnavailableCode
    ? t.releaseUnavailable
    : writeErrorMessage(error);
}

/** A freshly issued install command. It is never fetched again: shown once. */
export function InstallCommand({ issued }: { issued: BftInstallCommand }) {
  const time = formatTime(issued.expires_at);
  const relative = formatRelative(issued.expires_at);
  return (
    <div className="bft-command">
      <div className="bft-command-head">
        <span className="bft-command-label">{t.installCommand}</span>
        <CopyButton
          label={messages.common.copyLabel(t.installCommand)}
          text={issued.command}
        />
      </div>
      <CodeBlock label={t.installCommand} text={issued.command} />
      <p className="bft-command-note">
        {t.commandOnce}{" "}
        {time ? t.commandExpires(relative ? `${time} (${relative})` : time) : null}
      </p>
    </div>
  );
}

export function AddRunnerDialog({
  org,
  loadOnboarding,
  createCommand,
  onClose,
}: {
  org: string;
  loadOnboarding: (signal: AbortSignal) => Promise<BftRunnerOnboarding>;
  createCommand: () => Promise<BftInstallCommand>;
  onClose: () => void;
}) {
  const [onboarding, retry] = useResource(`runner-onboarding:${org}`, loadOnboarding);
  const [issued, setIssued] = useState<BftInstallCommand>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  const generate = () => {
    setBusy(true);
    setError(undefined);
    createCommand().then(
      (command) => {
        setIssued(command);
        setBusy(false);
      },
      (caught: unknown) => {
        setBusy(false);
        setError(installErrorMessage(caught));
      }
    );
  };

  const data = onboarding.state === "ready" ? onboarding.data : undefined;
  const primary = data?.local_steps.filter((step) => step.group === "primary") ?? [];
  const advanced = data?.local_steps.filter((step) => step.group === "advanced") ?? [];

  return (
    <Dialog
      actions={[
        {
          label: t.done,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: busy,
        },
      ]}
      className="bft-dialog-wide"
      description={t.addBody}
      isDismissable={!busy}
      isOpen
      onOpenChange={(open) => {
        // Closing mid-request would lose the one-time command it returns.
        if (!open && !busy) onClose();
      }}
      title={t.addTitle}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        {onboarding.state === "error" ? (
          <div className="bft-quiet-row" role="alert">
            <p className="bft-quiet bft-quiet-inline">{t.onboardingFailed}</p>
            <Button hierarchy="secondary-gray" onPress={retry} size="xs">
              {messages.states.retry}
            </Button>
          </div>
        ) : !data ? (
          <div className="bft-rows-skeleton bft-rows-skeleton-flush">
            <Skeleton height={14} width="40%" />
            <Skeleton height={14} />
            <Skeleton height={14} width="70%" />
          </div>
        ) : (
          <div className="bft-onboarding">
            <ol className="bft-steps">
              <li className="bft-step">
                <h3 className="bft-step-title">
                  <span className="bft-step-index">1</span>
                  {t.stepGenerateTitle}
                </h3>
                <p className="bft-step-body">
                  {t.stepGenerateBody(Math.round(data.install_code_ttl_seconds / 60))}
                </p>
                <dl className="bft-kv bft-step-kv">
                  <div>
                    <dt>{t.orgId}</dt>
                    <dd title={data.org_id}>{data.org_id}</dd>
                  </div>
                  <div>
                    <dt>{t.apiBase}</dt>
                    <dd title={data.api_base_url}>{data.api_base_url}</dd>
                  </div>
                </dl>
                <div className="bft-step-actions">
                  <Button
                    disabled={busy}
                    hierarchy={issued ? "secondary-gray" : "primary"}
                    onPress={generate}
                    size="sm"
                  >
                    {busy ? t.generating : issued ? t.generateAnother : t.generate}
                  </Button>
                </div>
                <DialogError message={error} />
                {issued ? <InstallCommand issued={issued} /> : null}
              </li>
              {primary.map((step, index) => (
                <li className="bft-step" key={step.id}>
                  <h3 className="bft-step-title">
                    <span className="bft-step-index">{index + 2}</span>
                    {step.title}
                  </h3>
                  <p className="bft-step-body">{step.description}</p>
                  <div className="bft-command-head">
                    <span className="bft-command-label">{t.stepsTitle}</span>
                    <CopyButton
                      label={messages.common.copyLabel(step.title)}
                      text={step.command}
                    />
                  </div>
                  <CodeBlock label={step.title} text={step.command} />
                </li>
              ))}
            </ol>
            {advanced.length > 0 ? (
              <details className="bft-details">
                <summary>{t.advancedTitle}</summary>
                <div className="bft-details-body">
                  {advanced.map((step) => (
                    <div className="bft-step" key={step.id}>
                      <div className="bft-command-head">
                        <span className="bft-step-title">{step.title}</span>
                        <CopyButton
                          label={messages.common.copyLabel(step.title)}
                          text={step.command}
                        />
                      </div>
                      <p className="bft-step-body">{step.description}</p>
                      <CodeBlock label={step.title} text={step.command} />
                    </div>
                  ))}
                  <dl className="bft-kv">
                    {(Object.keys(t.paths) as (keyof typeof t.paths)[]).map((key) => (
                      <div key={key}>
                        <dt>{t.paths[key]}</dt>
                        <dd title={data.paths[key]}>{data.paths[key]}</dd>
                      </div>
                    ))}
                  </dl>
                </div>
              </details>
            ) : null}
            <section aria-labelledby="bft-agent-title" className="bft-agent">
              <h3 className="bft-step-title" id="bft-agent-title">
                {t.agentTitle}
              </h3>
              <p className="bft-step-body">{t.agentBody}</p>
              <div className="bft-agent-row">
                <div className="bft-agent-copy">
                  <span className="bft-command-label">{t.agentHandoff}</span>
                  <span className="bft-agent-hint">{t.agentHandoffBody}</span>
                </div>
                <CopyButton
                  label={messages.common.copyLabel(t.agentHandoff)}
                  text={data.agent_handoff}
                />
              </div>
              <div className="bft-agent-row">
                <div className="bft-agent-copy">
                  <span className="bft-command-label">{t.agentSkill}</span>
                  <span className="bft-agent-hint">{t.agentSkillBody}</span>
                </div>
                <CopyButton
                  label={messages.common.copyLabel(t.agentSkill)}
                  text={data.agent_skill}
                />
              </div>
              <details className="bft-details">
                <summary>{t.showSkill}</summary>
                <div className="bft-details-body">
                  <CodeBlock label={t.agentSkill} text={data.agent_skill} />
                </div>
              </details>
            </section>
          </div>
        )}
      </ScrollArea>
    </Dialog>
  );
}
