/* oxlint-disable jsx-a11y/no-autofocus -- Search is the command palette's primary keyboard interaction when it opens. */
import { Command } from "cmdk";
import {
  useCallback,
  useEffect,
  useRef,
  useSyncExternalStore,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { Dialog as AriaDialog, Modal, ModalOverlay } from "react-aria-components";
import { commandPaletteLayout, motionDuration, spacing } from "../../tokens";
import { XIcon } from "../icons";
import { CommaLogoAnimation } from "../comma-mascot/CommaLogoAnimation";
import { NativeSurfaceSuppressor } from "../native-surface/NativeSurfaceSuppressor";
import { ScrollArea } from "../scroll-area";
import { cx, definedProps } from "../utils";

const COMMAND_PALETTE_EDGE_MASK = { size: spacing["4xl"] } as const;

export interface CommandPaletteItem<TValue extends string = string> {
  /** Stable unique value used by cmdk selection state. */
  value: TValue;
  title: ReactNode;
  subtitle?: ReactNode;
  /** Matched excerpt; may contain `CommandPaletteHighlight` nodes. */
  highlight?: ReactNode;
  meta?: ReactNode;
  icon?: ReactNode;
  disabled?: boolean;
}

export interface CommandPaletteGroup<TValue extends string = string> {
  id: string;
  heading?: ReactNode;
  items: readonly CommandPaletteItem<TValue>[];
}

export interface CommandPaletteFooterHint {
  keys: readonly string[];
  label: string;
}

export type CommandPaletteActiveChangeSource = "keyboard" | "pointer" | "programmatic";

export interface CommandPaletteProps<TValue extends string = string> {
  open: boolean;
  query: string;
  groups: readonly CommandPaletteGroup<TValue>[];
  onOpenChange: (open: boolean) => void;
  onQueryChange: (query: string) => void;
  onSelect: (item: CommandPaletteItem<TValue>) => void;
  /** Accessible name for both the dialog and cmdk combobox. */
  label: string;
  /** Controlled cmdk selection shared by pointer and keyboard navigation. */
  activeValue?: TValue;
  className?: string;
  closeLabel?: string;
  container?: HTMLElement;
  emptyDescription?: ReactNode;
  emptyTitle?: ReactNode;
  footerHints?: readonly CommandPaletteFooterHint[];
  listLabel?: string;
  loading?: boolean;
  loadingLabel?: string;
  loadingProgress?: number;
  onActiveValueChange?: (
    value: TValue,
    source: CommandPaletteActiveChangeSource
  ) => void;
  /** Commits pointer-owned work after the pointer settles on an item. */
  onPointerIntent?: (value: TValue) => void;
  /** Reverts transient pointer selection when the pointer leaves before settling. */
  onPointerIntentCancel?: (value: TValue) => void;
  placeholder?: string;
  /** Optional detail pane. Its visual surface is owned by the caller. */
  preview?: ReactNode;
  previewLabel?: string;
}

export interface CommandPaletteHighlightProps {
  children: ReactNode;
  className?: string;
}

/** Token-backed emphasis for an exact title or excerpt match. */
export const CommandPaletteHighlight = ({
  children,
  className,
}: CommandPaletteHighlightProps) => (
  <mark className={cx("bg-transparent font-medium text-inherit", className)}>
    {children}
  </mark>
);

const defaultFooterHints: readonly CommandPaletteFooterHint[] = [
  { label: "Navigate", keys: ["↑", "↓"] },
  { label: "Select", keys: ["↵"] },
];

const overlayClassName =
  "comma-command-palette-overlay fixed inset-0 z-[var(--z-index-modal-overlay)] flex items-center justify-center p-xl outline-none @max-[480px]/comma-window:p-md";

const modalClassName = "comma-command-palette-modal flex outline-none";

const dialogClassName =
  "comma-command-palette-dialog flex min-h-0 w-full flex-col overflow-hidden rounded-2xl border-[length:var(--border-width-0-5)] " +
  "border-primary bg-main-panel-bg text-primary shadow-3xl outline-none";

const previewViewportQuery = `(min-width: ${commandPaletteLayout.previewMinViewportWidth}px)`;

function subscribePreviewViewport(listener: () => void) {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return () => {};
  }
  const query = window.matchMedia(previewViewportQuery);
  query.addEventListener("change", listener);
  return () => query.removeEventListener("change", listener);
}

function previewViewportAvailable() {
  return (
    typeof window === "undefined" ||
    typeof window.matchMedia !== "function" ||
    window.matchMedia(previewViewportQuery).matches
  );
}

const itemClassName =
  "group flex cursor-default select-none items-start gap-md rounded-lg p-md outline-none " +
  "transition-[background-color,color] duration-[50ms] " +
  "data-[disabled=true]:pointer-events-none data-[disabled=true]:opacity-[var(--opacity-disabled)] " +
  "data-[selected=true]:bg-sidebar-bg-item motion-reduce:transition-none";

const CommandPaletteItemView = <TValue extends string>({
  item,
  onPointerClick,
  onPointerIntent,
  onPointerIntentCancel,
  onPointerSelectIntent,
  onSelect,
}: {
  item: CommandPaletteItem<TValue>;
  onPointerClick: () => void;
  onPointerIntent: () => void;
  onPointerIntentCancel: () => void;
  onPointerSelectIntent: (event: ReactPointerEvent<HTMLElement>) => void;
  onSelect: (item: CommandPaletteItem<TValue>) => void;
}) => (
  <Command.Item
    className={itemClassName}
    data-slot="command-palette-item"
    {...definedProps({ disabled: item.disabled })}
    onClickCapture={onPointerClick}
    onPointerCancel={onPointerIntentCancel}
    onPointerDownCapture={onPointerSelectIntent}
    onPointerLeave={onPointerIntentCancel}
    onPointerMoveCapture={onPointerIntent}
    onSelect={() => onSelect(item)}
    value={item.value}
  >
    {item.icon ? (
      <span
        aria-hidden="true"
        className="comma-icon-slot mt-xxs flex size-2xl shrink-0 items-center justify-center text-fg-tertiary transition-colors duration-[50ms] group-data-[selected=true]:text-fg-secondary motion-reduce:transition-none [&_svg]:size-full"
        data-slot="command-palette-item-icon"
      >
        {item.icon}
      </span>
    ) : null}
    <span className="flex min-w-0 flex-1 flex-col gap-xs text-start">
      <span
        className="truncate text-sm font-regular text-sidebar-text-primary group-data-[selected=true]:text-primary"
        data-slot="command-palette-item-title"
      >
        {item.title}
      </span>
      {item.subtitle ? (
        <span
          className="truncate text-xs text-sidebar-text-tertiary"
          data-slot="command-palette-item-subtitle"
        >
          {item.subtitle}
        </span>
      ) : null}
      {item.highlight ? (
        <span
          className="truncate text-sm font-regular text-sidebar-text-tertiary"
          data-slot="command-palette-item-highlight"
        >
          {item.highlight}
        </span>
      ) : null}
    </span>
    {item.meta ? (
      <span
        className="shrink-0 whitespace-nowrap text-sm font-regular text-quaternary @max-[384px]/comma-window:hidden"
        data-slot="command-palette-item-meta"
      >
        {item.meta}
      </span>
    ) : null}
  </Command.Item>
);

const CommandPaletteEmpty = ({
  description,
  title,
}: {
  description?: ReactNode;
  title: ReactNode;
}) => (
  <Command.Empty
    className="flex size-full items-center justify-center px-4xl py-5xl text-center"
    data-slot="command-palette-empty"
  >
    <span className="text-sm font-regular text-quaternary">{title}</span>
    {description ? <span className="sr-only"> {description}</span> : null}
  </Command.Empty>
);

const CommandPaletteFooter = ({
  hints,
}: {
  hints: readonly CommandPaletteFooterHint[];
}) => (
  <footer
    className="flex shrink-0 flex-wrap items-center gap-xl border-t-[length:var(--border-width-0-5)] border-primary px-xl py-lg text-xs text-quaternary"
    data-slot="command-palette-footer"
  >
    {hints.map((hint) => (
      <span
        className="inline-flex items-center gap-xs"
        key={`${hint.label}:${hint.keys.join("+")}`}
      >
        <span>{hint.label}</span>
        <span className="inline-flex items-center gap-xxs">
          {hint.keys.map((key, index) => (
            <kbd
              className="inline-flex h-xl min-w-xl items-center justify-center rounded-xs border-[length:var(--border-width-0-5)] border-primary bg-main-panel-item-bg px-xxs font-sans text-micro font-medium leading-none text-quaternary shadow-xs"
              key={`${key}-${index}`}
            >
              {key}
            </kbd>
          ))}
        </span>
      </span>
    ))}
  </footer>
);

/**
 * Controlled, presentation-only command palette. Callers provide already filtered and
 * ranked groups; cmdk owns accessible keyboard selection, never business search logic.
 */
export function CommandPalette<TValue extends string = string>({
  open,
  query,
  groups,
  onOpenChange,
  onQueryChange,
  onSelect,
  label,
  activeValue,
  className,
  closeLabel = "Close search",
  container,
  emptyDescription,
  emptyTitle = "No results found",
  footerHints = defaultFooterHints,
  listLabel = "Search results",
  loading = false,
  loadingLabel = "Loading results",
  loadingProgress,
  onActiveValueChange,
  onPointerIntent,
  onPointerIntentCancel,
  placeholder = "Search task",
  preview,
  previewLabel,
}: CommandPaletteProps<TValue>) {
  const activeChangeSourceRef =
    useRef<CommandPaletteActiveChangeSource>("programmatic");
  // Keep cmdk's pointer selection immediate; only the expensive preview
  // handoff waits for a cancelable dwell.
  const pointerIntentTimeoutRef = useRef<number | undefined>(undefined);
  const pointerIntentValueRef = useRef<TValue | undefined>(undefined);
  const activeValueRef = useRef(activeValue);
  activeValueRef.current = activeValue;
  const visibleGroups = groups.filter((group) => group.items.length > 0);
  const selectableValuesRef = useRef<ReadonlySet<TValue>>(new Set());
  selectableValuesRef.current = new Set(
    visibleGroups.flatMap((group) =>
      group.items.filter((item) => item.disabled !== true).map((item) => item.value)
    )
  );
  const resultCount = visibleGroups.reduce(
    (count, group) =>
      count + group.items.filter((item) => item.disabled !== true).length,
    0
  );
  const isEmpty = !loading && resultCount === 0;
  const hasPreviewViewport = useSyncExternalStore(
    subscribePreviewViewport,
    previewViewportAvailable,
    () => true
  );
  const showPreview = preview != null && !isEmpty && hasPreviewViewport;
  const pointerIntentCommit = onPointerIntent;
  const usesPointerIntent = pointerIntentCommit !== undefined;
  // cmdk normally owns pointer selection. Preview intent needs the active row
  // immediately while deferring only the preview, so this controlled mode owns
  // pointer selection in one place and leaves keyboard selection to cmdk.
  const ownsPointerSelection = usesPointerIntent && onActiveValueChange !== undefined;
  const hasScrollableResults = !loading && !isEmpty;
  const status = loading ? (
    loadingLabel
  ) : isEmpty ? (
    <>
      {emptyTitle}
      {emptyDescription ? <> {emptyDescription}</> : null}
    </>
  ) : (
    resultCount
  );
  const emitActiveValueChange = (
    value: TValue,
    source: CommandPaletteActiveChangeSource
  ) => {
    if (activeValueRef.current === value) return;
    activeValueRef.current = value;
    onActiveValueChange?.(value, source);
  };
  const handleActiveValueChange = (value: string) => {
    emitActiveValueChange(value as TValue, activeChangeSourceRef.current);
    activeChangeSourceRef.current = "programmatic";
  };
  const clearPointerIntent = useCallback(() => {
    if (pointerIntentTimeoutRef.current !== undefined) {
      window.clearTimeout(pointerIntentTimeoutRef.current);
      pointerIntentTimeoutRef.current = undefined;
    }
    pointerIntentValueRef.current = undefined;
  }, []);
  const schedulePointerIntent = (value: TValue) => {
    if (!usesPointerIntent) {
      return;
    }
    if (pointerIntentValueRef.current === value) return;

    clearPointerIntent();
    pointerIntentValueRef.current = value;
    pointerIntentTimeoutRef.current = window.setTimeout(() => {
      pointerIntentTimeoutRef.current = undefined;
      pointerIntentValueRef.current = undefined;
      if (
        (activeValueRef.current !== undefined && activeValueRef.current !== value) ||
        !selectableValuesRef.current.has(value)
      ) {
        return;
      }
      pointerIntentCommit(value);
    }, motionDuration.pointerIntent);
  };
  const markPointerChangeSource = () => {
    activeChangeSourceRef.current = "pointer";
    queueMicrotask(() => {
      if (activeChangeSourceRef.current === "pointer") {
        activeChangeSourceRef.current = "programmatic";
      }
    });
  };
  const activatePointerValue = (value: TValue) => {
    if (ownsPointerSelection) {
      emitActiveValueChange(value, "pointer");
      return;
    }
    markPointerChangeSource();
  };
  const cancelPointerIntent = (value: TValue) => {
    if (pointerIntentValueRef.current !== value) return;
    clearPointerIntent();
    onPointerIntentCancel?.(value);
  };
  const handleOpenChange = (nextOpen: boolean) => {
    if (!nextOpen) clearPointerIntent();
    onOpenChange(nextOpen);
  };

  useEffect(() => clearPointerIntent, [clearPointerIntent]);
  useEffect(() => {
    clearPointerIntent();
  }, [clearPointerIntent, open, query, usesPointerIntent]);

  return (
    <ModalOverlay
      className={overlayClassName}
      data-slot="command-palette-overlay"
      isDismissable
      isOpen={open}
      onOpenChange={handleOpenChange}
      {...definedProps({ UNSTABLE_portalContainer: container })}
    >
      <Modal className={modalClassName} data-slot="command-palette-modal">
        <NativeSurfaceSuppressor />
        <AriaDialog
          aria-label={label}
          className={cx(dialogClassName, className)}
          data-slot="command-palette-dialog"
        >
          <Command
            className="flex min-h-0 flex-1 flex-col"
            disablePointerSelection={ownsPointerSelection}
            label={label}
            loop
            shouldFilter={false}
            vimBindings={false}
            onKeyDownCapture={(event) => {
              const key = event.key.toLowerCase();
              if (
                event.key === "ArrowDown" ||
                event.key === "ArrowUp" ||
                event.key === "Home" ||
                event.key === "End" ||
                (event.ctrlKey && ["j", "k", "n", "p"].includes(key))
              ) {
                clearPointerIntent();
                activeChangeSourceRef.current = "keyboard";
              }
            }}
            {...definedProps({
              onValueChange: onActiveValueChange ? handleActiveValueChange : undefined,
              value: activeValue,
            })}
          >
            <output aria-atomic="true" aria-live="polite" className="sr-only">
              {listLabel}: {status}
            </output>
            <header
              className="flex shrink-0 items-center gap-lg px-xl pt-xl pb-md"
              data-slot="command-palette-header"
            >
              <Command.Input
                autoFocus
                className="min-w-0 flex-1 bg-transparent text-sm font-regular text-primary outline-none placeholder:text-placeholder"
                data-slot="command-palette-input"
                onValueChange={(value) => {
                  const pendingValue = pointerIntentValueRef.current;
                  if (pendingValue === undefined) {
                    clearPointerIntent();
                  } else {
                    cancelPointerIntent(pendingValue);
                  }
                  onQueryChange(value);
                }}
                placeholder={placeholder}
                value={query}
              />
              <button
                aria-label={closeLabel}
                className="comma-icon-slot inline-flex size-2xl shrink-0 items-center justify-center rounded-sm text-fg-tertiary outline-none [--button-press-scale:var(--motion-scale-tactile-pressed)] hover:bg-sidebar-bg-item hover:text-secondary focus-visible:shadow-focus-gray-shadow-xs [&_svg]:size-full"
                data-slot="command-palette-close"
                onClick={() => handleOpenChange(false)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ")
                    event.stopPropagation();
                }}
                type="button"
              >
                <XIcon />
              </button>
            </header>

            <Command.List
              className="min-h-0 flex-1"
              data-slot="command-palette-list"
              label={listLabel}
            >
              <div
                className={cx(
                  "comma-command-palette-content h-full min-h-0",
                  (hasScrollableResults || showPreview) &&
                    "comma-command-palette-content--inset",
                  showPreview && "comma-command-palette-content--split"
                )}
                data-has-preview={showPreview ? "true" : "false"}
                data-slot="command-palette-content"
              >
                {loading ? (
                  <Command.Loading
                    className="flex size-full items-center justify-center px-4xl py-5xl text-center text-sm text-quaternary"
                    data-slot="command-palette-loading"
                    label={loadingLabel}
                    {...definedProps({ progress: loadingProgress })}
                  >
                    <CommaLogoAnimation
                      style={{ color: "inherit" }}
                      aria-hidden="true"
                    />
                  </Command.Loading>
                ) : null}

                {isEmpty ? (
                  <CommandPaletteEmpty
                    {...definedProps({ description: emptyDescription })}
                    title={emptyTitle}
                  />
                ) : null}

                {hasScrollableResults ? (
                  <ScrollArea
                    className="h-full min-h-0"
                    contentClassName="min-h-full pr-lg"
                    edgeEffect="mask"
                    edgeMask={COMMAND_PALETTE_EDGE_MASK}
                    orientation="vertical"
                    scrollbarVisibility="hover"
                    viewportClassName="h-full min-h-0"
                    viewportProps={{ tabIndex: -1 }}
                  >
                    {visibleGroups.map((group) => (
                      <Command.Group
                        className="py-md [&_[cmdk-group-heading]]:px-md [&_[cmdk-group-heading]]:pb-sm [&_[cmdk-group-heading]]:text-xs [&_[cmdk-group-heading]]:font-medium [&_[cmdk-group-heading]]:text-quaternary [&_[cmdk-group-items]]:flex [&_[cmdk-group-items]]:flex-col [&_[cmdk-group-items]]:gap-xxs"
                        heading={group.heading}
                        key={group.id}
                        value={group.id}
                      >
                        {group.items.map((item) => (
                          <CommandPaletteItemView
                            item={item}
                            key={item.value}
                            onPointerClick={markPointerChangeSource}
                            onPointerIntent={() => {
                              activatePointerValue(item.value);
                              schedulePointerIntent(item.value);
                            }}
                            onPointerIntentCancel={() =>
                              cancelPointerIntent(item.value)
                            }
                            onPointerSelectIntent={(event) => {
                              if (event.button !== 0) return;
                              clearPointerIntent();
                              activatePointerValue(item.value);
                              onPointerIntent?.(item.value);
                            }}
                            onSelect={onSelect}
                          />
                        ))}
                      </Command.Group>
                    ))}
                  </ScrollArea>
                ) : null}

                {showPreview ? (
                  <div
                    className="comma-command-palette-preview min-h-0 min-w-0"
                    data-slot="command-palette-preview"
                    {...definedProps({
                      "aria-label": previewLabel,
                      role: previewLabel ? "region" : undefined,
                    })}
                  >
                    {preview}
                  </div>
                ) : null}
              </div>
            </Command.List>

            {footerHints.length > 0 ? (
              <CommandPaletteFooter hints={footerHints} />
            ) : null}
          </Command>
        </AriaDialog>
      </Modal>
    </ModalOverlay>
  );
}
