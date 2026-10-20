import type { ReactNode, Ref } from "react";
import { Button } from "../Button";
import { ScrollArea } from "../scroll-area";
import { LoadingIndicator } from "../LoadingIndicator";
import { ChevronRightSmallIcon, CubeIcon } from "../icons";

/**
 * Every button on Devices: the 28px toolbar button with 12px text that Drive's
 * Transfer uses. Use it with `size="sm"`: that size's `px-3` matches `px-lg`,
 * while the `px-md` of `size="xs"` would win over `px-lg` in the stylesheet.
 * A text link keeps its link style at 12px.
 */
export const deviceSettingsButtonClassName = "h-auto px-lg py-xs text-xs";
/** An overflow menu: a 28px icon button. Its padding hangs past the edge. */
export const deviceSettingsMenuClassName = "h-7 w-7";

export function DeviceSettingsSection({
  title,
  action,
  children,
}: {
  title: string;
  action?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="compute-section">
      {(title || action) && (
        <div className="compute-section-heading">
          {title && <h2>{title}</h2>}
          {action}
        </div>
      )}
      {children}
    </section>
  );
}
export function DeviceSettingsRow({
  title,
  description,
  action,
  children,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className="compute-row">
      <div>
        <p className="compute-row-title">{title}</p>
        {description && <p className="compute-muted">{description}</p>}
        {children}
      </div>
      {action}
    </div>
  );
}
export function DeviceSettingsFacts({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl>
      {rows.map(([label, value]) => (
        <div className="compute-fact" key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}
export function DeviceSettingsStatus({
  children,
  tone = "neutral",
  pending = false,
}: {
  children: ReactNode;
  tone?: "good" | "warning" | "neutral";
  pending?: boolean;
}) {
  return (
    <output className="compute-status" data-tone={tone} data-pending={pending}>
      {pending && (
        <LoadingIndicator label={typeof children === "string" ? children : ""} />
      )}
      {children}
    </output>
  );
}
export function DeviceSettingsSteps({
  steps,
}: {
  steps: { label: string; phase: string | undefined; status: string }[];
}) {
  return (
    <ol className="compute-steps">
      {steps.map((step, i) => (
        <li key={step.label} data-phase={step.phase}>
          <span className="compute-step-number" aria-hidden>
            {step.phase === "ready" ? "✓" : i + 1}
          </span>
          <div>
            <p className="compute-row-title">{step.label}</p>
            <output className="compute-muted">{step.status}</output>
          </div>
        </li>
      ))}
    </ol>
  );
}
export function DeviceSettingsResource({
  name,
  description,
  status,
  actions,
  onOpen,
}: {
  name: string;
  description: string;
  status: ReactNode;
  actions: ReactNode;
  onOpen(): void;
}) {
  return (
    <div className="compute-workload">
      <button className="compute-resource" onClick={onOpen} aria-label={name}>
        <span className="comma-device__agent-mark" aria-hidden>
          <CubeIcon className="size-4" />
        </span>
        <span className="compute-resource-identity">
          <span className="compute-row-title">{name}</span>
          <span className="compute-muted">{description}</span>
        </span>
        {status}
        <ChevronRightSmallIcon className="size-3 compute-chevron" />
      </button>
      {actions}
    </div>
  );
}
export function DeviceSettingsDetail({
  title,
  subtitle,
  backLabel,
  onBack,
  headingRef,
  screen,
  children,
}: {
  title: string;
  subtitle: string;
  backLabel: string;
  onBack?: (() => void) | undefined;
  headingRef?: Ref<HTMLHeadingElement>;
  screen: string;
  children: ReactNode;
}) {
  return (
    <ScrollArea
      className="compute-scroll"
      orientation="vertical"
      edgeEffect="mask"
      scrollbarVisibility="hover"
    >
      <main className="compute-settings" data-compute-screen={screen}>
        {onBack && (
          <div className="compute-back">
            <Button hierarchy="link-gray" size="sm" onPress={onBack}>
              {backLabel}
            </Button>
          </div>
        )}
        <h1 ref={headingRef} tabIndex={-1}>
          {title}
        </h1>
        <p className="compute-muted compute-subtitle">{subtitle}</p>
        {children}
      </main>
    </ScrollArea>
  );
}
