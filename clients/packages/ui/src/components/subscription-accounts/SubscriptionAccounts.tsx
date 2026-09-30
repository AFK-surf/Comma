import { useId, type ReactNode } from "react";
import { Button as AriaButton, MenuTrigger } from "react-aria-components";
import { Badge } from "../Badge";
import type { BadgeColor } from "../Badge";
import { Button } from "../Button";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "../menu";
import { Toggle } from "../toggle";
import {
  ReloadIcon,
  ShieldCheckIcon,
  FileIcon,
  TrashCanIcon,
  PlusIcon,
  MoreHorizontalIcon,
  OpenAiIcon,
  ClaudeAiIcon,
} from "../icons";
import { cx, useDelayedFlag } from "../utils";

/**
 * A load resolving faster than this never paints a placeholder — a skeleton on
 * and off inside two frames reads as a flicker, not as feedback.
 */
const skeletonDelayMs = 250;

export type SubscriptionProviderKind = "codex" | "claude";

const ProviderIcon = ({
  kind,
  className,
}: {
  kind: SubscriptionProviderKind;
  className: string;
}) =>
  kind === "codex" ? (
    <OpenAiIcon aria-hidden className={className} />
  ) : (
    <ClaudeAiIcon aria-hidden className={className} />
  );

const actionIcons = {
  quota: ReloadIcon,
  reset: ReloadIcon,
  reauthorize: ShieldCheckIcon,
  replace: FileIcon,
  delete: TrashCanIcon,
} as const;

export interface SubscriptionAccountRow {
  id: string;
  identity: string;
  plan?: string;
  provider: string;
  providerKind: SubscriptionProviderKind;
  /** Account warning. The toggle shows whether the account is enabled. */
  status: string;
  statusTone: BadgeColor;
  enabled: boolean;
  toggleLabel: string;
  actionsLabel: string;
  onToggle: () => void;
  /**
   * The one action that makes an unusable account usable again, offered beside
   * the status that reports the problem instead of only inside the row menu.
   */
  repair?: { label: string; onPress: () => void } | undefined;
  quota: { percent: number | null; label: string; detail: string } | null;
  actions: {
    id: keyof typeof actionIcons;
    label: string;
    destructive?: boolean;
    disabled?: boolean;
    onPress: () => void;
  }[];
}

export interface SubscriptionProviderOption {
  id: SubscriptionProviderKind;
  label: string;
  hint: string;
}

/**
 * A two-way provider choice. Two tiles show both subscriptions and the one in
 * effect at a glance, where a two-item dropdown hid the alternative behind a
 * click and told the reader nothing about what either subscription is.
 */
export function SubscriptionProviderChoice({
  label,
  options,
  value,
  disabled,
  onChange,
}: {
  label: string;
  options: SubscriptionProviderOption[];
  value: SubscriptionProviderKind;
  disabled?: boolean;
  onChange: (value: SubscriptionProviderKind) => void;
}) {
  const name = useId();
  return (
    <fieldset className="min-w-0 border-0 p-0">
      <legend className="mb-sm p-0 text-sm font-medium text-primary">{label}</legend>
      <div className="grid grid-cols-2 gap-md">
        {options.map((option) => {
          const selected = option.id === value;
          return (
            <label
              key={option.id}
              className={cx(
                "flex min-h-11 cursor-pointer items-start gap-sm rounded-lg border-[0.5px] px-lg py-md",
                "transition-colors duration-150 ease-out",
                selected
                  ? "border-brand-solid bg-secondary"
                  : "border-primary bg-primary hover:bg-secondary",
                disabled && "cursor-not-allowed opacity-70"
              )}
            >
              <input
                type="radio"
                name={name}
                value={option.id}
                checked={selected}
                disabled={disabled}
                aria-label={option.label}
                className="mt-xxs size-4 shrink-0 accent-current"
                onChange={() => onChange(option.id)}
              />
              <span className="min-w-0">
                <span className="flex items-center gap-xs text-sm font-medium text-primary">
                  <ProviderIcon kind={option.id} className="size-4 shrink-0" />
                  {option.label}
                </span>
                <span className="mt-xxs block text-pretty text-xs text-tertiary">
                  {option.hint}
                </span>
              </span>
            </label>
          );
        })}
      </div>
    </fieldset>
  );
}

export interface SubscriptionStep {
  text: string;
  /** Control that carries out this step, kept beside the instruction. */
  action?: ReactNode;
}

/** Numbered instructions for a flow the user has to finish outside the app. */
export function SubscriptionSteps({ steps }: { steps: SubscriptionStep[] }) {
  return (
    <ol className="m-0 flex list-none flex-col gap-lg p-0">
      {steps.map((step, index) => (
        <li key={step.text} className="flex gap-md">
          <span
            aria-hidden
            className="mt-xxs flex size-5 shrink-0 items-center justify-center rounded-full bg-quaternary text-xs font-medium tabular-nums text-secondary"
          >
            {index + 1}
          </span>
          <span className="flex min-w-0 flex-col items-start gap-md">
            <span className="text-pretty text-sm text-secondary">{step.text}</span>
            {step.action}
          </span>
        </li>
      ))}
    </ol>
  );
}

const QuotaCell = ({
  quota,
  enabled,
  unknownLabel,
}: {
  quota: SubscriptionAccountRow["quota"];
  enabled: boolean;
  unknownLabel: string;
}) => {
  if (!quota) return <span className="text-xs text-tertiary">{unknownLabel}</span>;
  const caption = [quota.label, quota.detail].filter(Boolean).join(" · ");
  return (
    <>
      <div className="flex items-center gap-sm">
        {quota.percent !== null ? (
          <progress
            aria-label={quota.label}
            value={Math.max(0, Math.min(100, quota.percent))}
            max={100}
            className={cx(
              "h-1.5 min-w-0 flex-1 appearance-none [&::-webkit-progress-bar]:rounded-full [&::-webkit-progress-bar]:bg-tertiary [&::-webkit-progress-value]:rounded-full [&::-moz-progress-bar]:rounded-full",
              enabled
                ? "[&::-webkit-progress-value]:bg-brand-solid [&::-moz-progress-bar]:bg-brand-solid"
                : "[&::-webkit-progress-value]:bg-quaternary [&::-moz-progress-bar]:bg-quaternary"
            )}
          />
        ) : null}
        <span
          className={cx(
            "shrink-0 text-sm tabular-nums text-primary",
            quota.percent !== null && "w-[5ch] text-left"
          )}
        >
          {quota.percent === null ? unknownLabel : `${quota.percent}%`}
        </span>
      </div>
      {caption ? (
        <p className="mt-xxs text-pretty text-xs text-tertiary">{caption}</p>
      ) : null}
    </>
  );
};

const actionItem = (action: SubscriptionAccountRow["actions"][number]) => {
  const Icon = actionIcons[action.id];
  return (
    <MenuItem
      key={action.id}
      id={action.id}
      icon={<Icon />}
      textValue={action.label}
      onAction={action.onPress}
      isDisabled={!!action.disabled}
      {...(action.destructive ? { tone: "destructive" as const } : {})}
    >
      {action.label}
    </MenuItem>
  );
};

/**
 * One labelled menu per account. The row used to carry five unlabelled icon
 * buttons whose meaning lived only in a tooltip, with delete a pixel away from
 * refresh; naming each action and setting deletion apart is the whole point.
 */
const AccountActionsMenu = ({
  row,
  busy,
}: {
  row: SubscriptionAccountRow;
  busy: boolean;
}) => {
  const routine = row.actions.filter((action) => !action.destructive);
  const destructive = row.actions.filter((action) => action.destructive);
  return (
    <MenuTrigger>
      <AriaButton
        aria-label={row.actionsLabel}
        isDisabled={busy}
        className="inline-flex size-10 items-center justify-center rounded-sm text-tertiary outline-none transition-colors duration-150 ease-out hover:bg-secondary hover:text-secondary focus-visible:ring-2 disabled:opacity-50 aria-expanded:bg-secondary"
      >
        <MoreHorizontalIcon className="size-4" />
      </AriaButton>
      <MenuPopover placement="bottom end">
        <Menu aria-label={row.actionsLabel}>
          {routine.map(actionItem)}
          {destructive.length > 0 && <MenuSeparator />}
          {destructive.map(actionItem)}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
};

export function SubscriptionAccounts({
  rows,
  busy,
  loaded,
  error,
  labels,
  onImport,
  onConnect,
  onRefresh,
  onNext,
}: {
  rows: SubscriptionAccountRow[];
  busy: boolean;
  loaded: boolean;
  error: string;
  labels: {
    table: string;
    identity: string;
    remaining: string;
    actions: string;
    enabled: string;
    empty: string;
    emptyHint: string;
    loading: string;
    refresh: string;
    unknownQuota: string;
    import: string;
    connect: string;
    next: string;
  };
  onImport: () => void;
  onConnect: () => void;
  onRefresh: () => void;
  onNext?: (() => void) | undefined;
}) {
  // A load that never resolved and reported an error: the region shows the
  // failure, and keeps showing it while a retry runs.
  const failed = !loaded && !!error;
  const pending = useDelayedFlag(!loaded && !failed && busy, skeletonDelayMs);
  return (
    <div className="flex w-full min-w-0 flex-col gap-lg">
      {error ? (
        <p role="alert" className="text-pretty text-sm text-error-primary">
          {error}
        </p>
      ) : null}
      {failed ? (
        // A failed load keeps this exact box while the retry runs: swapping
        // it for a taller skeleton and back is two reflows in one keypress.
        <div className="flex">
          <Button
            size="sm"
            hierarchy="secondary-gray"
            iconLeading={<ReloadIcon />}
            disabled={busy}
            onPress={onRefresh}
          >
            {labels.refresh}
          </Button>
        </div>
      ) : pending ? (
        <div aria-busy="true" className="flex flex-col gap-md">
          <output className="sr-only">{labels.loading}</output>
          {[0, 1].map((index) => (
            <div
              aria-hidden
              key={index}
              className="h-14 rounded-lg bg-secondary motion-safe:animate-pulse"
            />
          ))}
        </div>
      ) : !loaded ? null : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-xs rounded-lg border-[0.5px] border-primary bg-secondary px-xl py-4xl text-center">
          <p className="text-balance text-sm font-medium text-primary">
            {labels.empty}
          </p>
          <p className="max-w-[42ch] text-pretty text-sm text-tertiary">
            {labels.emptyHint}
          </p>
          <div className="mt-md flex flex-wrap justify-center gap-md">
            <Button size="sm" iconLeading={<PlusIcon />} onPress={onConnect}>
              {labels.connect}
            </Button>
            <Button size="sm" hierarchy="secondary-gray" onPress={onImport}>
              {labels.import}
            </Button>
          </div>
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border-[0.5px] border-primary">
          <table
            aria-label={labels.table}
            aria-busy={busy}
            className="w-full table-fixed border-collapse text-left text-sm"
          >
            <thead className="bg-secondary text-xs text-tertiary">
              <tr>
                <th scope="col" className="w-12 px-md py-md">
                  <span className="sr-only">{labels.enabled}</span>
                </th>
                <th scope="col" className="px-md py-md font-medium">
                  {labels.identity}
                </th>
                <th scope="col" className="w-[38%] px-md py-md font-medium">
                  {labels.remaining}
                </th>
                <th scope="col" className="w-14 px-md py-md">
                  <span className="sr-only">{labels.actions}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr
                  key={row.id}
                  className={cx(
                    "border-t-[0.5px] border-primary",
                    row.enabled ? "hover:bg-secondary" : "bg-secondary"
                  )}
                >
                  <td className="px-md py-lg align-middle">
                    <Toggle
                      size="sm"
                      aria-label={row.toggleLabel}
                      checked={row.enabled}
                      disabled={busy}
                      onChange={row.onToggle}
                    />
                  </td>
                  <th
                    scope="row"
                    aria-label={[row.identity, row.provider, row.plan, row.status]
                      .filter(Boolean)
                      .join(", ")}
                    className="min-w-0 px-md py-lg align-middle font-normal"
                  >
                    <div className="grid min-w-0 grid-cols-[1.25rem_minmax(0,1fr)] items-center gap-x-sm gap-y-xxs">
                      <span
                        className="row-span-2 self-center text-tertiary"
                        title={row.provider}
                      >
                        <ProviderIcon kind={row.providerKind} className="size-5" />
                        <span className="sr-only">{row.provider}</span>
                      </span>
                      <p
                        className="truncate font-medium text-primary"
                        title={row.identity}
                      >
                        {row.identity}
                      </p>
                      <span className="col-start-2 flex min-w-0 flex-wrap items-center gap-x-sm gap-y-xxs text-xs text-tertiary">
                        {row.plan ? (
                          <span
                            className="min-w-0 truncate text-secondary"
                            title={row.plan}
                          >
                            {row.plan}
                          </span>
                        ) : null}
                        {row.status ? (
                          <Badge
                            className="border-0 bg-transparent p-0 font-normal text-tertiary"
                            color={row.statusTone}
                            dot
                            size="sm"
                          >
                            {row.status}
                          </Badge>
                        ) : null}
                        {row.repair ? (
                          <Button
                            className="h-auto min-h-0 p-0 text-xs"
                            hierarchy="link-color"
                            size="xs"
                            disabled={busy}
                            onPress={row.repair.onPress}
                          >
                            {row.repair.label}
                          </Button>
                        ) : null}
                      </span>
                    </div>
                  </th>
                  <td className="px-md py-lg align-middle">
                    <QuotaCell
                      quota={row.quota}
                      enabled={row.enabled}
                      unknownLabel={labels.unknownQuota}
                    />
                  </td>
                  <td className="px-md py-lg align-middle">
                    <div className="flex justify-end">
                      <AccountActionsMenu row={row} busy={busy} />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {loaded ? (
        <div className="flex flex-wrap items-center gap-md">
          {rows.length > 0 && (
            <>
              <Button
                size="sm"
                hierarchy="secondary-gray"
                iconLeading={<PlusIcon />}
                disabled={busy}
                onPress={onConnect}
              >
                {labels.connect}
              </Button>
              <Button
                size="sm"
                hierarchy="tertiary-gray"
                disabled={busy}
                onPress={onImport}
              >
                {labels.import}
              </Button>
            </>
          )}
          <Button
            className="ml-auto"
            size="sm"
            hierarchy="tertiary-gray"
            iconLeading={<ReloadIcon />}
            disabled={busy}
            onPress={onRefresh}
          >
            {labels.refresh}
          </Button>
          {onNext ? (
            <Button
              size="sm"
              hierarchy="tertiary-gray"
              disabled={busy}
              onPress={onNext}
            >
              {labels.next}
            </Button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export function SubscriptionCredentialInput({
  busy,
  value,
  onChange,
  onFile,
  fileName,
  fileLabel,
  fileSource,
  jsonLabel,
}: {
  busy: boolean;
  value: string;
  onChange: (value: string) => void;
  onFile: (file: File) => void;
  fileName: string;
  fileLabel: string;
  /** Where the provider's CLI writes the file, so the reader can go find it. */
  fileSource: ReactNode;
  jsonLabel: string;
}) {
  return (
    // The two ways in are alternatives, so they stack rather than share a row.
    <div className="flex w-full min-w-0 flex-col gap-lg">
      <label className="relative block cursor-pointer rounded-lg border border-dashed border-primary bg-secondary p-3xl text-center focus-within:ring-2">
        <span className="block text-sm font-medium text-primary">
          {fileName || fileLabel}
        </span>
        <span className="mt-xs block text-xs text-tertiary">{fileSource}</span>
        <input
          type="file"
          aria-label={fileLabel}
          accept=".json,application/json"
          disabled={busy}
          className="absolute inset-0 h-full w-full cursor-pointer opacity-0"
          onChange={(event) => {
            const file = event.target.files?.[0];
            event.target.value = "";
            if (file) onFile(file);
          }}
        />
      </label>
      <label className="block text-sm text-primary">
        {jsonLabel}
        <textarea
          aria-label={jsonLabel}
          rows={4}
          spellCheck={false}
          autoComplete="off"
          disabled={busy}
          value={value}
          onChange={(event) => onChange(event.target.value)}
          className="mt-sm block w-full resize-none rounded-lg border border-primary bg-primary px-lg py-md font-mono text-xs text-primary"
        />
      </label>
    </div>
  );
}
