import { useCommaMessages } from "@comma/i18n/react";
import { LoaderIcon, PluginArtwork, ScrollArea, motionDuration } from "@comma/ui";
import { useLayoutEffect, useState } from "react";
import { useLeaving } from "../../chat/motion/useLeaving";
import { PluginBrandArtwork } from "../../plugins/PluginBrandArtwork";
import { OnboardingCardFooter, OnboardingPrimaryButton } from "../OnboardingCard";
import { OnboardingRowAction } from "../OnboardingRowAction";
import type {
  OnboardingPluginList,
  OnboardingPluginRow,
} from "../useOnboardingPlugins";

type Messages = ReturnType<typeof useCommaMessages>;

const skeletonRows = 4;

/**
 * The apps card: the workspace's integrations, each connected by signing in
 * in the browser. Until they arrive, the list holds the height it was given,
 * so nothing jumps. While an app's sign-in is open, a line under its row
 * says where to finish it. Another Connect replaces the sign-in in flight;
 * every Connect stays at full contrast.
 */
export function OnboardingAppsPanel({
  fits,
  list,
  onConnect,
  onContinue,
  onRowHeight,
}: {
  list: OnboardingPluginList;
  /** Every app fits in the card; otherwise the list scrolls inside it. */
  fits: boolean;
  onConnect: (pluginId: string) => void;
  /** The primary action; the item is done once an app is connected. */
  onContinue: () => void;
  /** A row's rendered height, which the font size sets; see `useRowHeight`. */
  onRowHeight: (height: number) => void;
}) {
  const connected =
    list.status === "ready" && list.rows.some((row) => row.connection === "connected");

  return (
    <>
      <div className="comma-onboarding-card__content">
        <OnboardingAppsList
          fits={fits}
          list={list}
          onConnect={onConnect}
          onRowHeight={onRowHeight}
        />
      </div>
      <OnboardingCardFooter
        primary={<OnboardingPrimaryButton done={connected} onPress={onContinue} />}
      />
    </>
  );
}

function OnboardingAppsList({
  fits,
  list,
  onConnect,
  onRowHeight,
}: {
  fits: boolean;
  list: OnboardingPluginList;
  onConnect: (pluginId: string) => void;
  onRowHeight: (height: number) => void;
}) {
  const messages = useCommaMessages();
  const [firstRow, setFirstRow] = useState<HTMLElement | null>(null);
  useRowHeight(firstRow, onRowHeight);

  switch (list.status) {
    case "unavailable":
      return (
        <p className="comma-onboarding-apps__failed" role="alert">
          {messages.onboarding_apps_load_failed()}
        </p>
      );
    case "preparing":
      return (
        <output className="comma-onboarding-apps__placeholder">
          <LoaderIcon className="comma-onboarding-spinner animate-spin" />
          {list.unreachable
            ? messages.onboarding_workspace_unreachable()
            : messages.onboarding_workspace_preparing()}
        </output>
      );
    case "loading":
      return (
        <output
          aria-busy="true"
          aria-label={messages.common_loading()}
          className="comma-onboarding-apps__placeholder"
          data-kind="loading"
        >
          {Array.from({ length: skeletonRows }, (_, index) => (
            <span className="comma-onboarding-apps__skeleton" key={index}>
              <span className="comma-onboarding-apps__skeleton-art" />
              <span className="comma-onboarding-apps__skeleton-lines">
                <span />
                <span />
              </span>
            </span>
          ))}
        </output>
      );
    case "ready":
      if (list.rows.length === 0) {
        return (
          <p className="comma-onboarding-apps__failed">
            {messages.onboarding_apps_none()}
          </p>
        );
      }
      return (
        <ScrollArea
          className="comma-onboarding-apps"
          data-fits={fits || undefined}
          edgeEffect="mask"
          orientation="vertical"
          // Every row's action is a tab stop that scrolls it into view; the
          // list itself is not one more.
          viewportProps={{ tabIndex: -1 }}
        >
          <ul
            aria-label={messages.onboarding_apps_list()}
            className="comma-onboarding-apps__list"
          >
            {list.rows.map((row, index) => (
              <li className="comma-onboarding-apps__item" key={row.id}>
                <OnboardingAppRow
                  messages={messages}
                  onConnect={onConnect}
                  row={row}
                  rowRef={index === 0 ? setFirstRow : undefined}
                />
              </li>
            ))}
          </ul>
        </ScrollArea>
      );
  }
}

/**
 * One app, in the plugin list's row geometry: its logo, its name over what it
 * lets Comma work with, and its action; while its sign-in is open, a line
 * under it says where to finish.
 */
function OnboardingAppRow({
  messages,
  onConnect,
  row,
  rowRef,
}: {
  messages: Messages;
  onConnect: (pluginId: string) => void;
  row: OnboardingPluginRow;
  rowRef: ((element: HTMLElement | null) => void) | undefined;
}) {
  const connecting = row.connection === "connecting";
  // The line under the row closes as it opened, then goes.
  const closing = useLeaving(connecting, motionDuration.stateChange) === true;
  return (
    <>
      <article className="comma-onboarding-app" data-plugin-id={row.id} ref={rowRef}>
        <PluginArtwork
          icon={<PluginBrandArtwork brand={row.brand} name={row.name} />}
        />
        <span className="comma-onboarding-app__text">
          <span className="comma-onboarding-app__name">{row.name}</span>
          <span className="comma-onboarding-app__summary">
            {appSummary(row, messages)}
          </span>
        </span>
        <OnboardingRowAction
          actionAriaLabel={messages.onboarding_apps_connect_named({ app: row.name })}
          actionLabel={messages.onboarding_apps_connect()}
          doneLabel={messages.onboarding_apps_connected()}
          onAction={() => onConnect(row.id)}
          pendingLabel={messages.onboarding_apps_connecting()}
          state={
            row.connection === "connected" ? "done" : connecting ? "pending" : "idle"
          }
        />
      </article>
      {connecting || closing ? (
        <div
          aria-hidden={!connecting || undefined}
          className="comma-onboarding-app__hint"
          data-open={connecting || undefined}
        >
          <div>
            <p>{messages.onboarding_apps_pending()}</p>
          </div>
        </div>
      ) : null}
    </>
  );
}

/**
 * Reports `row`'s rendered height, and again whenever it changes. A row's text
 * follows the font size preference, so a larger one makes every row taller
 * than its logo: the list is sized from this height to keep its half row.
 * One row is watched, never each.
 */
function useRowHeight(row: HTMLElement | null, onRowHeight: (height: number) => void) {
  useLayoutEffect(() => {
    if (!row || typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(([entry]) => {
      const height = entry?.borderBoxSize[0]?.blockSize;
      if (height) onRowHeight(height);
    });
    observer.observe(row);
    return () => observer.disconnect();
  }, [onRowHeight, row]);
}

/**
 * What an app lets Comma work with, in plain words and the reader's language,
 * for the integrations most people connect first; any other shows the
 * catalog's own summary.
 */
function appSummary(row: OnboardingPluginRow, messages: Messages) {
  switch (row.id) {
    case "google":
      return messages.onboarding_apps_about_google();
    case "github":
      return messages.onboarding_apps_about_github();
    case "notion":
      return messages.onboarding_apps_about_notion();
    case "slack":
      return messages.onboarding_apps_about_slack();
    case "linear":
      return messages.onboarding_apps_about_linear();
    case "feishu":
      return messages.onboarding_apps_about_feishu();
    default:
      return row.summary;
  }
}

/** The plugin ids of the apps connected in `list`, in list order. */
export function onboardingConnectedAppIds(list: OnboardingPluginList): string[] {
  return list.status === "ready"
    ? list.rows.filter((row) => row.connection === "connected").map((row) => row.id)
    : [];
}

/** The apps connected in `list`, by name, in list order. */
export function onboardingConnectedApps(list: OnboardingPluginList): string[] {
  return list.status === "ready"
    ? list.rows.filter((row) => row.connection === "connected").map((row) => row.name)
    : [];
}
