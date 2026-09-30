import { useCommaMessages } from "@comma/i18n/react";
import {
  memo,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
  type Ref,
  type ReactNode,
} from "react";
import { Button } from "../Button";
import { Collapse, CollapseContent } from "../collapse";
import { ArrowLeftIcon, CubeIcon, LoaderIcon, SearchIcon } from "../icons";
import { InputField } from "../input";
import { ScrollArea } from "../scroll-area";
import { cx, definedProps } from "../utils";
import {
  isReducedMotionEnabled,
  motionDistance,
  motionDuration,
  motionEasing,
} from "../../tokens";

export interface PluginResource {
  id: string;
  name: string;
  icon?: ReactNode;
  /** A control for this resource, such as reconnecting the account behind it. */
  trailingContent?: ReactNode;
}

export interface PluginDefinition {
  id: string;
  name: string;
  summary: string;
  description?: string;
  icon?: ReactNode;
  mcps?: readonly PluginResource[];
  skills?: readonly PluginResource[];
}

export interface PluginSkillDefinition {
  id: string;
  name: string;
  description?: string;
  categoryId?: string;
}

export interface PluginSkillCategory {
  id: string;
  name: string;
}

export type PluginCatalogTab = "plugins" | "skills";

export interface PluginCategory {
  id: string;
  name: string;
  plugins: readonly PluginDefinition[];
}

export interface PluginCatalogCopy {
  title: string;
  searchAriaLabel: string;
  searchPlaceholder: string;
  installedLabel: string;
  manageLabel: string;
  addLabel: string;
  showAllLabel: string;
  emptyLabel: string;
  openPluginAriaLabel: (name: string) => string;
  addPluginAriaLabel: (name: string) => string;
  showAllCategoryAriaLabel: (category: string) => string;
  skillsTitle: string;
  skillsSearchAriaLabel: string;
  skillsSearchPlaceholder: string;
  skillsEmptyLabel: string;
  skillCategoriesAriaLabel: string;
  openSkillAriaLabel: (name: string) => string;
}

type CommaMessages = ReturnType<typeof useCommaMessages>;

const defaultPluginCatalogCopy = (messages: CommaMessages): PluginCatalogCopy => ({
  addLabel: messages.plugins_add(),
  addPluginAriaLabel: (name) => messages.plugins_add_named({ name }),
  emptyLabel: messages.plugins_no_results(),
  installedLabel: messages.plugins_installed(),
  manageLabel: messages.plugins_manage(),
  openPluginAriaLabel: (name) => messages.plugins_view_details({ name }),
  searchAriaLabel: messages.plugins_search(),
  searchPlaceholder: messages.plugins_search_placeholder(),
  showAllCategoryAriaLabel: (category) =>
    messages.plugins_show_all_category({ category }),
  showAllLabel: messages.plugins_show_all(),
  openSkillAriaLabel: (name) => messages.plugins_skills_view_details({ name }),
  skillCategoriesAriaLabel: messages.plugins_skills_categories(),
  skillsEmptyLabel: messages.plugins_skills_no_results(),
  skillsSearchAriaLabel: messages.plugins_skills_search(),
  skillsSearchPlaceholder: messages.plugins_skills_search_placeholder(),
  skillsTitle: messages.plugins_skills(),
  title: messages.plugins_title(),
});

export interface PluginDetailCopy {
  backLabel: string;
  installLabel: string;
  uninstallLabel: string;
  tryInChatLabel: string;
  descriptionLabel: string;
  mcpsLabel: string;
  skillsLabel: string;
  manageLabel: string;
  installPluginAriaLabel: (name: string) => string;
  uninstallPluginAriaLabel: (name: string) => string;
  tryPluginInChatAriaLabel: (name: string) => string;
}

const defaultPluginDetailCopy = (messages: CommaMessages): PluginDetailCopy => ({
  backLabel: messages.plugins_back(),
  descriptionLabel: messages.plugins_description(),
  installLabel: messages.plugins_add_to_comma(),
  installPluginAriaLabel: (name) => messages.plugins_add_to_comma_named({ name }),
  manageLabel: messages.plugins_manage(),
  mcpsLabel: messages.plugins_mcps(),
  skillsLabel: messages.plugins_skills(),
  tryInChatLabel: messages.plugins_try_in_chat(),
  tryPluginInChatAriaLabel: (name) => messages.plugins_try_in_chat_named({ name }),
  uninstallLabel: messages.plugins_uninstall(),
  uninstallPluginAriaLabel: (name) => messages.plugins_uninstall_named({ name }),
});

export interface PluginArtworkProps {
  icon?: ReactNode;
  size?: "xs" | "sm" | "md";
  className?: string;
}

export const PluginArtwork = ({ icon, size = "md", className }: PluginArtworkProps) => (
  <span
    aria-hidden="true"
    className={cx(
      "inline-flex shrink-0 items-center justify-center overflow-hidden rounded-md border border-primary bg-primary text-primary",
      size === "md"
        ? "size-11 [&_img]:size-full [&_svg]:size-6"
        : size === "sm"
          ? "size-6 [&_img]:size-full [&_svg]:size-3.5"
          : "size-4 rounded-xs [&_img]:size-full [&_svg]:size-3",
      className
    )}
    data-slot="plugin-artwork"
  >
    {icon}
  </span>
);

const PluginSummary = ({ plugin }: { plugin: PluginDefinition }) => (
  <span className="flex min-w-0 flex-1 flex-col gap-xxs text-sm">
    <span className="truncate font-medium text-primary">{plugin.name}</span>
    <span className="truncate text-quaternary">{plugin.summary}</span>
  </span>
);

export interface PluginInstalledCardProps {
  plugin: PluginDefinition;
  installedLabel?: string;
  openAriaLabel?: string;
  onOpen?: (plugin: PluginDefinition, trigger: PluginOpenTrigger) => void;
  className?: string;
}

export type PluginOpenTrigger = "pointer" | "keyboard";

export const PluginInstalledCard = ({
  plugin,
  installedLabel,
  openAriaLabel,
  onOpen,
  className,
}: PluginInstalledCardProps) => {
  const messages = useCommaMessages();
  const resolvedInstalledLabel = installedLabel ?? messages.plugins_installed();
  const content = (
    <>
      <PluginArtwork icon={plugin.icon} />
      <span className="flex w-full min-w-0 flex-col text-sm">
        <span className="truncate font-medium text-primary">{plugin.name}</span>
        <span className="truncate text-quaternary">{resolvedInstalledLabel}</span>
      </span>
    </>
  );
  const classes = cx(
    "flex min-h-[108px] min-w-0 flex-col items-start justify-center gap-md rounded-xl border border-primary bg-primary p-md text-left outline-none",
    onOpen && "comma-plugin-card focus-visible:shadow-focus-gray",
    className
  );

  if (!onOpen) {
    return (
      <article className={classes} data-slot="plugin-installed-card">
        {content}
      </article>
    );
  }

  return (
    <button
      aria-label={openAriaLabel ?? `View ${plugin.name} plugin details`}
      className={classes}
      data-slot="plugin-installed-card"
      onClick={(event) => onOpen(plugin, event.detail === 0 ? "keyboard" : "pointer")}
      type="button"
    >
      {content}
    </button>
  );
};

export interface PluginListItemProps {
  plugin: PluginDefinition;
  actionLabel?: string;
  actionAriaLabel?: string;
  actionHierarchy?: "primary" | "secondary-gray";
  actionDisabled?: boolean;
  actionPending?: boolean;
  openAriaLabel?: string;
  trailingContent?: ReactNode;
  onAction?: (plugin: PluginDefinition) => void;
  onOpen?: (plugin: PluginDefinition, trigger: PluginOpenTrigger) => void;
  className?: string;
}

export const PluginListItem = ({
  plugin,
  actionLabel,
  actionAriaLabel,
  actionHierarchy = "secondary-gray",
  actionDisabled = false,
  actionPending = false,
  openAriaLabel,
  trailingContent,
  onAction,
  onOpen,
  className,
}: PluginListItemProps) => {
  const summary = (
    <>
      <PluginArtwork icon={plugin.icon} />
      <PluginSummary plugin={plugin} />
    </>
  );

  return (
    <article
      className={cx(
        "flex w-full items-center gap-lg rounded-xl p-md",
        onOpen && "comma-plugin-list-item",
        className
      )}
      data-slot="plugin-list-item"
      data-plugin-id={plugin.id}
    >
      {onOpen ? (
        <button
          aria-label={openAriaLabel ?? `View ${plugin.name} plugin details`}
          className="flex min-w-0 flex-1 items-center gap-lg rounded-md text-left outline-none focus-visible:shadow-focus-gray"
          onClick={(event) =>
            onOpen(plugin, event.detail === 0 ? "keyboard" : "pointer")
          }
          type="button"
        >
          {summary}
        </button>
      ) : (
        <div className="flex min-w-0 flex-1 items-center gap-lg">{summary}</div>
      )}
      {trailingContent ??
        (actionLabel && onAction ? (
          <Button
            aria-label={actionAriaLabel ?? `${actionLabel} ${plugin.name}`}
            className={cx(
              "h-7 px-lg py-xs",
              actionHierarchy === "secondary-gray" &&
                "border-primary bg-[var(--color-plugin-bg-button)] text-primary hover:bg-[var(--color-plugin-bg-button)]"
            )}
            hierarchy={actionHierarchy}
            iconLeading={
              actionPending ? <LoaderIcon className="animate-spin" /> : undefined
            }
            isDisabled={actionDisabled || actionPending}
            onPress={() => onAction(plugin)}
            size="sm"
          >
            {actionLabel}
          </Button>
        ) : null)}
    </article>
  );
};

export interface PluginShowAllProps {
  plugins: readonly PluginDefinition[];
  controls?: string;
  label?: string;
  ariaLabel?: string;
  onPress: (event: ReactMouseEvent<HTMLButtonElement>) => void;
  buttonRef?: Ref<HTMLButtonElement>;
  className?: string;
}

const maxMatchedPreviewItems = 3;
const maxIndividuallyAnimatedRevealItems = 12;

export const PluginShowAll = ({
  plugins,
  controls,
  label,
  ariaLabel,
  onPress,
  buttonRef,
  className,
}: PluginShowAllProps) => {
  const messages = useCommaMessages();
  return (
    <button
      aria-controls={controls}
      aria-expanded={controls ? false : undefined}
      aria-label={ariaLabel}
      className={cx(
        "comma-plugin-show-all flex items-center gap-lg rounded-xl p-md text-left outline-none focus-visible:shadow-focus-gray",
        className
      )}
      data-slot="plugin-show-all"
      onClick={onPress}
      ref={buttonRef}
      type="button"
    >
      <span aria-hidden="true" className="flex h-[22px] w-11 shrink-0 items-center">
        {plugins.slice(0, maxMatchedPreviewItems).map((plugin, index) => (
          <span
            className={cx(
              "flex items-center justify-center",
              index === 0 && "z-[1] -mr-xs size-[17px] rotate-[4.5deg]",
              index === 1 && "z-[2] -mr-xs size-[17px] -rotate-[6.5deg]",
              index === 2 && "z-[3] size-[18px] rotate-[9deg]"
            )}
            data-plugin-id={plugin.id}
            key={plugin.id}
          >
            <PluginArtwork icon={plugin.icon} size="xs" />
          </span>
        ))}
      </span>
      <span className="text-sm font-medium text-primary">
        {label ?? messages.plugins_show_all()}
      </span>
    </button>
  );
};

interface PluginPreviewIconOrigin {
  rect: DOMRect;
  rotation: number;
  artwork: HTMLElement;
}

const previewIconRotations = [4.5, -6.5, 9] as const;
const pluginRevealTimelineDuration = 300;
const pluginRevealTailStartDelay =
  motionDuration.spatialMove - motionDuration.revealItem + motionDuration.revealStagger;
let pluginArtworkFlightId = 0;

const localFragmentUrlPattern = /url\(\s*(["']?)#([^\s"'()]+)\1\s*\)/g;
const localFragmentAttributes = new Set(["href", "xlink:href"]);
const localIdReferenceListAttributes = new Set(["aria-describedby", "aria-labelledby"]);

const namespacePluginArtworkFlightIds = (artwork: HTMLElement) => {
  const idSuffix = `-comma-plugin-flight-${pluginArtworkFlightId++}`;
  const elements = [artwork, ...artwork.querySelectorAll<HTMLElement>("*")];
  const renamedIds = new Map<string, string>();

  elements.forEach((element) => {
    if (!element.id) return;
    const nextId = `${element.id}${idSuffix}`;
    renamedIds.set(element.id, nextId);
    element.id = nextId;
  });

  elements.forEach((element) => {
    Array.from(element.attributes).forEach((attribute) => {
      let nextValue = attribute.value.replace(
        localFragmentUrlPattern,
        (reference, quote: string, previousId: string) => {
          const nextId = renamedIds.get(previousId);
          return nextId ? `url(${quote}#${nextId}${quote})` : reference;
        }
      );

      if (localFragmentAttributes.has(attribute.name) && nextValue.startsWith("#")) {
        const nextId = renamedIds.get(nextValue.slice(1));
        if (nextId) nextValue = `#${nextId}`;
      }

      if (localIdReferenceListAttributes.has(attribute.name)) {
        nextValue = nextValue
          .split(/\s+/)
          .map((previousId) => renamedIds.get(previousId) ?? previousId)
          .join(" ");
      }

      if (nextValue !== attribute.value) {
        element.setAttribute(attribute.name, nextValue);
      }
    });
  });
};

const capturePluginPreviewIconOrigins = (trigger: HTMLButtonElement) =>
  new Map<string, PluginPreviewIconOrigin>(
    Array.from(trigger.querySelectorAll<HTMLElement>("[data-plugin-id]")).flatMap(
      (preview, index) => {
        const id = preview.dataset.pluginId;
        const artwork = preview.querySelector<HTMLElement>(
          '[data-slot="plugin-artwork"]'
        );

        return id && artwork
          ? [
              [
                id,
                {
                  rect: (() => {
                    const transformedRect = artwork.getBoundingClientRect();
                    const width = artwork.offsetWidth || transformedRect.width;
                    const height = artwork.offsetHeight || transformedRect.height;

                    return new DOMRect(
                      transformedRect.left + (transformedRect.width - width) / 2,
                      transformedRect.top + (transformedRect.height - height) / 2,
                      width,
                      height
                    );
                  })(),
                  rotation: previewIconRotations[index] ?? 0,
                  artwork: artwork.cloneNode(true) as HTMLElement,
                },
              ] as const,
            ]
          : [];
      }
    )
  );

const animatePluginPreviewIcons = (
  hiddenPlugins: HTMLDivElement,
  origins: ReadonlyMap<string, PluginPreviewIconOrigin>,
  reducedMotion: boolean
) => {
  if (reducedMotion) return undefined;

  const matchedPluginIds = new Set<string>();
  const cleanups = Array.from(origins).flatMap(([pluginId, origin]) => {
    const row = Array.from(
      hiddenPlugins.querySelectorAll<HTMLElement>('[data-slot="plugin-list-item"]')
    ).find((candidate) => candidate.dataset.pluginId === pluginId);
    const artwork = row?.querySelector<HTMLElement>('[data-slot="plugin-artwork"]');

    if (!artwork || typeof artwork.animate !== "function") return [];

    const destination = artwork.getBoundingClientRect();
    if (origin.rect.width === 0 || destination.width === 0) return [];

    const flight = hiddenPlugins.ownerDocument.createElement("span");
    const sourceArtwork = origin.artwork;
    const destinationArtwork = artwork.cloneNode(true) as HTMLElement;
    const deltaX =
      origin.rect.left +
      origin.rect.width / 2 -
      (destination.left + destination.width / 2);
    const deltaY =
      origin.rect.top +
      origin.rect.height / 2 -
      (destination.top + destination.height / 2);
    const destinationScale = destination.width / origin.rect.width;
    const sourceScale = origin.rect.width / destination.width;
    const previousVisibility = artwork.style.visibility;

    flight.setAttribute("aria-hidden", "true");
    flight.dataset.pluginId = pluginId;
    flight.dataset.slot = "plugin-artwork-flight";
    sourceArtwork.dataset.slot = "plugin-artwork-flight-source";
    destinationArtwork.dataset.slot = "plugin-artwork-flight-destination";
    namespacePluginArtworkFlightIds(sourceArtwork);
    namespacePluginArtworkFlightIds(destinationArtwork);
    Object.assign(flight.style, {
      height: `${destination.height}px`,
      left: `${destination.left}px`,
      margin: "0",
      pointerEvents: "none",
      position: "fixed",
      top: `${destination.top}px`,
      transformOrigin: "center",
      width: `${destination.width}px`,
      willChange: "transform",
      zIndex: "9999",
    });
    Object.assign(sourceArtwork.style, {
      height: `${origin.rect.height}px`,
      left: "50%",
      margin: "0",
      position: "absolute",
      top: "50%",
      transformOrigin: "center",
      width: `${origin.rect.width}px`,
      willChange: "opacity, transform",
    });
    Object.assign(destinationArtwork.style, {
      height: "100%",
      inset: "0",
      margin: "0",
      position: "absolute",
      transformOrigin: "center",
      width: "100%",
      willChange: "opacity, transform",
    });
    flight.append(sourceArtwork, destinationArtwork);
    artwork.style.visibility = "hidden";
    hiddenPlugins.ownerDocument.body.append(flight);
    matchedPluginIds.add(pluginId);

    const animationOptions = {
      duration: motionDuration.spatialMove,
      easing: motionEasing.spatialMove,
      fill: "both",
    } as const;
    const movement = flight.animate(
      [
        {
          transform: `translate3d(${deltaX}px, ${deltaY}px, 0)`,
        },
        { transform: "translate3d(0, 0, 0)" },
      ],
      animationOptions
    );
    const sourceAppearance = sourceArtwork.animate(
      [
        {
          opacity: 1,
          transform: `translate3d(-50%, -50%, 0) scale(1) rotate(${origin.rotation}deg)`,
        },
        {
          opacity: 0,
          transform: `translate3d(-50%, -50%, 0) scale(${destinationScale}) rotate(0deg)`,
        },
      ],
      animationOptions
    );
    const destinationAppearance = destinationArtwork.animate(
      [
        {
          opacity: 0,
          transform: `scale(${sourceScale}) rotate(${origin.rotation}deg)`,
        },
        { opacity: 1, transform: "scale(1) rotate(0deg)" },
      ],
      animationOptions
    );
    const animations = [movement, sourceAppearance, destinationAppearance];
    let cleaned = false;
    const cleanup = () => {
      if (cleaned) return;
      cleaned = true;
      flight.remove();
      artwork.style.visibility = previousVisibility;
    };
    const handleFinish = () => {
      cleanup();
      animations.forEach((animation) => animation.cancel());
    };

    movement.addEventListener("finish", handleFinish, { once: true });
    movement.addEventListener("cancel", cleanup, { once: true });

    return [
      () => {
        movement.removeEventListener("finish", handleFinish);
        animations.forEach((animation) => animation.cancel());
        cleanup();
      },
    ];
  });

  return {
    cleanup: () => cleanups.forEach((cleanup) => cleanup()),
    pluginIds: matchedPluginIds,
  };
};

const getPluginRevealItemDelay = (index: number, itemCount: number) => {
  const matchedItemCount = Math.min(maxMatchedPreviewItems, itemCount);

  if (index < matchedItemCount) {
    return index * motionDuration.revealStagger;
  }

  const tailItemCount = itemCount - matchedItemCount;
  const tailIndex = index - matchedItemCount;
  const latestStartDelay = pluginRevealTimelineDuration - motionDuration.revealItem;

  if (tailItemCount === 1) {
    return pluginRevealTailStartDelay;
  }

  const adaptiveStagger = Math.min(
    motionDuration.revealStagger,
    (latestStartDelay - pluginRevealTailStartDelay) / (tailItemCount - 1)
  );

  return pluginRevealTailStartDelay + tailIndex * adaptiveStagger;
};

const animatePluginRevealItems = (
  hiddenPlugins: HTMLDivElement,
  reducedMotion: boolean,
  matchedPluginIds: ReadonlySet<string>
) => {
  const animationTargets = Array.from(hiddenPlugins.children) as HTMLElement[];
  const animations = animationTargets.flatMap((item, index) => {
    const pluginId = item.dataset.pluginId;
    const hasMatchedArtwork = pluginId ? matchedPluginIds.has(pluginId) : false;

    if (typeof item.animate !== "function") return [];

    const animation = item.animate(
      reducedMotion || hasMatchedArtwork
        ? [{ opacity: 0 }, { opacity: 1 }]
        : [
            {
              opacity: 0,
              transform: `translate3d(0, -${motionDistance.revealItem}px, 0)`,
            },
            {
              opacity: 1,
              transform: "translate3d(0, 0, 0)",
            },
          ],
      {
        delay: reducedMotion
          ? 0
          : getPluginRevealItemDelay(index, animationTargets.length),
        duration: reducedMotion ? motionDuration.feedbackIn : motionDuration.revealItem,
        easing: motionEasing.smoothOut,
        fill: "both",
      }
    );
    const cleanup = () => {
      animation.removeEventListener("finish", cleanup);
      animation.cancel();
    };

    animation.addEventListener("finish", cleanup, { once: true });
    return [animation];
  });

  return () => animations.forEach((animation) => animation.cancel());
};

interface PluginCategorySectionProps {
  category: PluginCategory;
  copy: PluginCatalogCopy;
  expanded: boolean;
  previewCount: number;
  onExpand: (categoryId: string) => void;
  claimExpansionFocus: (categoryId: string) => boolean;
  onPluginInstall?: (plugin: PluginDefinition) => void;
  onPluginOpen?: PluginListItemProps["onOpen"];
  pendingPluginIds: ReadonlySet<string>;
}

const PluginCategorySection = ({
  category,
  copy,
  expanded,
  previewCount,
  onExpand,
  claimExpansionFocus,
  onPluginInstall,
  onPluginOpen,
  pendingPluginIds,
}: PluginCategorySectionProps) => {
  const hiddenContentId = useId();
  const hiddenPluginsRef = useRef<HTMLDivElement>(null);
  const showAllButtonRef = useRef<HTMLButtonElement>(null);
  const focusOriginRef = useRef<HTMLButtonElement>(null);
  const restoreFocusAfterCollapseRef = useRef(false);
  const previewIconOriginsRef = useRef<
    ReadonlyMap<string, PluginPreviewIconOrigin> | undefined
  >(undefined);
  const handledFocusRequestRef = useRef(0);
  const [focusRequestVersion, setFocusRequestVersion] = useState(0);
  const overflowPlugins = category.plugins.slice(previewCount);
  // A disclosure control costs more interaction than it saves for one row.
  // Keep a single overflow plugin visible and reserve Show all for 2+ rows.
  const hiddenPlugins = overflowPlugins.length > 1 ? overflowPlugins : [];
  const visiblePlugins =
    hiddenPlugins.length > 0
      ? category.plugins.slice(0, previewCount)
      : category.plugins;
  const individuallyAnimatedPlugins = hiddenPlugins.slice(
    0,
    maxIndividuallyAnimatedRevealItems
  );
  const groupedAnimatedPlugins = hiddenPlugins.slice(
    maxIndividuallyAnimatedRevealItems
  );

  useLayoutEffect(() => {
    if (!expanded || !previewIconOriginsRef.current || !hiddenPluginsRef.current) {
      return;
    }

    const origins = previewIconOriginsRef.current;
    previewIconOriginsRef.current = undefined;
    const hiddenPluginsElement = hiddenPluginsRef.current;
    const reducedMotion = isReducedMotionEnabled();
    const view = hiddenPluginsElement.ownerDocument.defaultView;
    const pointerTransitionTimer = view
      ? (() => {
          hiddenPluginsElement.dataset.pointerExpanding = "";
          return view.setTimeout(
            () => delete hiddenPluginsElement.dataset.pointerExpanding,
            reducedMotion ? motionDuration.feedbackIn : pluginRevealTimelineDuration
          );
        })()
      : undefined;
    const previewIconAnimation = animatePluginPreviewIcons(
      hiddenPluginsElement,
      origins,
      reducedMotion
    );
    const cleanupItems = animatePluginRevealItems(
      hiddenPluginsElement,
      reducedMotion,
      previewIconAnimation?.pluginIds ?? new Set()
    );

    return () => {
      if (pointerTransitionTimer !== undefined) {
        view?.clearTimeout(pointerTransitionTimer);
      }
      delete hiddenPluginsElement.dataset.pointerExpanding;
      previewIconAnimation?.cleanup();
      cleanupItems();
    };
  }, [expanded]);

  useEffect(() => {
    if (
      !expanded ||
      handledFocusRequestRef.current === focusRequestVersion ||
      focusRequestVersion === 0
    ) {
      return;
    }

    handledFocusRequestRef.current = focusRequestVersion;
    const focusOrigin = focusOriginRef.current;
    focusOriginRef.current = null;
    if (!claimExpansionFocus(category.id)) {
      return;
    }

    const activeElement = focusOrigin?.ownerDocument.activeElement;
    const triggerStillOwnedFocus =
      activeElement === focusOrigin ||
      (focusOrigin !== null &&
        !focusOrigin.isConnected &&
        activeElement === focusOrigin.ownerDocument.body);

    if (!triggerStillOwnedFocus) {
      return;
    }

    const firstRevealedRow = hiddenPluginsRef.current?.querySelector<HTMLElement>(
      '[data-slot="plugin-list-item"]'
    );
    const firstRevealedControl = firstRevealedRow?.querySelector<HTMLElement>(
      'button:not(:disabled):not([aria-disabled="true"]), a[href], input:not(:disabled)'
    );

    if (firstRevealedControl) {
      firstRevealedControl.focus();
      return;
    }

    if (firstRevealedRow) {
      firstRevealedRow.tabIndex = -1;
      firstRevealedRow.focus();
    }
  }, [category.id, claimExpansionFocus, expanded, focusRequestVersion]);

  useLayoutEffect(() => {
    if (!expanded || !hiddenPluginsRef.current) return;

    const hiddenPluginsElement = hiddenPluginsRef.current;
    return () => {
      const activeElement = hiddenPluginsElement.ownerDocument.activeElement;
      restoreFocusAfterCollapseRef.current =
        activeElement !== null && hiddenPluginsElement.contains(activeElement);
    };
  }, [expanded]);

  useLayoutEffect(() => {
    if (expanded || !restoreFocusAfterCollapseRef.current) return;

    restoreFocusAfterCollapseRef.current = false;
    showAllButtonRef.current?.focus();
  }, [expanded]);

  const renderPluginListItem = (plugin: PluginDefinition) => (
    <PluginListItem
      key={plugin.id}
      plugin={plugin}
      {...definedProps({
        actionAriaLabel: onPluginInstall
          ? copy.addPluginAriaLabel(plugin.name)
          : undefined,
        actionLabel: onPluginInstall ? copy.addLabel : undefined,
        actionPending: pendingPluginIds.has(plugin.id),
        onAction: onPluginInstall,
        openAriaLabel: onPluginOpen ? copy.openPluginAriaLabel(plugin.name) : undefined,
        onOpen: onPluginOpen,
      })}
    />
  );

  return (
    <section className="flex w-full flex-col gap-lg">
      <h2 className="m-0 px-md text-sm font-medium text-quaternary">{category.name}</h2>
      <div className="flex flex-col gap-xxs">
        {visiblePlugins.map(renderPluginListItem)}
        {hiddenPlugins.length > 0 ? (
          <>
            <Collapse open={expanded}>
              <CollapseContent
                containerClassName="comma-plugin-reveal"
                id={hiddenContentId}
              >
                <div className="flex flex-col gap-xxs" ref={hiddenPluginsRef}>
                  {individuallyAnimatedPlugins.map(renderPluginListItem)}
                  {groupedAnimatedPlugins.length > 0 ? (
                    <div
                      className="flex flex-col gap-xxs"
                      data-slot="plugin-reveal-overflow"
                    >
                      {groupedAnimatedPlugins.map(renderPluginListItem)}
                    </div>
                  ) : null}
                </div>
              </CollapseContent>
            </Collapse>
            {!expanded ? (
              <PluginShowAll
                ariaLabel={copy.showAllCategoryAriaLabel(category.name)}
                controls={hiddenContentId}
                buttonRef={showAllButtonRef}
                label={copy.showAllLabel}
                plugins={hiddenPlugins}
                onPress={(event) => {
                  focusOriginRef.current = event.currentTarget;
                  previewIconOriginsRef.current =
                    event.detail === 0
                      ? undefined
                      : capturePluginPreviewIconOrigins(event.currentTarget);
                  setFocusRequestVersion((version) => version + 1);
                  onExpand(category.id);
                }}
              />
            ) : null}
          </>
        ) : null}
      </div>
    </section>
  );
};

export interface PluginCatalogProps {
  categories: readonly PluginCategory[];
  copy?: Partial<PluginCatalogCopy>;
  installedPlugins?: readonly PluginDefinition[];
  categoryPreviewCount?: number;
  searchQuery?: string;
  defaultSearchQuery?: string;
  expandedCategoryIds?: readonly string[];
  defaultExpandedCategoryIds?: readonly string[];
  onExpandedCategoryIdsChange?: (categoryIds: readonly string[]) => void;
  onManageInstalled?: () => void;
  onPluginInstall?: (plugin: PluginDefinition) => void;
  onPluginOpen?: PluginListItemProps["onOpen"];
  onSearchQueryChange?: (query: string) => void;
  pendingPluginIds?: ReadonlySet<string>;
  /** Workspace skills. Supplying them adds the Skills tab beside the title. */
  skills?: readonly PluginSkillDefinition[];
  /** Loading/error content replaces the Skills results, never the Plugins tab. */
  skillsStatus?: ReactNode;
  /** Source families shown as filter pills; skills join one by `categoryId`. */
  skillCategories?: readonly PluginSkillCategory[];
  skillCategoryId?: string;
  onSkillCategoryChange?: (categoryId: string) => void;
  onSkillOpen?: (skill: PluginSkillDefinition, trigger: PluginOpenTrigger) => void;
  tab?: PluginCatalogTab;
  defaultTab?: PluginCatalogTab;
  onTabChange?: (tab: PluginCatalogTab) => void;
  className?: string;
}

const SkillCatalogItem = memo(function SkillCatalogItem({
  skill,
  onOpen,
  openAriaLabel,
}: {
  skill: PluginSkillDefinition;
  onOpen: PluginCatalogProps["onSkillOpen"];
  openAriaLabel: string;
}) {
  return (
    <li
      style={{
        contentVisibility: "auto",
        containIntrinsicBlockSize:
          "auto calc(var(--spacing-md) * 2 + var(--spacing) * 11)",
      }}
    >
      <PluginListItem
        plugin={{
          icon: <CubeIcon className="text-fg-tertiary" />,
          id: skill.id,
          name: skill.name,
          summary: skill.description ?? "",
        }}
        {...(onOpen
          ? {
              onOpen: (_plugin, trigger) => onOpen(skill, trigger),
              openAriaLabel,
            }
          : {})}
      />
    </li>
  );
});

const pluginCatalogTabs = ["plugins", "skills"] as const;

export const PluginCatalog = ({
  categories,
  copy,
  installedPlugins = [],
  categoryPreviewCount = 3,
  searchQuery,
  defaultSearchQuery = "",
  expandedCategoryIds,
  defaultExpandedCategoryIds = [],
  onExpandedCategoryIdsChange,
  onManageInstalled,
  onPluginInstall,
  onPluginOpen,
  onSearchQueryChange,
  pendingPluginIds = new Set(),
  skills,
  skillsStatus,
  skillCategories = [],
  skillCategoryId,
  onSkillCategoryChange,
  onSkillOpen,
  tab,
  defaultTab = "plugins",
  onTabChange,
  className,
}: PluginCatalogProps) => {
  const messages = useCommaMessages();
  const resolvedCopy = { ...defaultPluginCatalogCopy(messages), ...copy };
  const tabsId = useId();
  const [internalTab, setInternalTab] = useState(defaultTab);
  const activeTab = skills ? (tab ?? internalTab) : "plugins";
  const showsSkills = activeTab === "skills";
  const [internalQuery, setInternalQuery] = useState(defaultSearchQuery);
  const [internalExpandedCategoryIds, setInternalExpandedCategoryIds] = useState<
    readonly string[]
  >(defaultExpandedCategoryIds);
  const pendingExpansionFocusCategoryIdRef = useRef<string | null>(null);
  const activeQuery = searchQuery ?? internalQuery;
  const activeExpandedCategoryIds = expandedCategoryIds ?? internalExpandedCategoryIds;
  const normalizedQuery = activeQuery.trim().toLocaleLowerCase();
  const installedPluginIds = useMemo(
    () => new Set(installedPlugins.map((plugin) => plugin.id)),
    [installedPlugins]
  );

  const filteredInstalledPlugins = useMemo(
    () => installedPlugins.filter((plugin) => matchesPlugin(plugin, normalizedQuery)),
    [installedPlugins, normalizedQuery]
  );
  const filteredCategories = useMemo(
    () =>
      categories
        .map((category) => ({
          ...category,
          plugins: category.plugins.filter(
            (plugin) =>
              !installedPluginIds.has(plugin.id) &&
              (category.name.toLocaleLowerCase().includes(normalizedQuery) ||
                matchesPlugin(plugin, normalizedQuery))
          ),
        }))
        .filter((category) => category.plugins.length > 0),
    [categories, installedPluginIds, normalizedQuery]
  );
  const populatedSkillCategories = useMemo(
    () =>
      skillCategories.filter((category) =>
        (skills ?? []).some((skill) => skill.categoryId === category.id)
      ),
    [skillCategories, skills]
  );
  const [internalSkillCategoryId, setInternalSkillCategoryId] = useState<string>();
  const selectedSkillCategoryId = skillCategoryId ?? internalSkillCategoryId;
  // A search spans every category; the pills only scope the unfiltered list.
  const activeSkillCategoryId =
    normalizedQuery.length > 0 || populatedSkillCategories.length < 2
      ? undefined
      : (populatedSkillCategories.find(
          (category) => category.id === selectedSkillCategoryId
        )?.id ?? populatedSkillCategories[0]?.id);
  const filteredSkills = useMemo(
    () =>
      (skills ?? []).filter(
        (skill) =>
          (activeSkillCategoryId === undefined ||
            skill.categoryId === activeSkillCategoryId) &&
          `${skill.name} ${skill.description ?? ""}`
            .toLocaleLowerCase()
            .includes(normalizedQuery)
      ),
    [activeSkillCategoryId, skills, normalizedQuery]
  );
  const hasResults = showsSkills
    ? filteredSkills.length > 0
    : filteredInstalledPlugins.length > 0 || filteredCategories.length > 0;

  const updateQuery = (nextQuery: string) => {
    if (searchQuery === undefined) {
      setInternalQuery(nextQuery);
    }
    onSearchQueryChange?.(nextQuery);
  };

  const selectTab = (nextTab: PluginCatalogTab) => {
    if (nextTab === activeTab) return;
    // Each tab searches its own list; a query never carries across.
    updateQuery("");
    if (tab === undefined) {
      setInternalTab(nextTab);
    }
    onTabChange?.(nextTab);
  };

  const expandCategory = (categoryId: string) => {
    if (activeExpandedCategoryIds.includes(categoryId)) return;
    pendingExpansionFocusCategoryIdRef.current = categoryId;
    const nextIds = [...activeExpandedCategoryIds, categoryId];
    if (expandedCategoryIds === undefined) {
      setInternalExpandedCategoryIds(nextIds);
    }
    onExpandedCategoryIdsChange?.(nextIds);
  };

  const claimExpansionFocus = (categoryId: string) => {
    if (pendingExpansionFocusCategoryIdRef.current !== categoryId) {
      return false;
    }

    pendingExpansionFocusCategoryIdRef.current = null;
    return true;
  };

  return (
    <div
      className={cx(
        "relative flex size-full min-h-0 min-w-0 justify-center bg-primary",
        className
      )}
      data-slot="plugin-catalog"
    >
      <ScrollArea
        className="size-full"
        contentClassName="min-h-full"
        edgeEffect="mask"
        edgeMask={{ startSize: 0, endSize: 24 }}
        orientation="vertical"
        scrollbarVisibility="scroll"
      >
        <div className="mx-auto flex w-full max-w-[700px] flex-col gap-2xl pb-3xl pt-7xl">
          <header className="flex flex-col px-md">
            {skills ? (
              <>
                <h1 className="sr-only">
                  {showsSkills ? resolvedCopy.skillsTitle : resolvedCopy.title}
                </h1>
                <div
                  aria-label={resolvedCopy.title}
                  className="flex items-center gap-xl"
                  role="tablist"
                >
                  {pluginCatalogTabs.map((tabId) => {
                    const selected = tabId === activeTab;
                    return (
                      <button
                        aria-controls={`${tabsId}-panel`}
                        aria-selected={selected}
                        className={cx(
                          "rounded-xs border-0 bg-transparent p-0 text-xl font-medium outline-none transition-colors focus-visible:shadow-focus-gray",
                          selected
                            ? "text-primary"
                            : "text-quaternary hover:text-secondary"
                        )}
                        data-tab={tabId}
                        id={`${tabsId}-${tabId}`}
                        key={tabId}
                        onClick={() => selectTab(tabId)}
                        onKeyDown={(event) => {
                          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
                            return;
                          }
                          event.preventDefault();
                          const nextTab = selected
                            ? pluginCatalogTabs[tabId === "plugins" ? 1 : 0]
                            : tabId;
                          selectTab(nextTab);
                          document.getElementById(`${tabsId}-${nextTab}`)?.focus();
                        }}
                        role="tab"
                        tabIndex={selected ? 0 : -1}
                        type="button"
                      >
                        {tabId === "skills"
                          ? resolvedCopy.skillsTitle
                          : resolvedCopy.title}
                      </button>
                    );
                  })}
                </div>
              </>
            ) : (
              <h1 className="m-0 text-balance text-xl font-medium text-primary">
                {resolvedCopy.title}
              </h1>
            )}
          </header>
          <InputField
            aria-label={
              showsSkills
                ? resolvedCopy.skillsSearchAriaLabel
                : resolvedCopy.searchAriaLabel
            }
            className="w-full"
            fieldSize="sm"
            leadingIcon={<SearchIcon className="size-5" />}
            onChange={(event) => updateQuery(event.target.value)}
            placeholder={
              showsSkills
                ? resolvedCopy.skillsSearchPlaceholder
                : resolvedCopy.searchPlaceholder
            }
            // A click leaves the field quiet; keyboard focus keeps its ring.
            suppressFocusRing
            wrapperClassName="data-[focus-visible]:ring-2 data-[focus-visible]:ring-border-brand data-[focus-visible]:shadow-focus-brand-shadow-xs"
            value={activeQuery}
          />
          <div
            className="flex w-full flex-col gap-2xl"
            {...(skills
              ? {
                  "aria-labelledby": `${tabsId}-${activeTab}`,
                  id: `${tabsId}-panel`,
                  role: "tabpanel",
                }
              : {})}
          >
            {showsSkills ? skillsStatus : null}
            {showsSkills && !skillsStatus && activeSkillCategoryId !== undefined ? (
              <fieldset
                aria-label={resolvedCopy.skillCategoriesAriaLabel}
                className="m-0 flex min-w-0 flex-wrap items-center gap-xs border-0 p-0"
              >
                {populatedSkillCategories.map((category) => {
                  const pressed = category.id === activeSkillCategoryId;
                  return (
                    <button
                      aria-pressed={pressed}
                      className={cx(
                        "rounded-md border-0 px-md py-xs text-sm font-medium outline-none transition-colors focus-visible:shadow-focus-gray",
                        pressed
                          ? "bg-secondary text-primary"
                          : "bg-transparent text-quaternary hover:text-secondary"
                      )}
                      key={category.id}
                      onClick={() => {
                        if (skillCategoryId === undefined) {
                          setInternalSkillCategoryId(category.id);
                        }
                        onSkillCategoryChange?.(category.id);
                      }}
                      type="button"
                    >
                      {category.name}
                    </button>
                  );
                })}
              </fieldset>
            ) : null}
            {showsSkills && !skillsStatus && filteredSkills.length > 0 ? (
              <ul className="m-0 flex list-none flex-col gap-xs p-0">
                {filteredSkills.map((skill) => (
                  <SkillCatalogItem
                    key={skill.id}
                    skill={skill}
                    onOpen={onSkillOpen}
                    openAriaLabel={resolvedCopy.openSkillAriaLabel(skill.name)}
                  />
                ))}
              </ul>
            ) : null}
            {!showsSkills && filteredInstalledPlugins.length > 0 ? (
              <section className="flex w-full flex-col gap-md">
                <div className="flex items-center justify-between pl-md">
                  <h2 className="m-0 text-sm font-medium text-quaternary">
                    {resolvedCopy.installedLabel}
                  </h2>
                  {onManageInstalled ? (
                    <Button
                      className="h-7 px-lg py-xs text-sidebar-text-highlight"
                      hierarchy="tertiary-gray"
                      onPress={onManageInstalled}
                      size="sm"
                    >
                      {resolvedCopy.manageLabel}
                    </Button>
                  ) : null}
                </div>
                <div className="grid grid-cols-[repeat(auto-fill,minmax(145px,1fr))] gap-lg">
                  {filteredInstalledPlugins.map((plugin) => (
                    <PluginInstalledCard
                      installedLabel={resolvedCopy.installedLabel}
                      key={plugin.id}
                      plugin={plugin}
                      {...definedProps({
                        onOpen: onPluginOpen,
                        openAriaLabel: onPluginOpen
                          ? resolvedCopy.openPluginAriaLabel(plugin.name)
                          : undefined,
                      })}
                    />
                  ))}
                </div>
              </section>
            ) : null}
            {(showsSkills ? [] : filteredCategories).map((category) => (
              <PluginCategorySection
                category={category}
                claimExpansionFocus={claimExpansionFocus}
                copy={resolvedCopy}
                expanded={
                  normalizedQuery.length > 0 ||
                  activeExpandedCategoryIds.includes(category.id)
                }
                key={category.id}
                onExpand={expandCategory}
                previewCount={
                  normalizedQuery.length > 0
                    ? category.plugins.length
                    : categoryPreviewCount
                }
                {...definedProps({
                  onPluginInstall,
                  onPluginOpen,
                  pendingPluginIds,
                })}
              />
            ))}
            {!hasResults && !(showsSkills && skillsStatus) ? (
              <output className="block px-md py-3xl text-center text-sm text-quaternary">
                {showsSkills ? resolvedCopy.skillsEmptyLabel : resolvedCopy.emptyLabel}
              </output>
            ) : null}
          </div>
        </div>
      </ScrollArea>
    </div>
  );
};

const matchesPlugin = (plugin: PluginDefinition, query: string) => {
  if (!query) return true;
  return `${plugin.name} ${plugin.summary} ${plugin.description ?? ""}`
    .toLocaleLowerCase()
    .includes(query);
};

const PluginResourceRow = ({ resource }: { resource: PluginResource }) => (
  <li className="flex items-center gap-md rounded-xl px-md py-sm">
    <PluginArtwork icon={resource.icon} size="sm" />
    <span className="min-w-0 flex-1 truncate text-sm text-secondary">
      {resource.name}
    </span>
    {resource.trailingContent}
  </li>
);

export interface PluginDetailSectionProps {
  title: string;
  action?: ReactNode;
  children: ReactNode;
}

export const PluginDetailSection = ({
  title,
  action,
  children,
}: PluginDetailSectionProps) => (
  <section className="flex w-full flex-col gap-md">
    <div
      className={cx(
        "flex items-center justify-between pl-md",
        action ? "min-h-7" : "min-h-5"
      )}
    >
      <h2 className="m-0 text-sm font-medium text-quaternary">{title}</h2>
      {action}
    </div>
    {children}
  </section>
);

const PluginDetailHeader = ({
  plugin,
  trailingContent,
}: {
  plugin: PluginDefinition;
  trailingContent?: ReactNode;
}) => (
  <article
    className="flex w-full items-center gap-lg rounded-xl p-md"
    data-slot="plugin-detail-header"
  >
    <PluginArtwork icon={plugin.icon} />
    <div className="flex min-w-0 flex-1 flex-col gap-xxs text-sm">
      <h1 className="m-0 truncate text-sm font-medium text-primary">{plugin.name}</h1>
      <span className="truncate text-quaternary">{plugin.summary}</span>
    </div>
    {trailingContent}
  </article>
);

export interface PluginDetailProps {
  plugin: PluginDefinition;
  backLabel?: string;
  copy?: Partial<PluginDetailCopy>;
  installLabel?: string;
  uninstallLabel?: string;
  tryInChatLabel?: string;
  installed?: boolean;
  installPending?: boolean;
  uninstallPending?: boolean;
  onBack?: () => void;
  onInstall?: (plugin: PluginDefinition) => void;
  onUninstall?: (plugin: PluginDefinition) => void;
  onTryInChat?: (plugin: PluginDefinition) => void;
  onManageMcps?: (plugin: PluginDefinition) => void;
  manageMcpsLabel?: string;
  manageMcpsDisabled?: boolean;
  manageMcpsMessage?: ReactNode;
  /** Extra header controls placed before the built-in installed actions. */
  headerActions?: ReactNode;
  /** Extra detail sections rendered after the built-in ones. */
  children?: ReactNode;
  className?: string;
}

export const PluginDetail = ({
  plugin,
  backLabel,
  copy,
  installLabel,
  uninstallLabel,
  tryInChatLabel,
  installed = false,
  installPending = false,
  uninstallPending = false,
  onBack,
  onInstall,
  onUninstall,
  onTryInChat,
  onManageMcps,
  manageMcpsLabel,
  manageMcpsDisabled = false,
  manageMcpsMessage,
  headerActions,
  children,
  className,
}: PluginDetailProps) => {
  const messages = useCommaMessages();
  const resolvedCopy = { ...defaultPluginDetailCopy(messages), ...copy };
  const resolvedBackLabel = backLabel ?? resolvedCopy.backLabel;
  const resolvedInstallLabel = installLabel ?? resolvedCopy.installLabel;
  const resolvedUninstallLabel = uninstallLabel ?? resolvedCopy.uninstallLabel;
  const resolvedTryInChatLabel = tryInChatLabel ?? resolvedCopy.tryInChatLabel;
  const installAriaLabel = copy?.installPluginAriaLabel
    ? copy.installPluginAriaLabel(plugin.name)
    : `${resolvedInstallLabel} ${plugin.name}`;
  const uninstallAriaLabel = copy?.uninstallPluginAriaLabel
    ? copy.uninstallPluginAriaLabel(plugin.name)
    : `${resolvedUninstallLabel} ${plugin.name}`;
  const tryInChatAriaLabel = copy?.tryPluginInChatAriaLabel
    ? copy.tryPluginInChatAriaLabel(plugin.name)
    : `${resolvedTryInChatLabel} ${plugin.name}`;
  const trailingContent = installed ? (
    headerActions || onUninstall || onTryInChat ? (
      <div className="flex min-w-0 flex-1 items-center justify-end gap-md">
        {headerActions}
        {onUninstall ? (
          <Button
            aria-label={uninstallAriaLabel}
            className="h-7 px-lg py-xs"
            hierarchy="tertiary-gray"
            iconLeading={
              uninstallPending ? <LoaderIcon className="animate-spin" /> : undefined
            }
            isDisabled={uninstallPending}
            onPress={() => onUninstall(plugin)}
            size="sm"
          >
            {resolvedUninstallLabel}
          </Button>
        ) : null}
        {onTryInChat ? (
          <Button
            aria-label={tryInChatAriaLabel}
            className="h-7 px-lg py-xs"
            hierarchy="primary"
            onPress={() => onTryInChat(plugin)}
            size="sm"
          >
            {resolvedTryInChatLabel}
          </Button>
        ) : null}
      </div>
    ) : null
  ) : onInstall ? (
    <div className="flex min-w-0 flex-1 items-center justify-end">
      <Button
        aria-label={installAriaLabel}
        className="h-7 px-lg py-xs"
        hierarchy="primary"
        iconLeading={
          installPending ? <LoaderIcon className="animate-spin" /> : undefined
        }
        isDisabled={installPending}
        onPress={() => onInstall(plugin)}
        size="sm"
      >
        {resolvedInstallLabel}
      </Button>
    </div>
  ) : null;

  return (
    <div
      className={cx(
        "relative flex size-full min-h-0 min-w-0 justify-center bg-primary",
        className
      )}
      data-slot="plugin-detail"
    >
      <ScrollArea
        className="size-full"
        contentClassName="min-h-full"
        edgeEffect="mask"
        edgeMask={{ startSize: 0, endSize: 24 }}
        orientation="vertical"
        scrollbarVisibility="scroll"
      >
        <div className="mx-auto flex w-full max-w-[700px] flex-col gap-2xl pb-3xl pt-7xl">
          {onBack ? (
            <div className="px-md">
              <Button
                // Offsets the button's own inline padding so the arrow sits on the content edge.
                className="-ml-3"
                hierarchy="tertiary-gray"
                iconLeading={<ArrowLeftIcon />}
                onPress={onBack}
                size="sm"
              >
                {resolvedBackLabel}
              </Button>
            </div>
          ) : null}
          <PluginDetailHeader plugin={plugin} trailingContent={trailingContent} />
          {plugin.description ? (
            <PluginDetailSection title={resolvedCopy.descriptionLabel}>
              <p className="m-0 px-md text-sm text-secondary">{plugin.description}</p>
            </PluginDetailSection>
          ) : null}
          {plugin.mcps?.length ? (
            <PluginDetailSection
              action={
                onManageMcps ? (
                  <Button
                    className="h-7 px-lg py-xs text-sidebar-text-highlight"
                    hierarchy="tertiary-gray"
                    isDisabled={manageMcpsDisabled}
                    onPress={() => onManageMcps(plugin)}
                    size="sm"
                  >
                    {manageMcpsLabel ?? resolvedCopy.manageLabel}
                  </Button>
                ) : null
              }
              title={resolvedCopy.mcpsLabel}
            >
              {manageMcpsMessage ? (
                <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
                  {manageMcpsMessage}
                </output>
              ) : null}
              <ul className="m-0 flex list-none flex-col gap-xs p-0">
                {plugin.mcps.map((resource) => (
                  <PluginResourceRow key={resource.id} resource={resource} />
                ))}
              </ul>
            </PluginDetailSection>
          ) : null}
          {plugin.skills?.length ? (
            <PluginDetailSection title={resolvedCopy.skillsLabel}>
              <ul className="m-0 flex list-none flex-col gap-xs p-0">
                {plugin.skills.map((resource) => (
                  <PluginResourceRow
                    key={resource.id}
                    resource={{
                      icon: <CubeIcon className="text-fg-tertiary" />,
                      ...resource,
                    }}
                  />
                ))}
              </ul>
            </PluginDetailSection>
          ) : null}
          {children}
        </div>
      </ScrollArea>
    </div>
  );
};
