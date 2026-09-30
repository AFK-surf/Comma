import { Header, MenuSection } from "react-aria-components";
import { LoadingIndicator } from "../LoadingIndicator";
import {
  memo,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type ReactNode,
} from "react";
import { Button } from "../Button";
import { Badge, type BadgeColor } from "../Badge";
import { Collapse, CollapseContent } from "../collapse";
import { Dropdown, type DropdownItem } from "../dropdown";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SubmenuTrigger,
  SharedSubmenu,
  SharedSubmenuScope,
} from "../menu";
import { ArrowUpIcon, ChevronDownIcon } from "../icons";
import { ModelVendorIcon } from "../model-templates/ModelVendorIcon";
import { ScrollArea } from "../scroll-area";
import { Tooltip } from "../tooltip";
import {
  AppKeybindingShortcut,
  SettingsShortcut,
  SettingsShortcutKeycaps,
  type AppKeybinding,
  type SettingsShortcutValue,
} from "../settings-shortcut";
import { Toggle } from "../toggle";
import { isReducedMotionEnabled } from "../../tokens";
import {
  sameSettingsValue,
  useLatestCallback,
  withLatestCallbacks,
} from "./settingsIdentity";
import { cx, definedProps } from "../utils";

export interface SettingsSegmentedItem {
  disabled?: boolean;
  id: string;
  label: string;
}

type ModelMenuChoice = {
  id: string;
  label: string;
  subtitle?: string;
  selectedLabel?: string;
};
type ModelMenuFamily = {
  id: string;
  label: string;
  efforts: readonly ModelMenuChoice[];
};

export type SettingsControl =
  | {
      type: "menu";
      label: string;
      /** Renders an icon-only trigger; `label` becomes its accessible name. */
      icon?: ReactNode;
      disabled?: boolean;
      items: readonly {
        id: string;
        label: string;
        tone?: "default" | "destructive";
        onPress: () => void;
      }[];
    }
  | {
      type: "dropdown";
      ariaLabel?: string;
      width?: "content" | "fixed";
      items: DropdownItem[];
      disabled?: boolean;
      /** Options are still arriving; a loading row follows the current ones. */
      loading?: boolean;
      /** Renders only the rows of a flat list in view; pair with `width: "fixed"`. */
      virtualized?: boolean;
      value?: string;
      placeholder?: string;
      onChange?: (id: string) => void;
      onOpenChange?: (isOpen: boolean) => void;
    }
  | {
      type: "model-menu";
      value?: string;
      placeholder: string;
      disabled?: boolean;
      items: readonly { id: string; label: string; disabled?: boolean }[];
      groups: readonly {
        id: string;
        label: string;
        vendor?: string;
        section?: string;
        models: readonly (ModelMenuChoice | ModelMenuFamily)[];
      }[];
      onChange: (id: string) => void;
    }
  | {
      type: "toggle";
      checked?: boolean;
      defaultChecked?: boolean;
      disabled?: boolean;
      onChange?: (event: ChangeEvent<HTMLInputElement>) => void;
    }
  | {
      type: "segmented";
      items: readonly SettingsSegmentedItem[];
      value?: string;
      defaultValue?: string;
      onChange?: (id: string) => void;
    }
  | {
      type: "button";
      label: string;
      disabled?: boolean;
      onPress?: () => void;
      tone?: "default" | "danger";
    }
  | {
      type: "shortcut";
      value: SettingsShortcutValue | null;
      onClear?: () => Promise<void> | void;
      disabled?: boolean;
      errorMessage?: string;
      onChange?: (shortcut: SettingsShortcutValue) => Promise<void> | void;
      recordingLabel?: string;
    }
  | {
      type: "keybinding";
      value: AppKeybinding | null;
      disabled?: boolean;
      errorMessage?: string;
      onChange?: (binding: AppKeybinding) => void;
      onClear?: () => void;
      recordingLabel?: string;
      clearLabel?: string;
    }
  | {
      type: "keycaps";
      keys: readonly string[];
    }
  | {
      type: "custom";
      content: ReactNode;
    };

export interface SettingsPanelItem {
  id: string;
  title: string;
  /** Decorative identity beside the row's searchable text. */
  icon?: ReactNode;
  /** Identity, state and account facts for a connected-service card. */
  integration?: {
    status: { label: string; color: BadgeColor; loading?: boolean };
    details: readonly {
      label: string;
      value: string;
      /** Describes a detail's action in its tooltip and accessible name. */
      actionLabel?: string;
      onPress?: () => void;
    }[];
    content?: ReactNode;
    note: string;
  };
  description?: string;
  descriptionLoading?: boolean;
  errorMessage?: string;
  /**
   * Current state of the thing the row is about, reported as a dot in the
   * trailing edge the controls share, so states line up down a column of
   * rows. State the row reports; not something the reader can press.
   */
  status?: { label: string; color: BadgeColor; loading?: boolean };
  keywords?: readonly string[];
  /**
   * `stack` puts the control under the copy so large instruments can use the
   * full row, and leaves the title to assistive tech alone. `field` keeps the
   * title visible above a full-width control — the shape a form needs when its
   * rows live in a settings card.
   */
  layout?: "row" | "stack" | "field";
  control?: SettingsControl;
  /** Sits beside the control, for an action that acts on the setting itself. */
  controlLeading?: ReactNode;
  /**
   * Full-width content under the row's copy and control, such as a live
   * preview of the setting. `null` keeps an empty slot, so content that
   * arrives later folds open and content that leaves folds shut; leave it out
   * on rows that never show any.
   */
  content?: ReactNode;
}

export interface SettingsPanelSection {
  id: string;
  title: string;
  items: SettingsPanelItem[];
}

export type SettingsPanelSurface = "embedded" | "standalone";

export interface SettingsPanelProps {
  activeItemId?: string;
  sections?: SettingsPanelSection[];
  className?: string;
  surface?: SettingsPanelSurface;
  title?: string;
  titleAction?: ReactNode;
  emptyTitle?: string;
  emptyDescription?: string;
}

const defaultSections: SettingsPanelSection[] = [
  {
    id: "general",
    title: "General",
    items: [
      {
        id: "file-destination",
        title: "Default file open destination",
        description: "Where files and folders open by default",
        control: {
          type: "dropdown",
          value: "cursor",
          items: [
            { id: "cursor", label: "Cursor" },
            { id: "finder", label: "Finder" },
          ],
        },
      },
      {
        id: "language",
        title: "Language",
        description: "Language for the app UI",
        control: {
          type: "dropdown",
          value: "auto",
          items: [
            { id: "auto", label: "Auto detect" },
            { id: "en", label: "English" },
          ],
        },
      },
      {
        id: "menu-bar",
        title: "Show in menu bar",
        description: "Keep Comma in the macOS menu bar when the main window is closed",
        control: { type: "toggle" },
      },
    ],
  },
];

const Control = ({
  control,
  label,
  withinIntegration = false,
  fullWidth = false,
}: {
  control?: SettingsControl;
  label: string;
  withinIntegration?: boolean;
  /** A form row's control spans the row rather than sizing to its content. */
  fullWidth?: boolean;
}) => {
  const controlId = useId();
  if (!control) return null;

  if (control.type === "menu") {
    return (
      <MenuTrigger>
        {control.icon ? (
          <Button
            aria-label={control.label}
            hierarchy="tertiary-gray"
            iconLeading={control.icon}
            iconOnly
            size="md"
            {...definedProps({ disabled: control.disabled })}
          />
        ) : (
          <Button
            hierarchy="secondary-gray"
            size="sm"
            {...definedProps({ disabled: control.disabled })}
          >
            {control.label}
          </Button>
        )}
        <MenuPopover placement="bottom end">
          <Menu aria-label={`${label} ${control.label}`}>
            {control.items.map((item) => (
              <MenuItem
                key={item.id}
                id={item.id}
                onAction={item.onPress}
                {...definedProps({ tone: item.tone })}
              >
                {item.label}
              </MenuItem>
            ))}
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    );
  }

  if (control.type === "dropdown") {
    return (
      <Dropdown
        // `default` is what makes the trigger span its row; the `w-full`
        // override replaces that variant's fixed 20rem root with the row width.
        className={cx(
          "comma-settings-dropdown",
          control.width === "fixed" && "w-full",
          fullWidth && "w-full"
        )}
        items={control.items}
        placeholder={control.placeholder ?? "Select team member"}
        size="sm"
        width={fullWidth || control.width === "fixed" ? "default" : "content"}
        {...definedProps({
          ariaLabel: control.ariaLabel,
          disabled: control.disabled,
          loading: control.loading,
          virtualized: control.virtualized,
          value: control.value,
          onChange: control.onChange,
          onOpenChange: control.onOpenChange,
        })}
      />
    );
  }

  if (control.type === "model-menu") {
    const selected = [
      ...control.items,
      ...control.groups.flatMap((group) =>
        group.models.flatMap((model) => ("efforts" in model ? model.efforts : [model]))
      ),
    ].find((item) => item.id === control.value);
    const selectedLabel =
      selected && "selectedLabel" in selected
        ? selected.selectedLabel
        : selected?.label;
    const renderChoice = (choice: ModelMenuChoice, descriptionId: string) => (
      <MenuItem
        aria-label={choice.label}
        {...definedProps({
          "aria-describedby": choice.subtitle ? descriptionId : undefined,
        })}
        id={choice.id}
        key={choice.id}
        onAction={() => control.onChange(choice.id)}
        textValue={choice.label}
      >
        <span className="block min-w-0 truncate">
          <span className="block truncate">{choice.label}</span>
          {choice.subtitle && (
            <span className="block truncate text-xs text-tertiary" id={descriptionId}>
              {choice.subtitle}
            </span>
          )}
        </span>
      </MenuItem>
    );
    return (
      <MenuTrigger>
        <Button
          aria-label={label}
          className="comma-settings-dropdown min-w-0 w-full justify-between truncate"
          data-slot="model-menu-trigger"
          hierarchy="secondary-gray"
          iconTrailing={<ChevronDownIcon className="size-4" />}
          size="sm"
          {...definedProps({ disabled: control.disabled })}
        >
          <span className="min-w-0 truncate">
            {selectedLabel ?? control.placeholder}
          </span>
        </Button>
        <MenuPopover closeSubmenusOnPointerLeave placement="bottom end">
          <Menu aria-label={label}>
            {control.items.map((item) => (
              <MenuItem
                id={item.id}
                {...definedProps({ isDisabled: item.disabled })}
                key={item.id}
                onAction={() => control.onChange(item.id)}
              >
                {item.label}
              </MenuItem>
            ))}
            {control.items.length > 0 && control.groups.length > 0 && <MenuSeparator />}
            {Array.from(new Set(control.groups.map((group) => group.section))).map(
              (section) => (
                <MenuSection
                  key={section ?? "models"}
                  {...definedProps({ "aria-label": section })}
                >
                  {section && (
                    <Header className="px-md py-sm text-xs font-medium text-tertiary">
                      {section}
                    </Header>
                  )}
                  {control.groups
                    .filter((group) => group.section === section)
                    .map((group) => (
                      <SubmenuTrigger key={group.id} delay={0}>
                        <MenuItem
                          icon={<ModelVendorIcon vendor={group.vendor ?? group.id} />}
                        >
                          {group.label}
                        </MenuItem>
                        <MenuPopover offset={0} placement="right top">
                          <SharedSubmenuScope>
                            <Menu aria-label={group.label}>
                              {group.models.map((model, index) =>
                                "efforts" in model ? (
                                  <SubmenuTrigger key={model.id} delay={0}>
                                    <MenuItem>{model.label}</MenuItem>
                                    <SharedSubmenu>
                                      <MenuPopover offset={0} placement="right top">
                                        <Menu aria-label={model.label}>
                                          {model.efforts.map((effort, effortIndex) =>
                                            renderChoice(
                                              effort,
                                              `${controlId}-${group.id}-model-${index}-effort-${effortIndex}-description`
                                            )
                                          )}
                                        </Menu>
                                      </MenuPopover>
                                    </SharedSubmenu>
                                  </SubmenuTrigger>
                                ) : (
                                  renderChoice(
                                    model,
                                    `${controlId}-${group.id}-model-${index}-description`
                                  )
                                )
                              )}
                            </Menu>
                          </SharedSubmenuScope>
                        </MenuPopover>
                      </SubmenuTrigger>
                    ))}
                </MenuSection>
              )
            )}
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    );
  }

  if (control.type === "toggle") {
    return (
      <Toggle
        aria-label={label}
        size="md"
        slim
        {...definedProps({
          checked: control.checked,
          defaultChecked: control.defaultChecked,
          disabled: control.disabled,
          onChange: control.onChange,
        })}
      />
    );
  }

  if (control.type === "segmented") {
    const selected = control.value ?? control.defaultValue ?? control.items[0]?.id;
    return (
      <fieldset
        aria-label={label}
        className="m-0 flex items-center gap-xs border-0 p-0"
      >
        {control.items.map((item) => (
          <Button
            aria-pressed={item.id === selected}
            className={cx(
              "min-h-9 px-lg",
              item.id === selected && "bg-sidebar-bg-item"
            )}
            hierarchy="tertiary-gray"
            key={item.id}
            onPress={() => control.onChange?.(item.id)}
            size="sm"
            {...definedProps({ disabled: item.disabled })}
          >
            {item.label}
          </Button>
        ))}
      </fieldset>
    );
  }

  if (control.type === "button") {
    return (
      <Button
        {...definedProps({ className: withinIntegration ? "min-h-10" : undefined })}
        hierarchy={control.tone === "danger" ? "secondary-color" : "secondary-gray"}
        size="sm"
        {...definedProps({
          disabled: control.disabled,
          onPress: control.onPress,
        })}
      >
        {control.label}
      </Button>
    );
  }

  if (control.type === "shortcut") {
    return (
      <SettingsShortcut
        ariaLabel={label}
        value={control.value}
        {...definedProps({
          disabled: control.disabled,
          errorMessage: control.errorMessage,
          onChange: control.onChange,
          onClear: control.onClear,
          recordingLabel: control.recordingLabel,
        })}
      />
    );
  }

  if (control.type === "keybinding") {
    return (
      <AppKeybindingShortcut
        ariaLabel={label}
        value={control.value}
        {...definedProps({
          clearLabel: control.clearLabel,
          disabled: control.disabled,
          errorMessage: control.errorMessage,
          onChange: control.onChange,
          onClear: control.onClear,
          recordingLabel: control.recordingLabel,
        })}
      />
    );
  }

  if (control.type === "keycaps") {
    return <SettingsShortcutKeycaps keys={control.keys} />;
  }

  return <>{control.content}</>;
};

/**
 * A row's `content` slot. Holds on to what it last showed while it folds
 * shut, since by then the row has already stopped passing it.
 */
const SettingsRowContent = ({ content }: { content: ReactNode }) => {
  const open = content !== null && content !== false;
  const [shown, setShown] = useState(content);
  if (open && shown !== content) setShown(content);

  return (
    <Collapse className="w-full" open={open}>
      <CollapseContent className="pt-xl">{open ? content : shown}</CollapseContent>
    </Collapse>
  );
};

/**
 * One setting. It renders again only when its data changes, so a switch
 * flipped on one row leaves the rest of the page alone. Its callbacks call
 * the section's latest item when they run, not the one it last rendered.
 */
const SettingsRow = memo(
  function SettingsRow({
    active,
    item: renderedItem,
    latestItem,
  }: {
    active: boolean;
    item: SettingsPanelItem;
    latestItem: (id: string) => SettingsPanelItem | undefined;
  }) {
    const item = useMemo(
      () =>
        withLatestCallbacks(
          renderedItem,
          () => latestItem(renderedItem.id) ?? renderedItem
        ),
      [latestItem, renderedItem]
    );
    return <SettingsRowView active={active} item={item} />;
  },
  (previous, next) =>
    previous.active === next.active &&
    previous.latestItem === next.latestItem &&
    sameSettingsValue(previous.item, next.item)
);

const SettingsRowView = ({
  active,
  item,
}: {
  active: boolean;
  item: SettingsPanelItem;
}) => {
  const field = item.layout === "field";
  const stacked = item.layout === "stack" || field;
  const hasContent = item.content !== undefined;
  const fixedDropdown =
    item.control?.type === "model-menu" ||
    (item.control?.type === "dropdown" && item.control.width === "fixed");

  if (item.integration) {
    return (
      <div
        className="@container/integration w-full scroll-m-7xl outline-none"
        data-active={active ? "true" : "false"}
        data-setting-id={item.id}
        data-slot="settings-row"
        tabIndex={-1}
      >
        <div className="grid grid-cols-[32px_minmax(0,1fr)_auto] items-start gap-x-xl gap-y-xl p-2xl">
          <span
            aria-hidden="true"
            className="mt-xs inline-flex size-4xl items-center justify-center [&_svg]:size-full"
          >
            {item.icon}
          </span>
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-x-lg gap-y-xs">
              <p className="text-base font-medium text-primary">{item.title}</p>
              <Badge
                className="border-0 bg-transparent p-0 font-normal text-tertiary"
                color={item.integration.status.color}
                dot
                size="sm"
              >
                {item.integration.status.loading ? (
                  <LoadingIndicator label={item.integration.status.label} />
                ) : (
                  item.integration.status.label
                )}
              </Badge>
            </div>
            <output className="mt-xs block text-pretty text-sm leading-5 text-tertiary">
              {item.descriptionLoading ? (
                <LoadingIndicator label={item.description ?? item.title} />
              ) : (
                item.description
              )}
            </output>
          </div>
          <div className="-mr-md @max-[360px]/integration:col-start-2 @max-[360px]/integration:-ml-lg @max-[360px]/integration:justify-self-start">
            {item.control ? (
              <Control control={item.control} label={item.title} withinIntegration />
            ) : null}
          </div>
          {item.integration.content ? (
            <div className="col-span-2 col-start-2 border-t-[0.5px] border-primary pt-xl @max-[360px]/integration:col-span-3 @max-[360px]/integration:col-start-1">
              {item.integration.content}
            </div>
          ) : null}
          <dl className="col-span-2 col-start-2 m-0 grid min-w-0 grid-cols-[repeat(auto-fit,minmax(min(100%,200px),1fr))] gap-x-xl gap-y-md border-t-[0.5px] border-primary pt-xl @max-[360px]/integration:col-span-3 @max-[360px]/integration:col-start-1">
            {item.integration.details.map((detail) => {
              const value = detail.onPress ? (
                <Button
                  aria-label={
                    detail.actionLabel
                      ? `${detail.actionLabel} (${detail.value})`
                      : detail.value
                  }
                  className="-ml-md min-h-10 max-w-full justify-start gap-sm px-sm text-left font-normal whitespace-normal [&>span:first-child]:min-w-0 [&>span:first-child]:[overflow-wrap:anywhere]"
                  hierarchy="tertiary-gray"
                  iconTrailing={<ArrowUpIcon className="rotate-45 text-quaternary" />}
                  onPress={detail.onPress}
                  size="sm"
                >
                  {detail.value}
                </Button>
              ) : (
                <span className="[overflow-wrap:anywhere]">{detail.value}</span>
              );
              return (
                <div key={detail.label} className="min-w-0">
                  <dt className="text-xs leading-5 text-quaternary">{detail.label}</dt>
                  <dd className="m-0 flex min-h-10 min-w-0 items-center text-sm leading-5 text-primary">
                    {detail.onPress && detail.actionLabel ? (
                      <Tooltip content={detail.actionLabel}>{value}</Tooltip>
                    ) : (
                      value
                    )}
                  </dd>
                </div>
              );
            })}
          </dl>
          <p className="col-span-2 col-start-2 -mt-sm text-pretty text-xs leading-5 text-quaternary @max-[360px]/integration:col-span-3 @max-[360px]/integration:col-start-1">
            {item.integration.note}
          </p>
        </div>
      </div>
    );
  }

  return (
    <div
      className={cx(
        "flex w-full scroll-m-7xl border-b-[0.5px] border-primary bg-main-panel-item-bg outline-none last:border-b-0",
        stacked
          ? "flex-col items-stretch gap-md px-lg py-lg"
          : "min-h-[calc(var(--spacing-7xl)+var(--spacing-lg))] items-center gap-xl px-xl py-xl",
        // The slot's own padding opens with it, so a shut slot adds no gap.
        hasContent && !stacked && "flex-wrap gap-y-0",
        fixedDropdown &&
          !stacked &&
          "@max-[500px]/settings-section:flex-col @max-[500px]/settings-section:items-stretch",
        item.errorMessage && !stacked && "flex-wrap gap-y-sm"
      )}
      data-active={active ? "true" : "false"}
      data-setting-id={item.id}
      data-slot="settings-row"
      tabIndex={-1}
    >
      {field ? (
        <div className="flex min-w-0 flex-col gap-xxs" data-slot="settings-copy">
          <p className="text-sm font-medium text-primary">{item.title}</p>
          {item.description ? (
            <p className="text-pretty text-sm text-tertiary">
              {item.descriptionLoading ? (
                <LoadingIndicator label={item.description ?? item.title} />
              ) : (
                item.description
              )}
            </p>
          ) : null}
        </div>
      ) : null}
      {item.icon && !stacked ? (
        <span
          aria-hidden="true"
          className="inline-flex size-2xl shrink-0 items-center justify-center [&_svg]:size-full"
        >
          {item.icon}
        </span>
      ) : null}
      {stacked ? (
        field ? null : (
          <span className="sr-only">{item.title}</span>
        )
      ) : (
        <div
          className="flex min-w-0 flex-1 flex-col gap-xxs text-sm leading-5 tracking-normal"
          data-slot="settings-copy"
        >
          <p className="truncate text-primary">{item.title}</p>
          {item.description && (
            <p className="line-clamp-2 text-pretty text-quaternary">
              {item.descriptionLoading ? (
                <LoadingIndicator label={item.description ?? item.title} />
              ) : (
                item.description
              )}
            </p>
          )}
        </div>
      )}
      {item.control || item.controlLeading || item.status ? (
        <div
          className={cx(
            "flex max-w-full items-center gap-md",
            stacked ? "w-full" : "shrink-0 justify-end",
            fixedDropdown && !stacked && "w-64 @max-[500px]/settings-section:w-full"
          )}
          data-slot="settings-control"
        >
          {item.status ? (
            <Badge
              className="border-0 bg-transparent p-0 font-normal text-tertiary"
              color={item.status.color}
              data-slot="settings-status"
              dot
              size="sm"
            >
              {item.status.loading ? (
                <LoadingIndicator label={item.status.label} />
              ) : (
                item.status.label
              )}
            </Badge>
          ) : null}
          {item.controlLeading}
          {item.control ? (
            <Control control={item.control} label={item.title} fullWidth={field} />
          ) : null}
        </div>
      ) : null}
      {item.errorMessage ? (
        <p
          className="w-full min-w-0 text-left text-xs text-error-primary [overflow-wrap:anywhere]"
          id={`settings-error-${item.id}`}
          role="alert"
        >
          {item.errorMessage}
        </p>
      ) : null}
      {hasContent ? <SettingsRowContent content={item.content} /> : null}
    </div>
  );
};

export const SettingsSectionView = ({
  activeItemId,
  section,
  appearance = "grouped",
}: {
  activeItemId?: string;
  section: SettingsPanelSection;
  appearance?: "grouped" | "plain";
}) => {
  const titleId = `settings-section-${section.id}`;
  const labelledBy = section.title ? titleId : undefined;
  const latestItem = useLatestCallback((id: string) =>
    section.items.find((item) => item.id === id)
  );
  return (
    <section
      aria-labelledby={labelledBy}
      aria-label={section.title ? undefined : section.items[0]?.title}
      className="@container/settings-section flex w-full flex-col gap-md"
    >
      {section.title ? (
        <div className="flex min-h-6 w-full items-center px-xl">
          <h2
            className="min-w-0 flex-1 text-balance text-sm font-medium text-quaternary"
            id={titleId}
          >
            {section.title}
          </h2>
        </div>
      ) : null}
      <div
        className={
          appearance === "plain"
            ? "flex w-full flex-col"
            : "flex w-full flex-col overflow-hidden rounded-2xl border-[0.5px] border-primary bg-main-panel-item-bg"
        }
      >
        {section.items.map((item) => (
          <SettingsRow
            active={item.id === activeItemId}
            item={item}
            key={item.id}
            latestItem={latestItem}
          />
        ))}
      </div>
    </section>
  );
};

export const SettingsPanel = ({
  activeItemId,
  sections = defaultSections,
  className,
  surface = "standalone",
  title = "General",
  titleAction,
  emptyTitle = "No settings available",
  emptyDescription,
}: SettingsPanelProps) => {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!activeItemId) return;
    const target = Array.from(
      panelRef.current?.querySelectorAll<HTMLElement>("[data-setting-id]") ?? []
    ).find((element) => element.dataset.settingId === activeItemId);
    if (!target) return;

    target.scrollIntoView?.({
      behavior: isReducedMotionEnabled() ? "auto" : "smooth",
      block: "center",
    });
    target.focus({ preventScroll: true });
  }, [activeItemId]);

  return (
    <div
      className={cx(
        "size-full min-h-0 overflow-hidden",
        surface === "standalone" &&
          "rounded-2xl border-[0.5px] border-primary bg-main-panel-bg shadow-sm",
        className
      )}
      data-slot="settings-panel"
      data-surface={surface}
      ref={panelRef}
    >
      <ScrollArea
        className="size-full"
        edgeEffect="mask"
        edgeMask={{ endSize: 96, startSize: 48 }}
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="size-full"
      >
        <div
          // The column keeps a gutter of its own, so a card too narrow to hold
          // its full width never runs the rows into the card's edge.
          className="mx-auto grid w-[640px] max-w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-3xl gap-x-0 px-xl py-3xl"
          data-slot="settings-panel-content"
        >
          <h1 className="m-0 min-w-0 px-xl text-balance text-xl font-medium text-primary">
            {title}
          </h1>
          {titleAction ? (
            <div className="shrink-0 pr-xl" data-slot="settings-panel-title-action">
              {titleAction}
            </div>
          ) : null}
          {sections.length > 0 ? (
            <div className="col-span-2 flex w-full flex-col gap-3xl">
              {sections.map((section) => (
                <SettingsSectionView
                  key={section.id}
                  section={section}
                  {...definedProps({ activeItemId })}
                />
              ))}
            </div>
          ) : (
            <div
              className="col-span-2 flex min-h-48 w-full flex-col items-center justify-center gap-xs rounded-2xl border-[0.5px] border-primary bg-main-panel-item-bg px-3xl py-7xl text-center"
              data-slot="settings-empty-state"
            >
              <p className="m-0 text-sm font-medium text-primary">{emptyTitle}</p>
              {emptyDescription ? (
                <p className="m-0 max-w-md text-sm text-quaternary">
                  {emptyDescription}
                </p>
              ) : null}
            </div>
          )}
        </div>
      </ScrollArea>
    </div>
  );
};
