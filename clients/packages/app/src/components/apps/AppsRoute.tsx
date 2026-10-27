import { useCall, useTopic, type MiniApp } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import {
  LayoutGridIcon,
  ListBulletsIcon,
  MoreHorizontalIcon,
  PlusIcon,
  SearchIcon,
  SquareGridCircleIcon,
} from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  menuCompactClasses,
} from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { cx } from "@comma/ui/components/utils";
import { useNavigate } from "@tanstack/react-router";
import {
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
} from "react";
import { useActiveWorkspaceId } from "../activeWorkspace";
import {
  appsSidebarHost,
  useOptionalChatSidebar,
  useRegisterChatSidebarHost,
} from "../chat-sidebar/ChatSidebarContext";
import { animateSuggestionAcceptance } from "../chat/suggestions/suggestionAcceptanceMotion";
import { useMiniAppHomeDraft } from "./miniAppHomeDraft";
import { useMiniAppIcon, useMiniAppImage } from "./miniAppIcon";
import { useMiniAppOpenActions, type MiniAppOpenTarget } from "./miniAppOpen";
import {
  MiniAppSettingsDialog,
  type MiniAppSettingsTarget,
} from "./MiniAppSettingsDialog";

type AppsView = "gallery" | "list";

/** The view the reader last picked, for the rest of this session. */
let lastView: AppsView = "gallery";

/**
 * The Apps page, laid out as Plugins is: a large title, then search, New app and the gallery / list switch. It lists
 * the Workspace's own apps and the shared apps it added. An app opens in the right panel beside the page; its settings
 * open over it. Both also open from their own address (`openFor`, the Router's app link, and `settingsFor`).
 */
export function AppsRoute({
  settingsFor,
  openFor,
}: {
  settingsFor?: MiniAppSettingsTarget | undefined;
  openFor?: MiniAppOpenTarget | undefined;
}) {
  const messages = useCommaMessages();
  const workspace = useActiveWorkspaceId();
  const call = useCall();
  const navigate = useNavigate();
  const newApp = useNewApp();
  // The right panel shows the page's apps while the page is on screen.
  useRegisterChatSidebarHost(appsSidebarHost);
  const { value } = useTopic(workspace ? { topic: "miniApps", workspace } : null);
  const [chosen, setChosen] = useState<string>();
  const [query, setQuery] = useState("");
  const [view, setView] = useState(lastView);
  const apps = value?.apps ?? [];
  const needle = query.trim().toLocaleLowerCase();
  const shown = needle
    ? apps.filter((app) =>
        `${app.name}\n${app.description}`.toLocaleLowerCase().includes(needle)
      )
    : apps;
  const settings =
    settingsFor ??
    (chosen && workspace ? { workspaceId: workspace, appId: chosen } : undefined);
  const chooseView = (next: AppsView) => {
    lastView = next;
    setView(next);
  };

  let body: ReactNode;
  if (!value || (value.status === "loading" && apps.length === 0)) {
    body = <LoadingIndicator label={messages.mini_apps_loading()} />;
  } else if (value.status === "failed" && apps.length === 0) {
    body = (
      <div className="flex items-center justify-between gap-md px-md">
        <p className="text-sm text-error-primary" role="alert">
          {messages.mini_apps_load_failed()}
        </p>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            workspace && void call("miniApps.refresh", { workspace }).catch(() => {})
          }
          size="sm"
        >
          {messages.mini_apps_retry()}
        </Button>
      </div>
    );
  } else if (apps.length === 0) {
    body = (
      <div className="flex flex-col items-center gap-lg px-md py-7xl text-center">
        <span className="flex size-12 items-center justify-center rounded-xl bg-secondary">
          <SquareGridCircleIcon className="size-6 text-fg-secondary" />
        </span>
        <div className="flex flex-col gap-xs">
          <h2 className="text-md font-medium text-primary">
            {messages.mini_apps_empty_title()}
          </h2>
          <p className="max-w-(--container-xs) text-sm text-balance text-tertiary">
            {messages.mini_apps_empty()}
          </p>
        </div>
        <Button hierarchy="primary" onPress={newApp} size="sm">
          {messages.mini_apps_new()}
        </Button>
      </div>
    );
  } else if (shown.length === 0) {
    body = (
      <p className="px-md text-sm text-tertiary">
        {messages.mini_apps_no_match({ query: query.trim() })}
      </p>
    );
  } else {
    const entries = shown.map((app) => (
      <AppEntry
        app={app}
        key={app.id}
        onSettings={() => setChosen(app.id)}
        view={view}
        workspace={workspace!}
      />
    ));
    body =
      view === "gallery" ? (
        <ul className="grid grid-cols-[repeat(auto-fill,minmax(min(100%,12rem),1fr))] gap-lg">
          {entries}
        </ul>
      ) : (
        <ul className="flex flex-col gap-xxs">{entries}</ul>
      );
  }

  return (
    <div
      className="flex min-h-0 min-w-0 flex-1 flex-col bg-primary"
      data-testid="apps-route"
    >
      <ScrollArea
        className="size-full"
        contentClassName="min-h-full"
        edgeEffect="mask"
        edgeMask={{ startSize: 0, endSize: 24 }}
        orientation="vertical"
        scrollbarVisibility="scroll"
      >
        {/* The Plugins page's column, so the two pages' titles sit in one place. */}
        {/* A gutter keeps the column off the panel's edges once the window is narrower than it. */}
        <div className="px-xl">
          <div className="mx-auto flex w-full max-w-[700px] flex-col gap-xl pb-3xl pt-7xl">
            <header className="flex flex-col gap-md px-md">
              <div className="flex flex-wrap items-center gap-md">
                <h1 className="m-0 me-auto text-balance text-xl font-medium text-primary">
                  {messages.mini_apps_title()}
                </h1>
                {apps.length > 0 ? (
                  <InputField
                    aria-label={messages.mini_apps_search()}
                    fieldSize="sm"
                    leadingIcon={<SearchIcon className="size-5" />}
                    onChange={(event) => setQuery(event.target.value)}
                    placeholder={messages.mini_apps_search_placeholder()}
                    // A click leaves the field quiet; keyboard focus keeps its ring.
                    suppressFocusRing
                    value={query}
                    wrapperClassName="data-[focus-visible]:ring-2 data-[focus-visible]:ring-border-brand data-[focus-visible]:shadow-focus-brand-shadow-xs"
                  />
                ) : null}
                <Button
                  hierarchy="primary"
                  iconLeading={<PlusIcon />}
                  onPress={newApp}
                  size="sm"
                >
                  {messages.mini_apps_new()}
                </Button>
              </div>
              {apps.length > 0 ? (
                <fieldset
                  aria-label={messages.mini_apps_view()}
                  className="m-0 flex items-center justify-end gap-xxs border-0 p-0"
                >
                  <ViewButton
                    current={view}
                    icon={<LayoutGridIcon className="size-4" />}
                    label={messages.mini_apps_view_gallery()}
                    onPress={chooseView}
                    view="gallery"
                  />
                  <ViewButton
                    current={view}
                    icon={<ListBulletsIcon className="size-4" />}
                    label={messages.mini_apps_view_list()}
                    onPress={chooseView}
                    view="list"
                  />
                </fieldset>
              ) : null}
            </header>
            {body}
          </div>
        </div>
      </ScrollArea>
      {openFor ? (
        <OpenFromAddress
          key={`${openFor.workspaceId}/${openFor.appId}`}
          target={openFor}
        />
      ) : null}
      {settings ? (
        <MiniAppSettingsDialog
          {...settings}
          onClose={() => {
            if (settingsFor) void navigate({ to: "/apps" });
            else setChosen(undefined);
          }}
        />
      ) : null}
    </div>
  );
}

/** One of the two view buttons: icon only, named for screen readers, gray while chosen. */
function ViewButton({
  view,
  current,
  icon,
  label,
  onPress,
}: {
  view: AppsView;
  current: AppsView;
  icon: ReactNode;
  label: string;
  onPress: (view: AppsView) => void;
}) {
  const pressed = view === current;
  return (
    <button
      aria-label={label}
      aria-pressed={pressed}
      className={cx(
        "flex size-8 cursor-pointer items-center justify-center rounded-full border-0 outline-none transition-colors focus-visible:shadow-focus-gray",
        pressed
          ? "bg-secondary text-primary"
          : "bg-transparent text-quaternary hover:text-secondary"
      )}
      onClick={() => onPress(view)}
      title={label}
      type="button"
    >
      {icon}
    </button>
  );
}

/**
 * Prefills Home's composer with the start of a request to build an app, goes there, runs the composer's shimmer wave
 * across it once and leaves the caret at its end, so the viewer finishes the sentence and sends it. Nothing is sent.
 */
function useNewApp() {
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const draft = useMiniAppHomeDraft();
  return () => {
    const prompt = messages.mini_apps_new_prompt();
    void (draft?.(prompt) ?? Promise.resolve())
      .catch(() => undefined)
      .then(() => navigate({ to: "/" }))
      .then(() =>
        uiClock.frame(() => {
          const editor = document.querySelector<HTMLElement>(
            '.comma-chat-composer-frame [contenteditable="true"]'
          );
          if (!editor) return;
          editor.focus();
          // The composer may write the draft into the editor after this frame, which would leave the caret before it:
          // the caret goes to the end once the request is there.
          whenShowing(editor, prompt.trimEnd(), () => {
            const selection = editor.ownerDocument.getSelection();
            selection?.selectAllChildren(editor);
            selection?.collapseToEnd();
            // The composer's acceptance wave, once: the request just arrived in it. It ends on the first key.
            animateSuggestionAcceptance(editor);
          });
        })
      );
  };
}

/** Runs `then` once `editor` shows `text`: now, or when the composer writes it; a key typed first cancels it. */
function whenShowing(editor: HTMLElement, text: string, then: () => void) {
  const showing = () => (editor.textContent ?? "").startsWith(text);
  if (showing()) {
    then();
    return;
  }
  const stop = () => {
    observer.disconnect();
    editor.removeEventListener("keydown", stop);
  };
  const observer = new MutationObserver(() => {
    if (!showing()) return;
    stop();
    then();
  });
  observer.observe(editor, { childList: true, characterData: true, subtree: true });
  editor.addEventListener("keydown", stop);
}

const NEAR_VIEW_PX = 480;

/**
 * Whether `ref`'s element is within 480px of the page's view (its scroll area). Once it is, it stays: a card's cover is
 * read then, so a long gallery reads only the covers a reader comes near. A card already near is seen so before its
 * first paint, so a cover shown a moment ago shows with its card.
 */
function useNearView(ref: RefObject<Element | null>, enabled: boolean): boolean {
  const [near, setNear] = useState(false);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!enabled || near || !element) return;
    if (typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    const root = element.closest('[data-slot="scroll-area-viewport"]');
    const view = root?.getBoundingClientRect() ?? {
      top: 0,
      bottom: window.innerHeight,
    };
    const box = element.getBoundingClientRect();
    if (
      box.bottom >= view.top - NEAR_VIEW_PX &&
      box.top <= view.bottom + NEAR_VIEW_PX
    ) {
      setNear(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) setNear(true);
      },
      { root, rootMargin: `${NEAR_VIEW_PX}px 0px` }
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [enabled, near, ref]);
  return near;
}

/**
 * One app, as a gallery card (its thumbnail, then its name and one line on it) or a list row (its icon, name and
 * line). A press opens the app in the right panel (its latest preview while it is not published), or its settings while
 * it cannot run. Its state (not published, disabled) leads the line, in words.
 */
function AppEntry({
  app,
  workspace,
  view,
  onSettings,
}: {
  app: MiniApp;
  workspace: string;
  view: AppsView;
  onSettings: () => void;
}) {
  const messages = useCommaMessages();
  const open = useMiniAppOpenActions();
  const sidebar = useOptionalChatSidebar();
  // Until the app is published, the server runs its latest ready preview for its own Workspace; for anyone else, nothing.
  const runnable =
    app.status === "active" &&
    (app.live_version !== null ||
      (app.workspace_id === workspace && app.latest_version !== null));
  const target = { appId: app.id, workspaceId: workspace };
  const openBeside = () => {
    if (sidebar) sidebar.openApp(appsSidebarHost, { ...target, name: app.name });
    else open.inPanel(target);
  };
  const nameId = useId();
  const metaId = useId();
  const state =
    app.status === "disabled"
      ? messages.mini_apps_disabled_badge()
      : app.live_version === null
        ? messages.mini_apps_no_live_version()
        : app.installed
          ? messages.mini_apps_installed_badge()
          : "";
  const about =
    app.description || messages.mini_app_by_author({ author: app.author.name });
  const meta = [state, about].filter(Boolean).join(" · ");
  const iconUrl = useMiniAppIcon(app.icon_url, { workspace });
  const card = useRef<HTMLLIElement>(null);
  const gallery = view === "gallery";
  const coverUrl = useMiniAppImage(
    gallery ? app.cover_url : null,
    { workspace },
    useNearView(card, gallery && app.cover_url !== null)
  );
  const icon = (size: "gallery" | "list") =>
    iconUrl ? (
      <img
        alt=""
        className={cx(
          "object-cover outline-1 -outline-offset-1 outline-black/10 dark:outline-white/10",
          size === "gallery" ? "size-12 rounded-xl" : "size-8 rounded-lg"
        )}
        src={iconUrl}
      />
    ) : (
      <SquareGridCircleIcon
        className={cx("text-fg-quaternary", size === "gallery" ? "size-8" : "size-5")}
      />
    );
  const text = (
    <span className="flex min-w-0 flex-1 flex-col gap-xxs">
      <span
        className="truncate text-sm font-medium text-primary"
        id={nameId}
        title={app.name}
      >
        {app.name}
      </span>
      <span className="truncate text-xs text-tertiary" id={metaId} title={meta}>
        {meta}
      </span>
    </span>
  );
  const press = () => (runnable ? openBeside() : onSettings());
  const actions = (
    <MenuTrigger>
      <Button
        aria-describedby={nameId}
        aria-label={messages.mini_app_actions()}
        className={cx(
          "pointer-fine:opacity-0 pointer-fine:group-focus-within:opacity-100 pointer-fine:group-hover:opacity-100 aria-expanded:opacity-100",
          view === "gallery"
            ? "absolute top-sm right-sm"
            : "absolute top-1/2 right-md -translate-y-1/2"
        )}
        hierarchy={view === "gallery" ? "secondary-gray" : "tertiary-gray"}
        iconLeading={<MoreHorizontalIcon />}
        iconOnly
        size="xs"
      />
      <MenuPopover placement="bottom end">
        <Menu
          aria-label={messages.mini_app_actions()}
          className={menuCompactClasses}
          disabledKeys={runnable ? [] : ["open", "window"]}
          onAction={(key) => {
            if (key === "open") openBeside();
            else if (key === "window") void open.window(target);
            else onSettings();
          }}
        >
          <MenuItem id="open">{messages.mini_app_open()}</MenuItem>
          {open.canOpenWindow ? (
            <MenuItem id="window">{messages.mini_app_open_in_window()}</MenuItem>
          ) : null}
          <MenuItem id="settings">{messages.mini_app_settings()}</MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );

  if (view === "list") {
    return (
      <li className="group relative flex min-w-0" data-testid="apps-row">
        <button
          aria-describedby={metaId}
          aria-labelledby={nameId}
          className="flex w-full min-w-0 cursor-pointer items-center gap-md rounded-lg px-md py-sm pe-5xl text-left outline-none hover:bg-secondary focus-visible:shadow-focus-gray"
          onClick={press}
          type="button"
        >
          <span
            aria-hidden
            className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-tertiary"
          >
            {icon("list")}
          </span>
          {text}
        </button>
        {actions}
      </li>
    );
  }

  return (
    <li className="group relative flex min-w-0" data-testid="apps-card" ref={card}>
      <button
        aria-describedby={metaId}
        aria-labelledby={nameId}
        className="group/cover flex w-full min-w-0 cursor-pointer flex-col gap-md rounded-xl text-left outline-none focus-visible:shadow-focus-gray"
        onClick={press}
        type="button"
      >
        {/* The thumbnail is a gray box holding a page sheet, set in a fifth from the sides and top and cut off by the
            bottom edge as a first screen is. The sheet shows the Version's cover (its first screen), top first; an
            app without one shows its icon, or the missing-artwork glyph. A cover that is still loading leaves the
            sheet empty, so no glyph shows before it. The name and its line sit under the box, on the page. */}
        <span
          aria-hidden
          className="relative block aspect-video w-full overflow-hidden rounded-xl bg-tertiary ring-1 ring-secondary group-hover/cover:bg-quaternary"
        >
          <span className="absolute inset-x-1/5 top-1/5 bottom-0 flex items-center justify-center overflow-hidden rounded-t-lg bg-primary">
            {coverUrl === undefined ? null : coverUrl === null ? (
              icon("gallery")
            ) : (
              <img
                alt=""
                className="size-full object-cover object-top"
                data-testid="apps-card-cover"
                decoding="async"
                draggable={false}
                src={coverUrl}
              />
            )}
          </span>
        </span>
        <span className="flex w-full min-w-0 px-xxs">{text}</span>
      </button>
      {actions}
    </li>
  );
}

/**
 * An app's own address (the link the Router gives): opens the app in the right panel once its name is known, then
 * leaves the address for the gallery's, so going back does not open it again.
 */
function OpenFromAddress({ target }: { target: MiniAppOpenTarget }) {
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const sidebar = useOptionalChatSidebar();
  const { value } = useTopic({
    topic: "miniApp",
    workspace: target.workspaceId,
    app: target.appId,
  });
  const name = value?.status === "ready" ? value.app?.name : undefined;
  const settled = value !== undefined && value.status !== "loading";
  useEffect(() => {
    if (!settled) return;
    if (name) sidebar?.openApp(appsSidebarHost, { ...target, name });
    // A link to an app that is gone or could not be read says so, rather than leaving only the gallery.
    else
      toast.error(
        value?.status === "missing"
          ? messages.mini_app_unavailable_title()
          : messages.mini_apps_load_failed()
      );
    void navigate({ to: "/apps", replace: true });
    // Once, when the app's record settles.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settled]);
  return null;
}
