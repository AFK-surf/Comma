import { useState, type ReactNode } from "react";
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
import { ScrollArea, ScrollAreaLoadMore } from "../scroll-area";
import { Toggle } from "../toggle";
import { LoadingIndicator } from "../LoadingIndicator";

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
    allowed: boolean;
    disabled: boolean;
    description: string;
    onChange(allow: boolean): void;
  };
}

export interface DeviceSettingsProps {
  title: string;
  description: string;
  statusDescription: string;
  summary: string;
  addLabel: string;
  guidedLabel: string;
  manualLabel: string;
  addDisabled?: boolean;
  manualDisabled?: boolean;
  localLabel: string;
  loadingLabel: string;
  emptyLabel: string;
  agentsLabel: string;
  discoveredLabel?: string;
  emptyAgentsLabel: string;
  accessLabel: string;
  accessDetailsLabel: string;
  readOnlyLabel: string;
  operationsLabel: string;
  closeLabel: string;
  devices: readonly DeviceSettingsItem[];
  loading?: boolean;
  error?: string;
  hasMore?: boolean;
  onAdd(): void;
  onManual(): void;
  onLoadMore(): void;
}

function AgentIcon({ provider }: { provider: string | undefined }) {
  if (provider === "codex") return <OpenAiIcon className="size-4" />;
  if (provider === "claude") return <ClaudeAiIcon className="size-4" />;
  return <CubeIcon className="size-4" />;
}

export function DeviceSettings(props: DeviceSettingsProps) {
  const [accessId, setAccessId] = useState<string>();
  const [adding, setAdding] = useState(false);
  const selected = props.devices.find((device) => device.id === accessId);
  return (
    <div className="comma-devices" data-slot="device-settings">
      <div className="comma-devices__content">
        <header className="comma-devices__header">
          <div>
            <h1>{props.title}</h1>
            <p>{props.description}</p>
          </div>
          <Button
            className="comma-devices__connect"
            iconLeading={<PlusSmallIcon className="size-4" />}
            hierarchy="secondary-gray"
            size="sm"
            disabled={props.addDisabled === true && props.manualDisabled === true}
            onPress={() => setAdding(true)}
          >
            {props.addLabel}
          </Button>
        </header>
        <ScrollArea
          className="min-h-0 flex-1"
          viewportClassName="h-full"
          edgeEffect="mask"
          orientation="vertical"
          scrollbarVisibility="hover"
        >
          <div className="comma-devices__scroll-content">
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
            <div className="comma-devices__grid">
              {props.devices.map((device) => (
                <article
                  key={device.id}
                  aria-label={device.name}
                  className="comma-device"
                  data-slot="device-card"
                  data-connected={device.connected}
                >
                  <div className="comma-device__header">
                    <span className="comma-device__icon">
                      <DevicesIcon className="size-6" />
                    </span>
                    <div className="comma-device__identity">
                      <div className="comma-device__name">
                        <h3>{device.name}</h3>
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
                        {device.local && (
                          <span className="comma-device__local">
                            {props.localLabel}
                          </span>
                        )}
                      </div>
                      {device.description && (
                        <p>
                          {[device.description, device.source]
                            .filter(Boolean)
                            .join(" · ")}
                        </p>
                      )}
                    </div>
                    <div className="comma-device__menu">{device.actions}</div>
                  </div>
                  <div className="comma-device__agents">
                    <div className="comma-device__section-title">
                      <h4>
                        {device.connected
                          ? props.agentsLabel
                          : (props.discoveredLabel ?? props.agentsLabel)}
                      </h4>
                      <span>
                        {device.agents.filter((agent) => agent.ready).length} /{" "}
                        {device.agents.length}
                      </span>
                    </div>
                    {device.connected && !device.agents.length && (
                      <p className="comma-device__empty">{props.emptyAgentsLabel}</p>
                    )}
                    {Array.from(
                      new Set(
                        device.agents.map((agent) => agent.provider ?? agent.name)
                      )
                    ).map((provider) => {
                      const entries = device.agents.filter(
                        (agent) => (agent.provider ?? agent.name) === provider
                      );
                      const first = entries[0]!;
                      return (
                        <details className="comma-device__agent-group" key={provider}>
                          <summary>
                            <span
                              className="comma-device__agent-mark"
                              aria-hidden="true"
                            >
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
                              <span
                                className="comma-device__agent-mark"
                                aria-hidden="true"
                              >
                                <AgentIcon provider={agent.provider} />
                              </span>
                              <div className="comma-device__agent-info">
                                <span className="comma-device__agent-name">
                                  {agent.name}
                                </span>
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
                  </div>
                  <footer className="comma-device__footer">
                    <span>
                      {device.access.allowed
                        ? props.operationsLabel
                        : props.readOnlyLabel}
                    </span>
                    <Button
                      className="comma-device__details"
                      iconTrailing={<ArrowRightIcon className="size-3" />}
                      hierarchy="link-gray"
                      size="sm"
                      onPress={() => setAccessId(device.id)}
                    >
                      {props.accessDetailsLabel}
                    </Button>
                  </footer>
                </article>
              ))}
            </div>
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
      </div>
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
          <Toggle
            size="sm"
            label={props.accessLabel}
            hint={selected.access.description}
            checked={selected.access.allowed}
            disabled={selected.access.disabled}
            onChange={(event) => selected.access.onChange(event.target.checked)}
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
            <Button
              hierarchy="secondary-gray"
              disabled={props.addDisabled === true}
              onPress={() => {
                setAdding(false);
                props.onAdd();
              }}
            >
              {props.guidedLabel}
            </Button>
            <Button
              hierarchy="secondary-gray"
              disabled={props.manualDisabled === true}
              onPress={() => {
                setAdding(false);
                props.onManual();
              }}
            >
              {props.manualLabel}
            </Button>
          </div>
        </Dialog>
      )}
    </div>
  );
}
