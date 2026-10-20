import { Checkbox } from "@comma/ui/components/checkbox";
import { Dropdown, type DropdownItem } from "@comma/ui/components/dropdown";
import { ChevronRightSmallIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import type { BftModelOption, BftSettingsModels } from "./api";
import { messages } from "./messages";
import { AccountsSection } from "./ModelAccounts";
import { useApi } from "./resource";
import {
  FieldError,
  FormActions,
  FormSection,
  SaveButton,
  Unavailable,
  useWrite,
} from "./settingsForm";

const t = messages.settings.models;

// Dropdown ids cannot be null; this one stands for "follow the platform".
// Option keys are `kind:...`, so it cannot collide with one.
const platform = "platform";

type Role = "task" | "router";
type Mode = "all" | "selected";

const modes: { value: Mode; label: string; hint: string }[] = [
  { value: "all", label: t.modeAll, hint: t.modeAllHint },
  { value: "selected", label: t.modeSelected, hint: t.modeSelectedHint },
];

const fieldOf: Record<Role, "default_task_model" | "default_router_model"> = {
  task: "default_task_model",
  router: "default_router_model",
};

const keysOf = (options: BftModelOption[]) => options.map((option) => option.key);

const defaultsOf = (data: BftSettingsModels): Record<Role, string | null> => ({
  task: data.default_task_model?.key ?? null,
  router: data.default_router_model?.key ?? null,
});

/** Every option the page knows, by key, to send its choice back. */
const optionsByKey = (data: BftSettingsModels) => {
  const byKey = new Map<string, BftModelOption>();
  const add = (option: BftModelOption | null) => {
    if (option && !byKey.has(option.key)) byKey.set(option.key, option);
  };
  data.catalog.forEach(add);
  data.allowed_models.forEach(add);
  data.default_options.task.forEach(add);
  data.default_options.router.forEach(add);
  add(data.default_task_model);
  add(data.default_router_model);
  return byKey;
};

const planName = (plan: string) =>
  t.accounts.providers[plan] ?? plan.charAt(0).toUpperCase() + plan.slice(1);

const names = (list: string[]) => list.join(", ");

/**
 * What can serve a choice, in a few words. A pay-per-use choice names the
 * key sources that may serve it; the account pool picks one per request.
 */
const sourceOf = (option: BftModelOption) => {
  switch (option.served_by) {
    case "subscription":
      return t.sources.subscription(names(option.plans.map(planName)));
    case "api_key":
      return t.sources.apiKey(names(option.key_sources));
    case "platform":
      return t.sources.platform;
    default:
      return t.sources.none;
  }
};

// Search ignores case, spaces and punctuation, and splits letters from
// digits, so "gpt6 astra", "astra6" and "sol 6.1" all find their models.
const squash = (text: string) => text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");

const termsOf = (query: string) =>
  query
    .toLowerCase()
    .split(/\s+/)
    .flatMap((word) => squash(word).match(/\p{L}+|\p{N}+/gu) ?? []);

const matches = (option: BftModelOption, terms: string[]) => {
  const text = squash(
    [
      option.label,
      option.vendor ?? "",
      String(option.choice.model ?? ""),
      option.served_by ? sourceOf(option) : "",
      ...option.key_sources,
    ].join(" ")
  );
  return terms.every((term) => text.includes(term));
};

/** What a row adds to its model's name: other sources, or a pay-per-use choice no key serves now. */
const hintOf = (option: BftModelOption): { hint?: string } =>
  option.served_by === "subscription" && option.key_sources.length > 0
    ? { hint: t.groups.alsoPaid(names(option.key_sources)) }
    : option.served_by === null && option.choice.allow_paid === true
      ? { hint: t.sources.apiKey(names(option.key_sources)) }
      : {};

interface Group {
  id: string;
  title: string;
  note?: string;
  options: BftModelOption[];
  /** Its models cannot be chosen: no account serves them. */
  muted?: boolean;
}

/** The catalog's models by what serves them; platform models stand apart. */
const groupsOf = (data: BftSettingsModels): { served: Group[]; unserved: Group } => {
  const models = data.catalog.filter((option) => option.choice.kind === "catalog");
  const unserved: Group = {
    id: "unserved",
    title: t.groups.unserved,
    note: t.groups.unservedNote,
    options: [],
    muted: true,
  };
  if (data.servable_status !== "ok")
    return {
      served: [{ id: "catalog", title: t.groups.catalog, options: models }],
      unserved,
    };
  const plans = new Map<string, Group>();
  // Pay-per-use choices by the key sources that may serve them.
  const keys = new Map<string, Group>();
  for (const option of models) {
    if (option.served_by === "subscription") {
      // A model of several plans is listed under the first.
      const plan = option.plans[0] ?? "subscription";
      const group = plans.get(plan) ?? {
        id: `plan:${plan}`,
        title: t.groups.subscription(planName(plan)),
        note: t.groups.subscriptionNote,
        options: [],
      };
      group.options.push(option);
      plans.set(plan, group);
    } else if (option.served_by === "api_key") {
      const sources = names(option.key_sources);
      const group = keys.get(sources) ?? {
        id: `paid:${sources}`,
        title: t.groups.apiKey(sources),
        note: t.groups.apiKeyNote,
        options: [],
      };
      group.options.push(option);
      keys.set(sources, group);
    } else unserved.options.push(option);
  }
  return {
    served: [...plans.values(), ...keys.values()],
    unserved,
  };
};

export function SettingsModelsPage({
  org,
  data: initial,
}: {
  org: string;
  data: BftSettingsModels;
}) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [allowed, setAllowed] = useState(() => keysOf(data.allowed_models));
  const [mode, setMode] = useState<Mode>(() =>
    data.allowed_models.length > 0 ? "selected" : "all"
  );
  const [defaults, setDefaults] = useState(() => defaultsOf(data));
  const [query, setQuery] = useState("");
  const write = useWrite();
  const unavailable = data.catalog_status === "unavailable";
  // Every choice the page has shown. A choice the server stops offering, such
  // as one whose only key was disabled, keeps its data while it is selected:
  // it is listed as one no account serves, can be unselected, and is saved as
  // it is.
  const seen = useRef(new Map<string, BftModelOption>());
  const shown = useMemo(() => {
    const offered = optionsByKey(data);
    offered.forEach((option, key) => seen.current.set(key, option));
    const kept = [...new Set([...allowed, defaults.task, defaults.router])].flatMap(
      (key) => {
        const option = key && !offered.has(key) ? seen.current.get(key) : undefined;
        return option ? [{ ...option, served_by: null, plans: [] }] : [];
      }
    );
    return kept.length === 0
      ? data
      : {
          ...data,
          catalog: [...data.catalog, ...kept],
          default_options: {
            router: [...data.default_options.router, ...kept],
            task: [...data.default_options.task, ...kept],
          },
        };
  }, [data, allowed, defaults]);
  const byKey = useMemo(() => optionsByKey(shown), [shown]);
  const groups = useMemo(() => groupsOf(shown), [shown]);
  const empty = mode === "selected" && allowed.length === 0;

  // Retired Settings addresses land on their section.
  useEffect(() => {
    const section = window.location.hash.slice(1);
    if (section) document.getElementById(section)?.scrollIntoView({ block: "start" });
  }, []);

  const choiceOf = (key: string | null) =>
    key === null ? null : (byKey.get(key)?.choice ?? null);

  const submit = () =>
    write.run(
      () =>
        api.updateSettingsModels(org, {
          allowed_models:
            mode === "all"
              ? []
              : allowed.flatMap((key) => {
                  const choice = byKey.get(key)?.choice;
                  return choice ? [choice] : [];
                }),
          default_task_model: choiceOf(defaults.task),
          default_router_model: choiceOf(defaults.router),
        }),
      (next) => {
        setData(next);
        setAllowed(keysOf(next.allowed_models));
        setMode(next.allowed_models.length > 0 ? "selected" : "all");
        setDefaults(defaultsOf(next));
      }
    );

  return (
    <>
      <AccountsSection
        org={org}
        // An account change changes what serves each model; unsaved choices stay.
        onChange={() => void api.settingsModels(org).then(setData, () => undefined)}
      />
      <FormSection description={t.allowedHint} id="allowed" title={t.allowedTitle}>
        {unavailable ? (
          <Unavailable />
        ) : data.catalog.length === 0 ? (
          <p className="bft-quiet bft-quiet-inline">{t.catalogEmpty}</p>
        ) : (
          <>
            <fieldset aria-label={t.modesLabel} className="bft-choices">
              {modes.map(({ value, label, hint }) => (
                <label className="bft-choice" key={value}>
                  <input
                    checked={mode === value}
                    name="allowed-mode"
                    onChange={() => setMode(value)}
                    type="radio"
                    value={value}
                  />
                  <span className="bft-choice-main">
                    {label}
                    <span className="bft-choice-meta">{hint}</span>
                  </span>
                </label>
              ))}
            </fieldset>
            {mode === "selected" ? (
              <ModelPicker
                allowed={allowed}
                groups={groups}
                onChange={setAllowed}
                query={query}
                onQuery={setQuery}
                servableUnavailable={data.servable_status !== "ok"}
              />
            ) : null}
            <PlatformModels data={data} />
          </>
        )}
      </FormSection>
      <FormSection description={t.defaultsHint} title={t.defaultsTitle}>
        {(["task", "router"] as const).map((role) => (
          <div className="bft-form-field" key={role}>
            <Dropdown
              className="bft-form-field"
              destructive={Boolean(write.fields[fieldOf[role]])}
              disabled={unavailable}
              hint={t.defaultHints[role]}
              items={defaultItems(shown, role, defaults[role])}
              label={t.defaultLabels[role]}
              onChange={(value) =>
                setDefaults((current) => ({
                  ...current,
                  [role]: value === platform ? null : value,
                }))
              }
              size="sm"
              value={defaults[role] ?? platform}
            />
            <FieldError message={write.fields[fieldOf[role]]} />
          </div>
        ))}
        <FormActions write={write}>
          {empty ? <p className="bft-form-section-note">{t.pickOne}</p> : null}
          <SaveButton
            busy={write.busy}
            disabled={unavailable || empty}
            onPress={submit}
          />
        </FormActions>
      </FormSection>
    </>
  );
}

/**
 * A role's default choices, grouped by what serves them: the platform first,
 * then the offered models an account serves, and the current choice even when
 * nothing serves it any more.
 */
function defaultItems(
  data: BftSettingsModels,
  role: Role,
  current: string | null
): DropdownItem[] {
  const known = data.servable_status === "ok";
  const offered = data.default_options[role].filter(
    (option) =>
      option.choice.kind !== "platform" &&
      (!known || option.served_by !== null || option.key === current)
  );
  return [
    {
      id: platform,
      label: t.platformDefault(data.platform_defaults[role]?.label),
      group: t.groups.platform,
    },
    // The label names the source too, so the chosen value shows it.
    ...offered.map((option) =>
      known
        ? {
            id: option.key,
            label: `${option.label} · ${sourceOf(option)}`,
            group: sourceOf(option),
          }
        : { id: option.key, label: option.label }
    ),
  ];
}

function ModelPicker({
  allowed,
  groups,
  onChange,
  query,
  onQuery,
  servableUnavailable,
}: {
  allowed: string[];
  groups: { served: Group[]; unserved: Group };
  onChange: (update: (keys: string[]) => string[]) => void;
  query: string;
  onQuery: (query: string) => void;
  servableUnavailable: boolean;
}) {
  const [showUnserved, setShowUnserved] = useState(false);
  const terms = termsOf(query);
  const searching = terms.length > 0;
  const filter = (group: Group): Group => ({
    ...group,
    options: searching
      ? group.options.filter((option) => matches(option, terms))
      : group.options,
  });
  // A search looks through every group, those no account serves too; a
  // selected model no account serves keeps that group in view.
  const unserved = filter(groups.unserved);
  const keptSelected = groups.unserved.options.some((option) =>
    allowed.includes(option.key)
  );
  const shown = [
    ...groups.served.map(filter),
    ...(searching || showUnserved || keptSelected ? [unserved] : []),
  ].filter((group) => group.options.length > 0);

  const toggle = (keys: string[], on: boolean) =>
    onChange((current) =>
      on
        ? [...current, ...keys.filter((key) => !current.includes(key))]
        : current.filter((key) => !keys.includes(key))
    );

  return (
    <div className="bft-model-picker">
      {servableUnavailable ? (
        <p className="bft-form-section-note">{t.servableUnavailable}</p>
      ) : groups.served.length === 0 ? (
        <p className="bft-form-section-note">{t.noServed}</p>
      ) : null}
      <InputField
        aria-label={t.filter}
        autoComplete="off"
        fieldSize="sm"
        onChange={(event) => onQuery(event.target.value)}
        placeholder={t.filterHint}
        type="search"
        value={query}
        wrapperClassName="bft-model-filter"
      />
      {searching && shown.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noMatches}</p>
      ) : null}
      {shown.map((group) => (
        <ModelGroup
          allowed={allowed}
          group={group}
          // A search opens every group it finds models in.
          key={`${group.id}:${searching ? "search" : "browse"}`}
          onToggle={toggle}
          open={searching ? true : undefined}
        />
      ))}
      {!searching && !keptSelected && groups.unserved.options.length > 0 ? (
        <button
          className="bft-link-button bft-model-more"
          onClick={() => setShowUnserved((value) => !value)}
          type="button"
        >
          {showUnserved
            ? t.groups.hideUnserved
            : t.groups.showUnserved(groups.unserved.options.length)}
        </button>
      ) : null}
    </div>
  );
}

function ModelGroup({
  group,
  allowed,
  onToggle,
  open: forced,
}: {
  group: Group;
  allowed: string[];
  onToggle: (keys: string[], on: boolean) => void;
  open: boolean | undefined;
}) {
  // A group starts open; its list scrolls inside a fixed height.
  const [toggled, setOpen] = useState(true);
  const open = forced ?? toggled;
  const bodyId = useId();
  const keys = group.options.map((option) => option.key);
  // A model no account serves can only be unchecked.
  const choosable = group.muted ? keys.filter((key) => allowed.includes(key)) : keys;
  const selected = keys.filter((key) => allowed.includes(key)).length;

  return (
    <section className="bft-model-group" data-muted={group.muted ? true : undefined}>
      <div className="bft-model-group-head">
        {group.muted ? null : (
          <Checkbox
            aria-label={t.groups.selectAll(group.title)}
            checked={selected === keys.length}
            indeterminate={selected > 0 && selected < keys.length}
            onChange={(event) => onToggle(choosable, event.target.checked)}
            size="sm"
          />
        )}
        <button
          aria-controls={bodyId}
          aria-expanded={open}
          aria-label={
            open ? t.groups.collapse(group.title) : t.groups.expand(group.title)
          }
          className="bft-model-group-toggle"
          onClick={() => setOpen(!open)}
          type="button"
        >
          <span className="bft-model-group-chevron" data-open={open ? true : undefined}>
            <ChevronRightSmallIcon />
          </span>
          <span className="bft-model-group-title">{group.title}</span>
          <span className="bft-model-group-count">
            {t.groups.count(selected, keys.length)}
          </span>
        </button>
      </div>
      {group.note ? <p className="bft-model-group-note">{group.note}</p> : null}
      {open ? (
        <ScrollArea
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-model-group-viewport"
        >
          <div className="bft-checklist" id={bodyId}>
            {group.options.map((option) => {
              const checked = allowed.includes(option.key);
              return (
                <Checkbox
                  checked={checked}
                  disabled={group.muted && !checked}
                  {...hintOf(option)}
                  key={option.key}
                  label={option.label}
                  onChange={(event) => onToggle([option.key], event.target.checked)}
                  size="sm"
                />
              );
            })}
          </div>
        </ScrollArea>
      ) : null}
    </section>
  );
}

/** The platform's own models: listed for what they cost, never allowed or not. */
function PlatformModels({ data }: { data: BftSettingsModels }) {
  const rows = (
    [
      [t.groups.platformRouter, data.platform_defaults.router?.label],
      [t.groups.platformTask, data.platform_defaults.task?.label],
    ] as const
  ).filter(([, label]) => label);
  if (rows.length === 0) return null;
  return (
    <section className="bft-model-group">
      <div className="bft-model-group-head">
        <span className="bft-model-group-title">{t.groups.platform}</span>
      </div>
      <p className="bft-model-group-note">{t.groups.platformNote}</p>
      <dl className="bft-model-platform">
        {rows.map(([role, label]) => (
          <div key={role}>
            <dt>{role}</dt>
            <dd>{label}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
