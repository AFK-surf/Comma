import { useState, type ReactNode } from "react";
import { Button } from "../Button";
import { Dialog } from "../dialog";
import { SettingsControlView } from "../settings-panel";
import {
  DevicesIcon,
  PlusSmallIcon,
  OpenAiIcon,
  ClaudeAiIcon,
  CubeIcon,
  LoadingCircleIcon,
  MoreHorizontalIcon,
  ShieldCheckIcon,
} from "../icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "../menu";
import { ScrollArea, ScrollAreaLoadMore } from "../scroll-area";
import { LoadingIndicator } from "../LoadingIndicator";
import { cx } from "../utils";
import {
  deviceSettingsButtonClassName,
  deviceSettingsMenuClassName,
} from "./DeviceSettingsContent";

/** How far the workspace's agents may go on a computer. */
export type DeviceAccessLevel = "off" | "read" | "full";

export interface DeviceSettingsAgent {
  id: string;
  name: string;
  provider?: string;
  /** Shown under the name while it is not ready (sign in required, not found), and always on a row with `source`. */
  status: string;
  ready: boolean;
  /** The person has to act on it (sign in). */
  attention?: boolean;
  /** Version, sign-in and last check, each a label and its value: shown in the computer's details only. */
  details?: readonly (readonly [string, string])[];
  /** What its runtime said of itself: shown in the details only. */
  note?: string | undefined;
  /** Not signed in: a button that signs it in, before the source; `busy` while its page waits in the browser. */
  signIn?: {
    label: string;
    pending: boolean;
    busy: boolean;
    onPress(): void;
    error?: string | undefined;
  };
  /**
   * Which account it runs on, on this computer: a dropdown at the row's trailing edge, the same control as Access.
   * No `value` shows the placeholder: nothing is chosen, and nothing is chosen for the person.
   */
  source?: {
    label: string;
    placeholder: string;
    value?: string | undefined;
    disabled: boolean;
    items: readonly { id: string; label: string }[];
    onChange(id: string): void;
  };
  /** A text link after the status line, to fix what it says (add a workspace account). */
  link?: { label: string; onPress(): void };
}

export interface DeviceSettingsItem {
  id: string;
  name: string;
  /** Its connection, named by the indicator while it connects. */
  status: string;
  loading?: boolean;
  connected: boolean;
  local?: boolean;
  /** A Comma device: its own icon, and no agents of its own. */
  commaDevice?: boolean;
  /** Hardware, source and identity, each a label and its value: shown in the details dialog only. */
  metadata?: readonly (readonly [string, string])[] | undefined;
  /** The overflow menu's own entries after Details (rename, remove, settings). */
  menu?: {
    id: string;
    label: string;
    destructive?: boolean;
    onAction(): void;
  }[];
  /** What keeps it from Tasks, over its agents. */
  notice?: string | undefined;
  /** The agents' settings could not be read or saved: a note in the agents section, with its retry. */
  agentsProblem?: { label: string; retryLabel: string; onRetry(): void } | undefined;
  /** The computer's sandbox, after its agents and access, in a part of the card of its own. */
  content?: ReactNode;
  /** A runtime check that is running or failed; a check that passed is not shown. */
  runtimeCheck?:
    | {
        label: string;
        pending: boolean;
        disabled: boolean;
        error?: string | undefined;
        onCheck(): void;
      }
    | undefined;
  agents: DeviceSettingsAgent[];
  access: {
    level: DeviceAccessLevel;
    disabled: boolean;
    onChange(level: DeviceAccessLevel): void;
  };
}

export interface DeviceSettingsProps {
  title: string;
  addLabel: string;
  /**
   * What the Add dialog shows: the install command for another computer, and
   * other ways to add one. A function gets the dialog's close, for an option
   * that continues in a dialog of its own.
   */
  addContent?: ReactNode | ((close: () => void) => ReactNode);
  /** Asking the Router to help add one instead. */
  guidedLabel: string;
  addDisabled?: boolean;
  guidedDisabled?: boolean;
  localLabel: string;
  loadingLabel: string;
  emptyLabel: string;
  agentsLabel: string;
  emptyAgentsLabel: string;
  accessLabel: string;
  detailsLabel: string;
  /** The details' heading over the computer's own facts. */
  deviceLabel: string;
  moreLabel(name: string): string;
  /** Offline computers, folded under the online ones. */
  offlineLabel(count: number): string;
  /** Each access level: its name and, in the menu, what it allows. */
  accessLevels: Record<DeviceAccessLevel, { label: string; description: string }>;
  closeLabel: string;
  devices: readonly DeviceSettingsItem[];
  /** The workspace's Cloud VM, in its own section after the person's computers. */
  cloud?: DeviceSettingsItem | undefined;
  cloudLabel?: string;
  children?: ReactNode;
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

/** One row per agent: a computer with two Codex installs shows Codex once, with the best of their states. */
function agentRows(agents: readonly DeviceSettingsAgent[]) {
  const rows = new Map<string, DeviceSettingsAgent>();
  for (const agent of agents) {
    const key = agent.provider ?? agent.name;
    const held = rows.get(key);
    if (!held || (!held.ready && (agent.ready || (agent.attention && !held.attention))))
      rows.set(key, agent);
  }
  return [...rows.values()];
}

function Facts({
  rows,
  className,
}: {
  rows: readonly (readonly [string, string])[];
  className?: string;
}) {
  return (
    <dl className={cx("comma-device-details__list", className)}>
      {rows.map(([label, value]) => (
        <div key={label} className="comma-device-details__row">
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function AgentRow({ agent }: { agent: DeviceSettingsAgent }) {
  const signIn = agent.signIn;
  const source = agent.source;
  // Under the name only what keeps it from working: a failed sign-in, or a problem with an agent in use. A row with a
  // source always says which account it uses.
  const below = signIn?.error
    ? signIn.error
    : (source || !agent.ready) && agent.status
      ? agent.status
      : undefined;
  return (
    <div className="comma-device__agent">
      <span className="comma-device__agent-mark" aria-hidden="true">
        <AgentIcon provider={agent.provider} />
      </span>
      <span className="comma-device__agent-identity">
        <span className="comma-device__agent-name">{agent.name}</span>
        {below && (
          <span
            className="comma-device__agent-status"
            data-attention={agent.attention === true || signIn?.error !== undefined}
            {...(signIn?.error ? { role: "alert" } : {})}
          >
            {below}
            {agent.link && (
              <>
                {" "}
                <Button
                  className="text-xs"
                  hierarchy="link-gray"
                  size="xs"
                  onPress={agent.link.onPress}
                >
                  {agent.link.label}
                </Button>
              </>
            )}
          </span>
        )}
      </span>
      {signIn && (
        <Button
          className={deviceSettingsButtonClassName}
          hierarchy="secondary-gray"
          size="sm"
          disabled={signIn.pending}
          aria-busy={signIn.busy}
          {...(signIn.busy
            ? { iconLeading: <LoadingCircleIcon className="size-4 animate-spin" /> }
            : {})}
          onPress={signIn.onPress}
        >
          {signIn.label}
        </Button>
      )}
      {source && (
        <SettingsControlView
          label={source.label}
          control={{
            type: "dropdown",
            ariaLabel: source.label,
            disabled: source.disabled,
            placeholder: source.placeholder,
            ...(source.value === undefined ? {} : { value: source.value }),
            items: source.items.map((item) => ({ id: item.id, label: item.label })),
            onChange: (id) => {
              if (id !== source.value) source.onChange(id);
            },
          }}
        />
      )}
    </div>
  );
}

export function DeviceSettings(props: DeviceSettingsProps) {
  const [detailsId, setDetailsId] = useState<string>();
  const [adding, setAdding] = useState(false);
  const all = [...props.devices, ...(props.cloud ? [props.cloud] : [])];
  const selected = all.find((device) => device.id === detailsId);
  // The local computer is always open; others fold to one line while offline.
  const open = props.devices.filter((device) => device.local || device.connected);
  const offline = props.devices.filter((device) => !device.local && !device.connected);
  const header = (device: DeviceSettingsItem) => (
    <div className="comma-device__header">
      <span className="comma-device__icon">
        {device.commaDevice ? (
          <CubeIcon className="size-5" />
        ) : (
          <DevicesIcon className="size-5" />
        )}
      </span>
      <div className="comma-device__identity">
        <div className="comma-device__name">
          <h3>{device.name}</h3>
          {device.local && (
            <span className="comma-device__local">{props.localLabel}</span>
          )}
        </div>
      </div>
      <div className="comma-device__trailing">
        {device.loading && (
          <span className="comma-device__connection">
            <LoadingIndicator label={device.status} />
          </span>
        )}
        <span className="comma-device__menu">
          <MenuTrigger>
            <Button
              className={deviceSettingsMenuClassName}
              hierarchy="tertiary-gray"
              size="xs"
              iconOnly
              iconLeading={<MoreHorizontalIcon />}
              aria-label={props.moreLabel(device.name)}
            />
            <MenuPopover placement="bottom end">
              <Menu aria-label={props.moreLabel(device.name)}>
                <MenuItem id="details" onAction={() => setDetailsId(device.id)}>
                  {props.detailsLabel}
                </MenuItem>
                {(device.menu ?? []).map((entry) => (
                  <MenuItem
                    key={entry.id}
                    id={entry.id}
                    {...(entry.destructive ? { tone: "destructive" as const } : {})}
                    onAction={entry.onAction}
                  >
                    {entry.label}
                  </MenuItem>
                ))}
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </span>
      </div>
    </div>
  );
  const card = (device: DeviceSettingsItem) => (
    <article
      key={device.id}
      aria-label={device.name}
      className="comma-device"
      data-slot="device-card"
      data-connected={device.connected}
    >
      {header(device)}
      {!device.commaDevice && (
        <section className="comma-device__section" aria-label={props.agentsLabel}>
          {device.runtimeCheck?.pending && (
            <p className="comma-device__note">{device.runtimeCheck.label}</p>
          )}
          {device.runtimeCheck?.error && (
            <p className="comma-device__note" role="alert">
              {device.runtimeCheck.error}{" "}
              <Button
                className="text-xs"
                hierarchy="link-gray"
                size="xs"
                disabled={device.runtimeCheck.disabled}
                onPress={device.runtimeCheck.onCheck}
              >
                {device.runtimeCheck.label}
              </Button>
            </p>
          )}
          {device.notice && (
            <p className="comma-device__note" data-attention="true">
              {device.notice}
            </p>
          )}
          {/* As a failed runtime check: a note in this section, with its retry. */}
          {device.agentsProblem && (
            <p className="comma-device__note" role="alert">
              {device.agentsProblem.label}{" "}
              <Button
                className="text-xs"
                hierarchy="link-gray"
                size="xs"
                onPress={device.agentsProblem.onRetry}
              >
                {device.agentsProblem.retryLabel}
              </Button>
            </p>
          )}
          {device.connected && !device.agents.length && (
            <p className="comma-device__note">{props.emptyAgentsLabel}</p>
          )}
          {/* A row says nothing about an agent that works; only what keeps it from working. */}
          {agentRows(device.agents).map((agent) => (
            <AgentRow key={agent.id} agent={agent} />
          ))}
        </section>
      )}
      {/* Agents and access are the station's; the sandbox (the VMM) is a part of its own, after a divider. */}
      <div className="comma-device__agent comma-device__access">
        <span className="comma-device__agent-mark" aria-hidden="true">
          <ShieldCheckIcon className="size-4" />
        </span>
        <span className="comma-device__agent-name">{props.accessLabel}</span>
        {/* The same control as a settings row's (Language, say). */}
        <SettingsControlView
          label={props.accessLabel}
          control={{
            type: "dropdown",
            ariaLabel: `${device.name} ${props.accessLabel}`,
            disabled: device.access.disabled,
            value: device.access.level,
            items: (["off", "read", "full"] as const).map((level) => ({
              id: level,
              label: props.accessLevels[level].label,
              subtitle: props.accessLevels[level].description,
            })),
            onChange: (id) => {
              const level = id as DeviceAccessLevel;
              if (level !== device.access.level) device.access.onChange(level);
            },
          }}
        />
      </div>
      {device.content && <div className="comma-device__sandbox">{device.content}</div>}
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
          </header>
          <div className="comma-devices__list">
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
            <div className="comma-devices__grid">{open.map(card)}</div>
          </div>
          {offline.length > 0 && (
            <section
              className="comma-devices__list"
              aria-label={props.offlineLabel(offline.length)}
            >
              <h2 className="comma-devices__summary">
                {props.offlineLabel(offline.length)}
              </h2>
              <div className="comma-devices__offline">
                {offline.map((device) => (
                  <article
                    key={device.id}
                    aria-label={device.name}
                    className="comma-device__row"
                    data-slot="device-card"
                    data-connected={false}
                  >
                    {header(device)}
                  </article>
                ))}
              </div>
            </section>
          )}
          {props.cloud && (
            <section className="comma-devices__list" aria-label={props.cloudLabel}>
              <h2 className="comma-devices__summary">{props.cloudLabel}</h2>
              <div className="comma-devices__grid">{card(props.cloud)}</div>
            </section>
          )}
          {props.children}
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
          onOpenChange={(isOpen) => {
            if (!isOpen) setDetailsId(undefined);
          }}
        >
          {/* Each fact a label and its value; the agents one list each, under their name. */}
          <div className="comma-device-details">
            {selected.metadata?.length ? (
              <section aria-label={props.deviceLabel}>
                <h3>{props.deviceLabel}</h3>
                <Facts
                  rows={selected.metadata}
                  className="comma-device-details__facts"
                />
              </section>
            ) : null}
            {selected.agents.length > 0 && (
              <section aria-label={props.agentsLabel}>
                <h3>{props.agentsLabel}</h3>
                {selected.agents.map((agent) => (
                  <div key={agent.id} className="comma-device-details__group">
                    <div className="comma-device-details__head">
                      <span>{agent.name}</span>
                      {agent.status && (
                        <span className="comma-device-details__status">
                          {agent.status}
                        </span>
                      )}
                    </div>
                    {agent.note && (
                      <p className="comma-device-details__note">{agent.note}</p>
                    )}
                    {agent.details?.length ? <Facts rows={agent.details} /> : null}
                  </div>
                ))}
              </section>
            )}
          </div>
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
            {typeof props.addContent === "function"
              ? props.addContent(() => setAdding(false))
              : props.addContent}
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
