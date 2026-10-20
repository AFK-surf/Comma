import { useId, useState, type ReactNode } from "react";
import { Button } from "../Button";
import { Dialog } from "../dialog";
import {
  ArrowRightIcon,
  DevicesIcon,
  PlusSmallIcon,
  OpenAiIcon,
  ClaudeAiIcon,
  CubeIcon,
  ChevronRightSmallIcon,
} from "../icons";
import { ChoiceList } from "../choice-list";
import { ScrollArea, ScrollAreaLoadMore } from "../scroll-area";
import { LoadingIndicator } from "../LoadingIndicator";
import { cx } from "../utils";
import { deviceSettingsButtonClassName } from "./DeviceSettingsContent";

/** How far the workspace's agents may go on a computer. */
export type DeviceAccessLevel = "off" | "read" | "full";

export interface DeviceSettingsItem {
  id: string;
  name: string;
  status: string;
  loading?: boolean;
  connected: boolean;
  local?: boolean;
  source?: string | undefined;
  description?: string | undefined;
  metadata?: string[] | undefined;
  actions?: ReactNode;
  content?: ReactNode;
  /** How this device reaches it now (direct, through a relay), under its name. */
  path?: string | undefined;
  /** Whether it takes Tasks, under its name: ready, or what keeps it from them. */
  tasks?: { label: string; ready: boolean } | undefined;
  runtimeCheck?:
    | {
        label: string;
        pending: boolean;
        disabled: boolean;
        error?: string | undefined;
        onCheck(): void;
      }
    | undefined;
  agents: {
    id: string;
    name: string;
    provider?: string;
    status: string;
    ready: boolean;
    attention?: boolean;
    description?: string | undefined;
    details?: string[];
  }[];
  access: {
    level: DeviceAccessLevel;
    disabled: boolean;
    onChange(level: DeviceAccessLevel): void;
  };
}

export interface DeviceSettingsProps {
  title: string;
  description: string;
  statusDescription: string;
  summary: string;
  addLabel: string;
  /** What the Add dialog shows: the install command for another computer. */
  addContent?: ReactNode;
  /** Asking the Router to help add one instead. */
  guidedLabel: string;
  addDisabled?: boolean;
  guidedDisabled?: boolean;
  localLabel: string;
  loadingLabel: string;
  emptyLabel: string;
  agentsLabel: string;
  discoveredLabel?: string;
  emptyAgentsLabel: string;
  accessLabel: string;
  accessDetailsLabel: string;
  /** Each access level: its name, what it allows, and how a card's footer says it. */
  accessLevels: Record<
    DeviceAccessLevel,
    { label: string; description: string; summary: string }
  >;
  closeLabel: string;
  devices: readonly DeviceSettingsItem[];
  /** The workspace's Cloud VM, in its own section after the person's computers. */
  cloud?: DeviceSettingsItem | undefined;
  cloudLabel?: string;
  children?: ReactNode;
  availableSummary?: ((ready: number, total: number) => string) | undefined;
  loading?: boolean;
  error?: string;
  hasMore?: boolean;
  onGuided(): void;
  onLoadMore(): void;
}

function AgentIcon({ provider }: { provider: string | undefined }) {
  if (provider === "codex") return <OpenAiIcon className="size-4" />;
  if (provider === "claude") return <ClaudeAiIcon className="size-4" />;
  return <CubeIcon className="size-4" />;
}

export function DeviceSettings(props: DeviceSettingsProps) {
  const [accessId, setAccessId] = useState<string>();
  const accessHeading = useId();
  const [adding, setAdding] = useState(false);
  const selected = [...props.devices, ...(props.cloud ? [props.cloud] : [])].find(
    (device) => device.id === accessId
  );
  const card = (device: DeviceSettingsItem) => (
    <article
      key={device.id}
      aria-label={device.name}
      className="comma-device"
      data-slot="device-card"
      data-connected={device.connected}
    >
      <div className="comma-device__header">
        <span className="comma-device__icon">
          <DevicesIcon className="size-5" />
        </span>
        <div className="comma-device__identity">
          <div className="comma-device__name">
            <h3>{device.name}</h3>
            {device.local && (
              <span className="comma-device__local">{props.localLabel}</span>
            )}
          </div>
          {device.description && (
            <p>{[device.description, device.source].filter(Boolean).join(" · ")}</p>
          )}
          {device.path && <p className="comma-device__path">{device.path}</p>}
          {device.tasks && (
            <p className="comma-device__tasks" data-ready={device.tasks.ready}>
              {device.tasks.label}
            </p>
          )}
        </div>
        {/* A row reports the state of its subject at its trailing edge. */}
        <div className="comma-device__trailing">
          <span className="comma-device__connection">
            {device.loading ? (
              <LoadingIndicator label={device.status} />
            ) : (
              <>
                <span className="comma-device__dot" aria-hidden="true" />
                {device.status}
              </>
            )}
          </span>
          {device.actions && (
            <span className="comma-device__menu">{device.actions}</span>
          )}
        </div>
      </div>
      <section className="comma-device__section">
        <div className="comma-device__section-title">
          <h4>
            {device.connected
              ? props.agentsLabel
              : (props.discoveredLabel ?? props.agentsLabel)}
          </h4>
          <div className="comma-device__section-meta">
            <span>
              {props.availableSummary?.(
                device.agents.filter((agent) => agent.ready).length,
                device.agents.length
              ) ??
                `${device.agents.filter((agent) => agent.ready).length} / ${device.agents.length}`}
            </span>
            {device.runtimeCheck && (
              <Button
                className={deviceSettingsButtonClassName}
                hierarchy="secondary-gray"
                size="sm"
                disabled={device.runtimeCheck.disabled || device.runtimeCheck.pending}
                aria-busy={device.runtimeCheck.pending}
                onPress={device.runtimeCheck.onCheck}
              >
                {device.runtimeCheck.label}
              </Button>
            )}
          </div>
        </div>
        {device.runtimeCheck?.error && (
          <p className="comma-device__note" role="alert">
            {device.runtimeCheck.error}
          </p>
        )}
        {device.connected && !device.agents.length && (
          <p className="comma-device__note">{props.emptyAgentsLabel}</p>
        )}
        {Array.from(
          new Set(device.agents.map((agent) => agent.provider ?? agent.name))
        ).map((provider) => {
          const entries = device.agents.filter(
            (agent) => (agent.provider ?? agent.name) === provider
          );
          const first = entries[0]!;
          return (
            <details className="comma-device__agent-group" key={provider}>
              <summary>
                <span className="comma-device__agent-mark" aria-hidden="true">
                  <AgentIcon provider={provider} />
                </span>
                <span className="comma-device__agent-name">
                  {first.name}
                  {entries.length > 1 ? " (" + entries.length + ")" : ""}
                </span>
                <span className="comma-device__agent-status">
                  {entries.every((agent) => agent.status === first.status)
                    ? first.status
                    : entries.filter((agent) => agent.ready).length +
                      " / " +
                      entries.length}
                </span>
                <ChevronRightSmallIcon
                  className="comma-device__expand size-3"
                  aria-hidden="true"
                />
              </summary>
              {entries.map((agent) => (
                <div key={agent.id} className="comma-device__agent">
                  <span className="comma-device__agent-mark" aria-hidden="true">
                    <AgentIcon provider={agent.provider} />
                  </span>
                  <div className="comma-device__agent-info">
                    <span className="comma-device__agent-name">{agent.name}</span>
                    {agent.description && <p>{agent.description}</p>}
                    {agent.details?.map((detail) => (
                      <p key={detail}>{detail}</p>
                    ))}
                  </div>
                  <span
                    className="comma-device__agent-status"
                    data-ready={agent.ready}
                    data-attention={agent.attention === true}
                  >
                    {agent.status}
                  </span>
                </div>
              ))}
            </details>
          );
        })}
      </section>
      {device.content}
      <footer className="comma-device__footer">
        <span>{props.accessLevels[device.access.level].summary}</span>
        <Button
          className="text-xs"
          iconTrailing={<ArrowRightIcon className="size-3" />}
          hierarchy="link-gray"
          size="xs"
          onPress={() => setAccessId(device.id)}
        >
          {props.accessDetailsLabel}
        </Button>
      </footer>
    </article>
  );
  return (
    <div className="comma-devices" data-slot="device-settings">
      <ScrollArea
        className="min-h-0 flex-1"
        viewportClassName="h-full"
        edgeEffect="mask"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        {/* The title is part of the page and scrolls with the list. */}
        <div className="comma-devices__column">
          <header className="comma-devices__header">
            <h1>{props.title}</h1>
            <Button
              className={cx(deviceSettingsButtonClassName, "pl-md")}
              iconLeading={<PlusSmallIcon className="size-4" />}
              hierarchy="secondary-gray"
              size="sm"
              disabled={props.addDisabled === true}
              onPress={() => setAdding(true)}
            >
              {props.addLabel}
            </Button>
            <p>{props.description}</p>
          </header>
          <div className="comma-devices__list">
            <div className="comma-devices__summary">{props.summary}</div>
            {/* A later page shows its progress at the end of the list. */}
            {props.loading && !props.hasMore && (
              <output className="comma-devices__notice">{props.loadingLabel}</output>
            )}
            {props.error && (
              <p className="comma-devices__notice text-error-primary" role="alert">
                {props.error}
              </p>
            )}
            {!props.loading && !props.error && !props.devices.length && (
              <p className="comma-devices__notice">{props.emptyLabel}</p>
            )}
            <div className="comma-devices__grid">{props.devices.map(card)}</div>
          </div>
          {props.cloud && (
            <section className="comma-devices__list" aria-label={props.cloudLabel}>
              <h2 className="comma-devices__summary">{props.cloudLabel}</h2>
              <div className="comma-devices__grid">{card(props.cloud)}</div>
            </section>
          )}
          {props.children}
          <p className="comma-devices__explanation">{props.statusDescription}</p>
          <ScrollAreaLoadMore
            className="comma-devices__pagination"
            failed={props.error !== undefined}
            hasMore={props.hasMore === true}
            loading={props.loading}
            onLoadMore={props.onLoadMore}
          />
        </div>
      </ScrollArea>
      {selected && (
        <Dialog
          isOpen
          showCloseButton
          title={selected.name}
          description={props.accessDetailsLabel}
          onOpenChange={(open) => {
            if (!open) setAccessId(undefined);
          }}
          actions={[
            {
              label: props.closeLabel,
              hierarchy: "secondary-gray",
              onPress: () => setAccessId(undefined),
            },
          ]}
        >
          {selected.metadata?.length ? (
            <ul className="comma-device__facts">
              {selected.metadata.map((fact) => (
                <li key={fact}>{fact}</li>
              ))}
            </ul>
          ) : null}
          <h3 id={accessHeading} className="comma-device__access-title">
            {props.accessLabel}
          </h3>
          <ChoiceList
            name={`device-access-${selected.id}`}
            labelledBy={accessHeading}
            options={(["off", "read", "full"] as const).map((level) => ({
              id: level,
              label: props.accessLevels[level].label,
              description: props.accessLevels[level].description,
            }))}
            value={[selected.access.level]}
            disabled={selected.access.disabled}
            onChange={(next) => {
              const level = next[0] as DeviceAccessLevel | undefined;
              if (level && level !== selected.access.level)
                selected.access.onChange(level);
            }}
          />
          {props.error && (
            <p role="alert" className="mt-lg text-sm text-error-primary">
              {props.error}
            </p>
          )}
        </Dialog>
      )}
      {adding && (
        <Dialog
          isOpen
          showCloseButton
          title={props.addLabel}
          onOpenChange={setAdding}
          actions={[
            {
              label: props.closeLabel,
              hierarchy: "secondary-gray",
              onPress: () => setAdding(false),
            },
          ]}
        >
          <div className="flex flex-col gap-lg">
            {props.addContent}
            <Button
              hierarchy="secondary-gray"
              disabled={props.guidedDisabled === true}
              onPress={() => {
                setAdding(false);
                props.onGuided();
              }}
            >
              {props.guidedLabel}
            </Button>
          </div>
        </Dialog>
      )}
    </div>
  );
}
