import { useId, useState, type ReactNode } from "react";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
} from "react-aria-components";
import { ChevronDownIcon, ChevronRightSmallIcon } from "../icons";
import { MenuPopover } from "../menu";
import { ScrollArea } from "../scroll-area";
import { Toggle } from "../toggle";
import { cx } from "../utils";
import { spacing } from "../../tokens";

export interface ModelPickerModel {
  id: string;
  name: string;
  /** The line it belongs to, such as "Opus"; models are listed under it. */
  family?: string;
  icon: ReactNode;
  efforts: readonly string[];
}

export interface ModelPickerAccount {
  id: string;
  name: string;
  icon?: ReactNode;
  /** A short state, such as what quota is left. */
  note?: string;
  tone?: "default" | "warning";
}

export interface ModelPickerValue {
  /** `null` is the built-in model. */
  model: string | null;
  /** `null` is the model's default effort. */
  effort: string | null;
  /** `null` lets the system choose the account. */
  profile: string | null;
  /** With an automatic account: may it use pay-per-use keys. */
  allowPaid: boolean;
}

export interface ModelPickerLabels {
  models: string;
  search: string;
  noMatch: string;
  effort: string;
  defaultEffort: string;
  account: string;
  auto: string;
  autoNote: string;
  allowPaid: string;
  allowPaidHint: string;
}

export interface ModelPickerProps {
  /** Names the trigger and its panel. */
  label: string;
  value: ModelPickerValue;
  builtin: { label: string; icon: ReactNode };
  /** Names a current choice that is not among `models`, such as an older setting. */
  currentLabel?: string;
  models: readonly ModelPickerModel[];
  /** Profiles that can serve a model, in the order to offer them. */
  accountsFor: (model: string) => readonly ModelPickerAccount[];
  labels: ModelPickerLabels;
  disabled?: boolean;
  /** Off when the model runs on its own sign-in, so there is no account to choose. */
  chooseAccount?: boolean;
  /** Each choice takes effect at once. */
  onChange: (value: ModelPickerValue) => void;
}

const optionClass = (selected: boolean) =>
  cx(
    "flex w-full min-w-0 cursor-pointer items-center gap-sm rounded-md px-md py-xs text-left text-sm text-primary outline-none",
    "hover:bg-secondary focus-visible:bg-secondary",
    selected && "bg-secondary font-medium"
  );

/**
 * One way to choose what an Agent runs: the model, how hard it thinks and
 * which account runs it, side by side in one panel. Each choice takes effect
 * as it is made.
 */
export function ModelPicker({
  label,
  value,
  builtin,
  currentLabel,
  models,
  accountsFor,
  labels,
  disabled,
  chooseAccount = true,
  onChange,
}: ModelPickerProps) {
  const valueId = useId();
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(value);
  const [filter, setFilter] = useState("");
  const [accountsOpen, setAccountsOpen] = useState(false);

  const current = models.find((model) => model.id === value.model);
  const chosen = models.find((model) => model.id === draft.model);
  const accounts = draft.model ? accountsFor(draft.model) : [];
  const account = accounts.find((entry) => entry.id === draft.profile);
  const valueAccount = value.model
    ? accountsFor(value.model).find((entry) => entry.id === value.profile)
    : undefined;

  const words = filter.trim().toLowerCase();
  const listed = models.filter(
    (model) =>
      !words || model.name.toLowerCase().includes(words) || model.id.includes(words)
  );
  const families = new Map<string, ModelPickerModel[]>();
  for (const model of listed) {
    const family = model.family ?? model.name;
    families.set(family, [...(families.get(family) ?? []), model]);
  }

  // A new model waits for its effort before anything is saved; an effort,
  // or an account for the model in effect, is saved at once.
  const [awaitingEffort, setAwaitingEffort] = useState(false);
  const choose = (patch: Partial<ModelPickerValue>) => {
    const next = { ...draft, ...patch };
    setDraft(next);
    if (!awaitingEffort || "effort" in patch) {
      setAwaitingEffort(false);
      onChange(next);
    }
  };
  const pickModel = (id: string | null) => {
    if (id === draft.model) return;
    const next = models.find((model) => model.id === id);
    const picked = {
      ...draft,
      model: id,
      effort: null,
      // An account the new model cannot use is dropped.
      profile:
        id &&
        draft.profile &&
        accountsFor(id).some((entry) => entry.id === draft.profile)
          ? draft.profile
          : null,
    };
    setDraft(picked);
    if (next && next.efforts.length > 0) {
      setAwaitingEffort(true);
    } else {
      setAwaitingEffort(false);
      onChange(picked);
    }
  };

  return (
    <DialogTrigger
      isOpen={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) {
          setDraft(value);
          setAwaitingEffort(false);
          setFilter("");
          setAccountsOpen(false);
        }
      }}
    >
      <AriaButton
        aria-label={label}
        // The name is the Agent; the current choice is read after it.
        aria-describedby={valueId}
        isDisabled={disabled ?? false}
        data-slot="model-picker-trigger"
        className={cx(
          "comma-settings-dropdown flex h-9 min-w-0 max-w-full cursor-pointer items-center gap-sm rounded-lg bg-primary px-md text-sm text-primary shadow-xs ring-1 ring-primary ring-inset outline-none",
          "hover:bg-primary_hover focus-visible:ring-2 disabled:cursor-not-allowed disabled:opacity-60"
        )}
      >
        {value.model && current ? current.icon : builtin.icon}
        <span id={valueId} className="flex min-w-0 items-center gap-sm">
          <span className="min-w-0 truncate font-medium">
            {value.model
              ? (current?.name ?? currentLabel ?? value.model)
              : builtin.label}
          </span>
          {current ? (
            <>
              <span className="shrink-0 text-tertiary">
                {value.effort ?? labels.defaultEffort}
              </span>
              {chooseAccount ? (
                <span className="min-w-0 truncate text-tertiary">
                  {valueAccount?.name ?? labels.auto}
                </span>
              ) : null}
            </>
          ) : null}
        </span>
        <ChevronDownIcon className="size-4 shrink-0 text-quaternary" />
      </AriaButton>
      <MenuPopover offset={spacing.xs} placement="bottom end">
        <AriaDialog
          aria-label={label}
          data-slot="model-picker-panel"
          className="flex flex-col rounded-xl bg-popup-secondary p-sm shadow-xs ring-1 ring-primary ring-inset outline-none"
        >
          <div className="flex min-h-0 gap-sm">
            <section
              className="flex w-64 min-w-0 flex-col gap-xs"
              aria-label={labels.models}
            >
              <h4 className="px-md pt-xs text-xs font-medium text-tertiary">
                {labels.models}
              </h4>
              {models.length > 8 ? (
                <input
                  aria-label={labels.search}
                  placeholder={labels.search}
                  value={filter}
                  onChange={(event) => setFilter(event.target.value)}
                  className="mx-xs rounded-md bg-primary px-md py-xs text-sm text-primary ring-1 ring-primary ring-inset outline-none placeholder:text-placeholder focus:ring-2"
                />
              ) : null}
              <ScrollArea className="max-h-80" edgeEffect="mask">
                <div className="flex flex-col gap-xxs">
                  <button
                    type="button"
                    aria-pressed={draft.model === null}
                    className={optionClass(draft.model === null)}
                    onClick={() => pickModel(null)}
                  >
                    {builtin.icon}
                    <span className="truncate">{builtin.label}</span>
                  </button>
                  {[...families].map(([family, members]) => (
                    <fieldset
                      key={family}
                      className="m-0 flex min-w-0 flex-col border-0 p-0"
                    >
                      <legend
                        className={cx(
                          "px-md pt-sm pb-xxs text-xs text-quaternary",
                          families.size < 2 && "sr-only"
                        )}
                      >
                        {family}
                      </legend>
                      {members.map((model) => (
                        <button
                          key={model.id}
                          type="button"
                          aria-pressed={draft.model === model.id}
                          title={model.id}
                          className={optionClass(draft.model === model.id)}
                          onClick={() => pickModel(model.id)}
                        >
                          {model.icon}
                          <span className="truncate">{model.name}</span>
                        </button>
                      ))}
                    </fieldset>
                  ))}
                  {listed.length === 0 ? (
                    <p className="px-md py-xs text-xs text-tertiary">
                      {labels.noMatch}
                    </p>
                  ) : null}
                </div>
              </ScrollArea>
            </section>
            {chosen ? (
              <section
                className="flex w-36 flex-col gap-xxs"
                aria-label={labels.effort}
              >
                <h4 className="px-md pt-xs pb-xxs text-xs font-medium text-tertiary">
                  {labels.effort}
                </h4>
                {[null, ...chosen.efforts].map((effort) => (
                  <button
                    key={effort ?? ""}
                    type="button"
                    aria-pressed={!awaitingEffort && draft.effort === effort}
                    className={optionClass(!awaitingEffort && draft.effort === effort)}
                    onClick={() => choose({ effort })}
                  >
                    {effort ?? labels.defaultEffort}
                  </button>
                ))}
              </section>
            ) : null}
          </div>
          {chosen && chooseAccount ? (
            <div className="mt-sm flex items-center gap-sm border-t border-secondary pt-sm">
              <DialogTrigger isOpen={accountsOpen} onOpenChange={setAccountsOpen}>
                <AriaButton
                  aria-label={labels.account}
                  className="flex min-w-0 flex-1 cursor-pointer items-center gap-xs rounded-md px-md py-xs text-left text-sm text-secondary outline-none hover:bg-secondary focus-visible:bg-secondary"
                >
                  <span className="text-tertiary">{labels.account}</span>
                  <span className="min-w-0 truncate text-primary">
                    {account?.name ?? labels.auto}
                  </span>
                  <ChevronRightSmallIcon className="size-4 shrink-0 text-quaternary" />
                </AriaButton>
                <MenuPopover offset={spacing.md} placement="right bottom">
                  <AriaDialog
                    aria-label={labels.account}
                    data-slot="model-picker-accounts"
                    className="flex w-72 flex-col gap-xxs rounded-xl bg-popup-secondary p-sm shadow-xs ring-1 ring-primary ring-inset outline-none"
                  >
                    <h4 className="px-md pt-xs pb-xxs text-xs font-medium text-tertiary">
                      {labels.account}
                    </h4>
                    <button
                      type="button"
                      aria-pressed={draft.profile === null}
                      className={cx(
                        optionClass(draft.profile === null),
                        "flex-col items-start"
                      )}
                      onClick={() => choose({ profile: null })}
                    >
                      <span>{labels.auto}</span>
                      <span className="text-xs font-normal text-tertiary">
                        {labels.autoNote}
                      </span>
                    </button>
                    {draft.profile === null ? (
                      <div className="px-md py-xs">
                        <Toggle
                          size="sm"
                          label={labels.allowPaid}
                          checked={draft.allowPaid}
                          onChange={(event) =>
                            choose({ allowPaid: event.target.checked })
                          }
                        />
                        {/* The switch sizes to its label; the hint wraps in the panel. */}
                        <p className="mt-xxs pl-10 text-xs text-pretty text-tertiary">
                          {labels.allowPaidHint}
                        </p>
                      </div>
                    ) : null}
                    {accounts.map((entry) => (
                      <button
                        key={entry.id}
                        type="button"
                        aria-pressed={draft.profile === entry.id}
                        className={optionClass(draft.profile === entry.id)}
                        onClick={() => {
                          choose({ profile: entry.id });
                          setAccountsOpen(false);
                        }}
                      >
                        {entry.icon}
                        <span className="flex min-w-0 flex-col">
                          <span className="truncate">{entry.name}</span>
                          {entry.note ? (
                            <span
                              className={cx(
                                "truncate text-xs font-normal",
                                entry.tone === "warning"
                                  ? "text-warning-primary"
                                  : "text-tertiary"
                              )}
                            >
                              {entry.note}
                            </span>
                          ) : null}
                        </span>
                      </button>
                    ))}
                  </AriaDialog>
                </MenuPopover>
              </DialogTrigger>
            </div>
          ) : null}
        </AriaDialog>
      </MenuPopover>
    </DialogTrigger>
  );
}
