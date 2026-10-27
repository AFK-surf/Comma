/* eslint-disable unicorn/require-post-message-target-origin -- MessagePort messages take no origin. */
import type {
  MiniAppFramePortMessage,
  MiniAppInit,
} from "@comma/chat-contract/mini-app-runtime";
import {
  miniAppFrameSandbox,
  miniAppRuntimeUrl,
  miniAppWebRuntimePath,
} from "@comma/chat-contract/mini-app-runtime";
import {
  useCall,
  useTopic,
  type MiniAppInvokeResult,
  type MiniAppSessionInfo,
  type MiniAppVia,
} from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { Dialog } from "@comma/ui/components/dialog";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import {
  MiniAppChrome,
  MiniAppConfirmSheet,
  MiniAppGrantSheet,
  MiniAppNotice,
  type MiniAppChromeAction,
  type MiniAppChromeProps,
} from "@comma/ui/components/mini-apps";
import { toast } from "@comma/ui/components/toast";
import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../../nativePlatformActions";
import { useActiveWorkspaceId } from "../activeWorkspace";
import { useCommaUiThemeName } from "../commaUiTheme";
import { useMiniAppHomeDraft } from "./miniAppHomeDraft";
import { useMiniAppIcon } from "./miniAppIcon";

/** Where an app's `chat.draft` text goes: the chat the app runs beside, else Home's composer (`useMiniAppHomeDraft`). */
export const MiniAppDraftContext = createContext<
  ((text: string) => void | Promise<void>) | undefined
>(undefined);

/** The runtime document's URL on this platform: Main's `comma-app` scheme on Mac, the web origin's static route. */
export function miniAppRuntimeSrc(): string {
  return getNativeBridge().platform === "electron"
    ? miniAppRuntimeUrl
    : new URL(miniAppWebRuntimePath, window.location.origin).href;
}

export const MINI_APP_MAX_RUNNING = 3;
export const MINI_APP_START_TIMEOUT_MS = 10_000;
const PING_EVERY_MS = 1000;
const STALL_AFTER_MS = 5000;
const MAX_PICKED_FILES = 10;
const MAX_PICKED_BYTES = 20 * 1_048_576;

/**
 * Frames that run an app now, oldest first: a fourth stops a kept frame waiting off screen, else the oldest (it can run
 * again from its notice).
 */
const running = new Map<symbol, { stop: () => void; parked: () => boolean }>();
function acquirePlace(
  key: symbol,
  stop: () => void,
  parked: () => boolean
): () => void {
  running.delete(key);
  while (running.size >= MINI_APP_MAX_RUNNING) {
    const [victim, place] =
      [...running].find(([, held]) => held.parked()) ?? running.entries().next().value!;
    running.delete(victim);
    place.stop();
  }
  running.set(key, { stop, parked });
  return () => {
    running.delete(key);
  };
}

/** How long a kept frame waits off screen for its host to come back before it stops. */
const KEPT_FOR_MS = 5 * 60_000;

/**
 * A running app kept across its host's unmount (a chat card left by a page switch): its frame, session and broker live
 * under the keeper, in `node`, which moves into the host's slot while one shows it and off screen while none does.
 */
type KeptFrame = {
  /** The host's key, and the keeper's (the host's within the account). */
  hostKey: string;
  key: string;
  info: MiniAppSessionInfo;
  inert: boolean;
  node: HTMLDivElement;
  /** Where its `chat.draft` goes: the last host's. */
  draft: { current: ((text: string) => void | Promise<void>) | undefined };
  /** The host that shows it now, told when the app ends; none while it waits off screen. */
  onEnd: ((next: State) => void) | undefined;
  parked: boolean;
  expire: CancelUiTimer | undefined;
};

type FrameKeeper = {
  /** The frame kept under `key` that waits for a host, if any. */
  parked(key: string): KeptFrame | undefined;
  /** Keeps a session that just opened under `key`; undefined while another host holds that key. */
  keep(key: string, info: MiniAppSessionInfo, inert: boolean): KeptFrame | undefined;
  /** Moves the frame into `slot`; false when it ended or another host took it first. */
  show(frame: KeptFrame, slot: HTMLElement, onEnd: (next: State) => void): boolean;
  /** Moves the frame off screen, where it runs until a host shows it again, it loses its place, or it expires. */
  park(frame: KeptFrame): void;
};

type Movable = Element & { moveBefore?: (node: Node, child: Node | null) => void };

const FrameKeeperContext = createContext<FrameKeeper | null>(null);

/**
 * Keeps the apps of hosts that ask for it (`keepKey`) running when those hosts unmount, so a page switch back shows the
 * same frame at once instead of opening a session, starting the app and reading its data again. A frame moves between
 * its host and the off-screen lot with `moveBefore`, which keeps its document; where that is missing nothing is kept.
 * Kept frames count against `MINI_APP_MAX_RUNNING` and go first when a new frame needs a place. They belong to the
 * signed-in `account`: another account finds none, and a switch stops them all.
 */
export function MiniAppFrameKeeper({
  account,
  children,
}: {
  account: string;
  children: ReactNode;
}) {
  const call = useCall();
  const lot = useRef<HTMLDivElement>(null);
  const accountRef = useRef(account);
  accountRef.current = account;
  const [frames, setFrames] = useState<readonly KeptFrame[]>([]);
  const [keeper] = useState(() => {
    if (typeof Element === "undefined" || !("moveBefore" in Element.prototype))
      return null;
    const kept = new Map<string, KeptFrame>();
    const scoped = (key: string) => `${accountRef.current}\u0000${key}`;
    const move = (parent: Element, frame: KeptFrame) =>
      (parent as Movable).moveBefore!(frame.node, null);
    const drop = (frame: KeptFrame) => {
      if (kept.get(frame.key) !== frame) return;
      kept.delete(frame.key);
      frame.expire?.();
      frame.node.remove();
      setFrames([...kept.values()]);
      void call("miniApps.session.close", { session: frame.info.session }).catch(
        () => {}
      );
    };
    const wait = (frame: KeptFrame) => {
      frame.parked = true;
      frame.onEnd = undefined;
      frame.expire = uiClock.after(KEPT_FOR_MS, () => drop(frame));
    };
    /** The app ended: its host, if one shows it, shows how. */
    const ended = (frame: KeptFrame, next: State) => {
      const host = frame.onEnd;
      drop(frame);
      host?.(next);
    };
    const api: FrameKeeper & {
      ended: (frame: KeptFrame, next: State) => void;
      dropAll: () => void;
    } = {
      parked: (key) => {
        const frame = kept.get(scoped(key));
        return frame?.parked ? frame : undefined;
      },
      keep: (hostKey, info, inert) => {
        const key = scoped(hostKey);
        if (kept.has(key) || !lot.current) return undefined;
        const node = document.createElement("div");
        node.className = "relative flex min-h-0 flex-1 flex-col";
        lot.current.append(node);
        const frame: KeptFrame = {
          hostKey,
          key,
          info,
          inert,
          node,
          draft: { current: undefined },
          onEnd: undefined,
          parked: true,
          expire: undefined,
        };
        wait(frame);
        kept.set(key, frame);
        setFrames([...kept.values()]);
        return frame;
      },
      show: (frame, slot, onEnd) => {
        if (kept.get(frame.key) !== frame || !frame.parked) return false;
        frame.expire?.();
        frame.expire = undefined;
        frame.parked = false;
        frame.onEnd = onEnd;
        frame.node.style.width = "";
        frame.node.style.height = "";
        move(slot, frame);
        return true;
      },
      park: (frame) => {
        if (kept.get(frame.key) !== frame || frame.parked) return;
        // Off screen at the size it had, so the app does not lay out again on the way out or back.
        frame.node.style.width = `${frame.node.offsetWidth}px`;
        frame.node.style.height = `${frame.node.offsetHeight}px`;
        move(lot.current!, frame);
        wait(frame);
      },
      ended,
      dropAll: () =>
        [...kept.values()].forEach((frame) => ended(frame, { status: "stopped" })),
    };
    return api;
  });
  useEffect(() => () => keeper?.dropAll(), [keeper, account]);

  return (
    <FrameKeeperContext.Provider value={keeper}>
      {children}
      {/* The lot: off screen and hidden, so a kept app neither paints nor takes input or focus. */}
      <div
        aria-hidden
        className="pointer-events-none invisible fixed top-0"
        inert
        ref={lot}
        style={{ left: "-100000px" }}
      />
      {keeper
        ? frames.map((frame) =>
            createPortal(
              <MiniAppDraftContext.Provider
                value={(text) => frame.draft.current?.(text)}
              >
                <RunningFrame
                  info={frame.info}
                  inert={frame.inert}
                  onEnd={(next) => keeper.ended(frame, next)}
                  parked={() => frame.parked}
                />
              </MiniAppDraftContext.Provider>,
              frame.node,
              frame.key
            )
          )
        : null}
    </FrameKeeperContext.Provider>
  );
}

/** The host's place for a kept frame: the frame moves in while the host shows it and out to the lot when it unmounts. */
function KeptFrameSlot({
  frame,
  onEnd,
  onLost,
}: {
  frame: KeptFrame;
  onEnd: (next: State) => void;
  onLost: () => void;
}) {
  const keeper = useContext(FrameKeeperContext)!;
  const slot = useRef<HTMLDivElement>(null);
  const draft = useContext(MiniAppDraftContext);
  const homeDraft = useMiniAppHomeDraft();
  const sendDraft = draft ?? homeDraft;
  useLayoutEffect(() => {
    frame.draft.current = sendDraft;
  }, [frame, sendDraft]);
  const onEndRef = useRef(onEnd);
  onEndRef.current = onEnd;
  const onLostRef = useRef(onLost);
  onLostRef.current = onLost;
  useLayoutEffect(() => {
    if (!keeper.show(frame, slot.current!, (next) => onEndRef.current(next))) {
      onLostRef.current();
      return;
    }
    return () => keeper.park(frame);
  }, [keeper, frame]);
  return <div className="relative flex min-h-0 flex-1 flex-col" ref={slot} />;
}

/**
 * The design tokens an app's styles read, under `--comma-*` so they never override an app's own variables (shadcn/ui's
 * `--muted` and `--accent` are surfaces; `--comma-muted` is a text color): each resolved from this window's theme by
 * the CSS property that computes it. An app follows Comma's design system by default through them.
 */
const TOKEN_SOURCES: readonly (readonly [
  string,
  string,
  "color" | "borderTopLeftRadius" | "fontSize" | "lineHeight" | "boxShadow",
])[] = [
  ["--comma-background", "--color-bg-primary", "color"],
  ["--comma-surface", "--color-bg-secondary", "color"],
  ["--comma-surface-strong", "--color-bg-tertiary", "color"],
  ["--comma-foreground", "--color-text-primary", "color"],
  ["--comma-muted", "--color-text-secondary", "color"],
  ["--comma-subtle", "--color-text-tertiary", "color"],
  ["--comma-faint", "--color-text-quaternary", "color"],
  ["--comma-border", "--color-border-primary", "color"],
  ["--comma-border-subtle", "--color-border-secondary", "color"],
  ["--comma-primary", "--color-button-primary-bg", "color"],
  ["--comma-primary-foreground", "--color-button-primary-fg", "color"],
  ["--comma-accent", "--color-text-brand-primary", "color"],
  ["--comma-danger", "--color-text-error-primary", "color"],
  ["--comma-success", "--color-text-success-primary", "color"],
  ["--comma-warning", "--color-text-warning-primary", "color"],
  ...(["sm", "md", "lg", "xl", "2xl"] as const).map(
    (size) =>
      [`--comma-radius-${size}`, `--radius-${size}`, "borderTopLeftRadius"] as const
  ),
  ...(["xs", "sm", "md", "lg", "xl"] as const).flatMap((size) => [
    [`--comma-text-${size}`, `--text-${size}`, "fontSize"] as const,
    [
      `--comma-text-${size}-leading`,
      `--text-${size}--line-height`,
      "lineHeight",
    ] as const,
  ]),
  // A hero value or a result title: Comma's smallest display size.
  ["--comma-text-2xl", "--text-display-xs", "fontSize"],
  ["--comma-text-2xl-leading", "--text-display-xs--line-height", "lineHeight"],
  ...(["xs", "sm", "md", "lg"] as const).map(
    (size) => [`--comma-shadow-${size}`, `--shadow-${size}`, "boxShadow"] as const
  ),
];

function readTokens(anchor: HTMLElement): Record<string, string> {
  const probes = document.createElement("div");
  probes.hidden = true;
  const spans = TOKEN_SOURCES.map(([, source, property]) => {
    const span = document.createElement("span");
    span.style[property] = `var(${source})`;
    probes.append(span);
    return span;
  });
  anchor.append(probes);
  const tokens: Record<string, string> = {};
  TOKEN_SOURCES.forEach(([name, , property], index) => {
    const value = getComputedStyle(spans[index]!)[property];
    if (value && !/[;{}]|url\(/i.test(value)) tokens[name] = value;
  });
  const font = getComputedStyle(anchor).fontFamily;
  if (font && !/[;{}]|url\(/i.test(font)) tokens["--comma-font"] = font;
  probes.remove();
  return tokens;
}

type Prompt =
  | { kind: "grant"; capability: string; resolve: (allowed: boolean) => void }
  | {
      kind: "confirm";
      op: string;
      args: Record<string, unknown>;
      resolve: (confirmed: boolean) => void;
    };

type State =
  | { status: "opening" }
  | { status: "running"; info: MiniAppSessionInfo; kept?: KeptFrame | undefined }
  | {
      status: "paused" | "failed" | "stalled" | "stopped" | "unavailable" | "disabled";
      reason?: string;
    };

export type MiniAppFrameProps = {
  appId: string;
  via: MiniAppVia;
  /** A Task's card previews this Version. */
  version?: number | undefined;
  /** Entries of the chrome's actions menu (open modes, settings). */
  actions?: readonly MiniAppChromeAction[] | undefined;
  className?: string | undefined;
  /** A fixed frame height (an inline preview); the frame fills its place otherwise. */
  height?: number | undefined;
  /** The app's name and author, for the chrome when no session opened (a link page knows them). */
  known?: { name: string; author: string } | undefined;
  /** The chrome's shape: a card among other content, or flush in a surface that has its own frame. */
  variant?: MiniAppChromeProps["variant"];
  /** Text before the author in the chrome (a Task card's Version). */
  detail?: string | undefined;
  leading?: ReactNode;
  /** Classes for the chrome's bar (a window's title bar: its drag region and traffic-light inset). */
  headerClassName?: string | undefined;
  trailing?: ReactNode;
  footer?: ReactNode;
  /** Opens no session yet: the chrome keeps the app's place (a chat card not yet in view). */
  idle?: boolean | undefined;
  /** A preview to look at, not use (a chat card): the app takes no pointer or keyboard input. */
  inert?: boolean | undefined;
  /**
   * Keeps the running app when this host unmounts (`MiniAppFrameKeeper`): a host with the same key shows that frame
   * again at once, without opening a session or starting the app again.
   */
  keepKey?: string | undefined;
  /** A launch cover's press (the chrome's `cover` variant) and its accessible name. */
  onOpen?: (() => void) | undefined;
  openLabel?: string | undefined;
  /**
   * The app will not run again here: deleted or no longer shared (`unavailable`), or turned off (`disabled`). A host
   * that has another use for the place (a chat card) takes it back; without this the frame shows the notice.
   */
  onGone?: ((kind: "unavailable" | "disabled") => void) | undefined;
};

/**
 * The host of one running app: the sandboxed runtime frame, the broker that sends each call of the frame to the core
 * (`miniApps.invoke`, bound to the session this host opened), and the host UI an app cannot draw: the chrome, the grant
 * and confirm sheets, and the paused, failed and stalled notices.
 */
export function MiniAppFrame(props: MiniAppFrameProps) {
  const { appId, via, version, idle = false, keepKey } = props;
  const viaKey = "workspace" in via ? `w:${via.workspace}` : `l:${via.token}`;
  const messages = useCommaMessages();
  const call = useCall();
  const keeper = useContext(FrameKeeperContext);
  const [attempt, setAttempt] = useState(0);
  // A frame kept for this host's key shows from the first render: nothing opens or starts.
  const [state, setState] = useState<State>(() => {
    const kept = keepKey ? keeper?.parked(keepKey) : undefined;
    return kept ? { status: "running", info: kept.info, kept } : { status: "opening" };
  });
  const stateRef = useRef(state);
  stateRef.current = state;

  useEffect(() => {
    const shown = stateRef.current;
    if (
      shown.status === "running" &&
      shown.kept !== undefined &&
      shown.kept.hostKey === keepKey
    )
      return;
    if (idle) return;
    let current = true;
    let opened: string | undefined;
    setState({ status: "opening" });
    call("miniApps.session.open", {
      app: appId,
      via,
      platform: getNativeBridge().platform === "electron" ? "mac" : "web",
      ...(version !== undefined ? { version } : {}),
    }).then(
      (info) => {
        opened = info.session;
        if (!current) {
          void call("miniApps.session.close", { session: info.session }).catch(
            () => {}
          );
          return;
        }
        if (info.app.status === "disabled") {
          setState({ status: "disabled" });
          return;
        }
        // A kept session is the keeper's to close.
        const kept = keepKey
          ? keeper?.keep(keepKey, info, props.inert === true)
          : undefined;
        if (kept) opened = undefined;
        setState({ status: "running", info, kept });
      },
      (error: { code?: string; message?: string }) => {
        if (!current) return;
        setState(
          error.code === "app_paused"
            ? { status: "paused" }
            : error.code === "not_found" || error.code === "http_404"
              ? { status: "unavailable" }
              : {
                  status: "failed",
                  ...(error.message ? { reason: error.message } : {}),
                }
        );
      }
    );
    return () => {
      current = false;
      if (opened)
        void call("miniApps.session.close", { session: opened }).catch(() => {});
    };
    // `via` is keyed by viaKey: a new object for the same path opens nothing new.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [appId, viaKey, version, attempt, call, idle, keepKey, keeper]);

  const onGone = props.onGone;
  useEffect(() => {
    if (state.status === "unavailable" || state.status === "disabled")
      onGone?.(state.status);
  }, [state.status, onGone]);

  const info = state.status === "running" ? state.info : undefined;
  return (
    <MiniAppChromeHost
      {...props}
      info={info}
      body={
        state.status === "running" && state.kept ? (
          <KeptFrameSlot
            frame={state.kept}
            onEnd={(next) => setState(next)}
            onLost={() => {
              setState({ status: "opening" });
              setAttempt((n) => n + 1);
            }}
          />
        ) : info ? (
          <RunningFrame
            key={info.session}
            inert={props.inert === true}
            info={info}
            onEnd={(next) => setState(next)}
          />
        ) : idle ? null : state.status === "opening" ? (
          <div className="flex flex-1 items-center justify-center py-3xl">
            <LoadingIndicator label={messages.mini_app_loading()} />
          </div>
        ) : (
          <MiniAppNotice
            kind={
              state.status as
                | "paused"
                | "failed"
                | "stalled"
                | "stopped"
                | "unavailable"
                | "disabled"
            }
            reason={"reason" in state ? state.reason : undefined}
            onRetry={
              state.status === "unavailable" || state.status === "disabled"
                ? undefined
                : () => setAttempt((n) => n + 1)
            }
          />
        )
      }
    />
  );
}

/** The chrome with its Report dialog; the app's name shows from the session once it opened. */
function MiniAppChromeHost({
  appId,
  via,
  actions,
  className,
  known,
  height,
  variant,
  detail,
  leading,
  headerClassName,
  onOpen,
  openLabel,
  trailing,
  footer,
  info,
  body,
}: MiniAppFrameProps & {
  info: MiniAppSessionInfo | undefined;
  body: ReactNode;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const activeWorkspace = useActiveWorkspaceId();
  const [reporting, setReporting] = useState(false);
  const [reason, setReason] = useState("");
  // An app that did not open (paused, failed) still shows whose it is: the Workspace's copy of the app, read only then.
  const { value: stored } = useTopic(
    !info && !known && "workspace" in via
      ? { topic: "miniApp", workspace: via.workspace, app: appId }
      : null
  );
  const shown = info?.app ?? stored?.app ?? null;
  const name = shown?.name ?? known?.name ?? "";
  const author = shown?.author.name ?? known?.author ?? "";
  const iconUrl = useMiniAppIcon(shown?.icon_url, via);
  const reportWorkspace = "workspace" in via ? via.workspace : activeWorkspace;
  return (
    <>
      <MiniAppChrome
        actions={actions}
        author={author}
        bodyHeight={height}
        className={className}
        detail={detail}
        footer={footer}
        iconUrl={iconUrl}
        headerClassName={headerClassName}
        leading={leading}
        onOpen={onOpen}
        openLabel={openLabel}
        name={name}
        onReport={() => setReporting(true)}
        trailing={trailing}
        variant={variant}
      >
        {body}
      </MiniAppChrome>
      {reporting ? (
        <Dialog
          actions={[
            {
              label: messages.mini_app_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setReporting(false),
            },
            {
              label: messages.mini_app_report_send(),
              hierarchy: "destructive",
              disabled: !reason.trim() || !reportWorkspace,
              onPress: () => {
                if (!reportWorkspace) return;
                setReporting(false);
                void call("miniApps.report", {
                  workspace: reportWorkspace,
                  app: appId,
                  reason: reason.trim(),
                }).then(
                  () => toast.success(messages.mini_app_report_sent()),
                  () => toast.error(messages.mini_app_report_failed())
                );
              },
            },
          ]}
          description={messages.mini_app_report_description()}
          input={{
            "aria-label": messages.mini_app_report_reason(),
            placeholder: messages.mini_app_report_reason(),
            value: reason,
            onChange: (event) => setReason(event.target.value),
            maxLength: 2000,
            autoFocus: true,
          }}
          isOpen
          onOpenChange={(open) => {
            if (!open) setReporting(false);
          }}
          title={messages.mini_app_report_title({ name })}
          variant="input"
        />
      ) : null}
    </>
  );
}

/** The value an Each time op answers when the viewer cancels its confirm. */
function declined(op: string): unknown {
  if (op === "tasks.propose") return { created: false };
  if (op === "links.open") return { opened: false };
  if (op === "files.pick") return [];
  return null;
}

/** Copies a value's bytes into ArrayBuffers the frame can take (`backend.fetch`'s body): the list to transfer. */
function forFrame(op: string, value: unknown): [unknown, Transferable[]] {
  if (
    (op === "backend.fetch" || op === "drive.read") &&
    value &&
    typeof value === "object"
  ) {
    const field = op === "backend.fetch" ? "body" : "data";
    const bytes = (value as Record<string, unknown>)[field];
    if (bytes instanceof Uint8Array) {
      const buffer = bytes.slice().buffer;
      return [{ ...value, [field]: buffer }, [buffer]];
    }
  }
  return [value, []];
}

/** The viewer picks files in the host's own picker; the app gets only those. */
function pickFiles(args: Record<string, unknown>): Promise<File[]> {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.multiple = args.multiple === true;
    if (Array.isArray(args.accept)) input.accept = args.accept.join(",");
    input.addEventListener("change", () => resolve([...(input.files ?? [])]), {
      once: true,
    });
    input.addEventListener("cancel", () => resolve([]), { once: true });
    input.click();
  });
}

function RunningFrame({
  info,
  inert,
  onEnd,
  parked = () => false,
}: {
  info: MiniAppSessionInfo;
  inert: boolean;
  onEnd: (state: State) => void;
  /** Whether a kept frame waits off screen now: it goes first when a new frame needs a place. */
  parked?: () => boolean;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const themeName = useCommaUiThemeName();
  const call = useCall();
  const draftHere = useContext(MiniAppDraftContext);
  const homeDraft = useMiniAppHomeDraft();
  const draft = draftHere ?? homeDraft;
  const draftRef = useRef(draft);
  draftRef.current = draft;
  const frame = useRef<HTMLIFrameElement>(null);
  const anchor = useRef<HTMLDivElement>(null);
  const port = useRef<MessagePort | undefined>(undefined);
  const [prompt, setPrompt] = useState<Prompt>();
  /** Prompts wait their turn: one sheet at a time. */
  const prompts = useRef<Promise<unknown>>(Promise.resolve());
  const grants = useRef(info.grants);
  const theme: "dark" | "light" = themeName === "Dark mode" ? "dark" : "light";
  const themeRef = useRef(theme);
  themeRef.current = theme;
  const onEndRef = useRef(onEnd);
  onEndRef.current = onEnd;

  const ask = <T,>(make: (resolve: (value: T) => void) => Prompt): Promise<T> => {
    const next = prompts.current.then(
      () =>
        new Promise<T>((resolve) =>
          setPrompt(
            make((value) => {
              setPrompt(undefined);
              resolve(value);
            })
          )
        )
    );
    prompts.current = next.catch(() => undefined);
    return next;
  };

  useEffect(() => {
    if (!anchor.current || !port.current) return;
    port.current.postMessage({
      type: "theme",
      theme,
      tokens: readTokens(anchor.current),
    });
  }, [theme]);

  useEffect(() => {
    const key = Symbol(info.app.id);
    let stopped = false;
    let channel: MessageChannel | undefined;
    let startup: CancelUiTimer | undefined;
    let watchdog: CancelUiTimer | undefined;
    const end = (next: State) => {
      if (stopped) return;
      stopped = true;
      onEndRef.current(next);
    };
    const release = acquirePlace(key, () => end({ status: "stopped" }), parked);
    const bundle = call("miniApps.bundle", { session: info.session });
    bundle.catch(() => undefined);

    const reply = (
      id: number,
      result: MiniAppInvokeResult | { ok: true; value: unknown }
    ) => {
      const target = port.current;
      if (!target || stopped) return;
      if ("ok" in result) {
        target.postMessage({ type: "result", id, ok: true, value: result.value });
        return;
      }
      if (result.status === "error") {
        target.postMessage({
          type: "result",
          id,
          ok: false,
          error: { code: result.code, message: result.message },
        });
        // The owner's Workspace is out of credit: the frame stops at once.
        if (result.code === "app_paused") end({ status: "paused" });
        return;
      }
      if (result.status === "done") {
        const [value, transfer] = forFrame("", result.value);
        target.postMessage({ type: "result", id, ok: true, value }, transfer);
      }
    };
    const fail = (id: number, code: string, message: string) =>
      port.current?.postMessage({
        type: "result",
        id,
        ok: false,
        error: { code, message },
      });

    /** Does what the core allowed the host to do. */
    const hostEffect = async (
      id: number,
      op: string,
      args: Record<string, unknown>
    ) => {
      try {
        switch (op) {
          case "chat.draft":
            await draftRef.current?.(String(args.text));
            toast.success(messages.mini_app_draft_added());
            reply(id, { ok: true, value: null });
            return;
          case "clipboard.write":
            await nativePlatformClipboard.writeText(String(args.text));
            reply(id, { ok: true, value: null });
            return;
          case "notify": {
            if (typeof Notification === "undefined") {
              fail(id, "unsupported", "Notifications are not available here.");
              return;
            }
            let permission = Notification.permission;
            if (permission === "default")
              permission = await Notification.requestPermission();
            if (permission !== "granted") {
              fail(id, "denied", "Notifications are off for Comma.");
              return;
            }
            const notice = new Notification(String(args.title), {
              body: typeof args.body === "string" ? args.body : "",
            });
            // A click on it brings Comma to the front, where the app runs.
            notice.addEventListener("click", () => window.focus());
            reply(id, { ok: true, value: null });
            return;
          }
          case "calendar.events": {
            const bridge = getNativeBridge();
            if (bridge.platform !== "electron") {
              fail(id, "unsupported", "The calendar is on Mac only.");
              return;
            }
            // Main reads it with the Mac apps engine, only while Calendar is on in Comma and macOS allows it.
            const read = await bridge.macApps.calendarEvents({
              from: String(args.from),
              to: String(args.to),
            });
            if (read.status === "ok") reply(id, { ok: true, value: read.events });
            else if (read.status === "denied")
              fail(id, "denied", "macOS does not allow Comma to read the calendar.");
            else if (read.status === "off")
              fail(id, "unavailable", "Calendar is off in Comma > Plugins > Mac apps.");
            else fail(id, "unsupported", "The calendar is not available here.");
            return;
          }
          case "links.open":
            await openNativePlatformExternalUrl(String(args.url));
            reply(id, { ok: true, value: { opened: true } });
            return;
          default:
            fail(id, "unsupported", `${op} is not available here.`);
        }
      } catch (error) {
        fail(id, "failed", error instanceof Error ? error.message : "The call failed.");
      }
    };

    const invoke = async (id: number, op: string, args: unknown, confirmed = false) => {
      let result: MiniAppInvokeResult;
      try {
        result = await call("miniApps.invoke", {
          session: info.session,
          op,
          args,
          ...(confirmed ? { confirmed: true } : {}),
        });
      } catch (error) {
        fail(
          id,
          "unavailable",
          error instanceof Error ? error.message : "Comma is not reachable."
        );
        return;
      }
      if (stopped) return;
      if (result.status === "done" || result.status === "error") {
        if (result.status === "done") {
          const [value, transfer] = forFrame(op, result.value);
          port.current?.postMessage({ type: "result", id, ok: true, value }, transfer);
        } else reply(id, result);
        return;
      }
      if (result.status === "grant") {
        const allowed = await ask<boolean>((resolve) => ({
          kind: "grant",
          capability: result.capability,
          resolve,
        }));
        if (!allowed) {
          fail(id, "denied", "The viewer did not allow it.");
          return;
        }
        try {
          const granted = await call("miniApps.grant", {
            session: info.session,
            capability: result.capability,
          });
          grants.current = granted.grants;
          port.current?.postMessage({ type: "grants", grants: granted.grants });
        } catch {
          fail(id, "failed", "The grant could not be saved.");
          return;
        }
        await invoke(id, op, args);
        return;
      }
      if (result.status === "confirm") {
        const shown = (result.args ?? {}) as Record<string, unknown>;
        if (op === "files.pick") {
          // The viewer's press on the sheet opens the picker at once: a picker needs that press.
          let picking: Promise<File[]> | undefined;
          const chosen = await ask<boolean>((resolve) => ({
            kind: "confirm",
            op,
            args: shown,
            resolve: (yes) => {
              if (yes) picking = pickFiles(shown);
              resolve(yes);
            },
          }));
          if (!chosen || !picking) {
            reply(id, { ok: true, value: declined(op) });
            return;
          }
          const allowed = await call("miniApps.invoke", {
            session: info.session,
            op,
            args,
            confirmed: true,
          }).catch(() => undefined);
          const files = await picking;
          if (allowed?.status !== "host") {
            reply(id, allowed ?? { status: "error", code: "unavailable", message: "" });
            return;
          }
          const kept = files
            .slice(0, MAX_PICKED_FILES)
            .filter((f) => f.size <= MAX_PICKED_BYTES);
          const picked = await Promise.all(
            kept.map(async (file) => ({
              name: file.name,
              mime: file.type || "application/octet-stream",
              data: await file.arrayBuffer(),
            }))
          );
          port.current?.postMessage(
            { type: "result", id, ok: true, value: picked },
            picked.map((p) => p.data)
          );
          return;
        }
        if (op === "links.open" && getNativeBridge().platform !== "electron") {
          // On the web the press opens the tab, then the core's answer gives it its address.
          let opened: Promise<Window | undefined> | undefined;
          let answer: Promise<MiniAppInvokeResult> | undefined;
          const accepted = await ask<boolean>((resolve) => ({
            kind: "confirm",
            op,
            args: shown,
            resolve: (yes) => {
              if (yes) {
                answer = call("miniApps.invoke", {
                  session: info.session,
                  op,
                  args,
                  confirmed: true,
                });
                opened = openNativePlatformExternalUrlFromUserAction(async () => {
                  const allowed = await answer!;
                  if (allowed.status !== "host") throw new Error("refused");
                  return String(shown.url);
                });
              }
              resolve(yes);
            },
          }));
          if (!accepted) {
            reply(id, { ok: true, value: declined(op) });
            return;
          }
          const tab = await opened!.catch(() => undefined);
          reply(id, { ok: true, value: { opened: tab !== undefined } });
          return;
        }
        const agreed = await ask<boolean>((resolve) => ({
          kind: "confirm",
          op,
          args: shown,
          resolve,
        }));
        if (!agreed) {
          reply(id, { ok: true, value: declined(op) });
          return;
        }
        await invoke(id, op, args, true);
        return;
      }
      await hostEffect(id, result.op, (result.args ?? {}) as Record<string, unknown>);
    };

    const onPortMessage = (event: MessageEvent<MiniAppFramePortMessage>) => {
      const message = event.data;
      if (!message || typeof message !== "object" || stopped) return;
      switch (message.type) {
        case "started":
          startup?.();
          startup = undefined;
          return;
        case "error":
          end({
            status: "failed",
            reason:
              typeof message.reason === "string" ? message.reason.slice(0, 300) : "",
          });
          return;
        case "pong":
          lastPong = uiClock.monotonic();
          return;
        case "call":
          if (typeof message.id === "number" && typeof message.op === "string")
            void invoke(message.id, message.op, message.args);
          return;
        default:
      }
    };

    let lastPong = uiClock.monotonic();
    let initialized = false;
    const onWindowMessage = (event: MessageEvent) => {
      // Only this host's own frame hands over a port: any other window is ignored.
      if (
        initialized ||
        stopped ||
        !frame.current ||
        event.source !== frame.current.contentWindow ||
        (event.data as { type?: unknown } | null)?.type !== "comma-app:ready"
      )
        return;
      initialized = true;
      channel = new MessageChannel();
      port.current = channel.port1;
      channel.port1.addEventListener("message", onPortMessage);
      channel.port1.start();
      const init: MiniAppInit = {
        app: { id: info.app.id, name: info.app.name, version: info.version },
        viewer: grants.current.includes("identity.basic") ? info.viewer : null,
        theme: themeRef.current,
        tokens: anchor.current ? readTokens(anchor.current) : {},
        locale,
        timeZone: viewerTimeZone(),
        capabilities: info.capabilities,
        grants: grants.current,
        storage: info.storage,
        backend: info.backend,
      };
      frame.current.contentWindow!.postMessage({ type: "comma-app:init", init }, "*", [
        channel.port2,
      ]);
      bundle.then(
        ({ files }) => {
          if (stopped) return;
          const sent = files.map((file) => ({
            path: file.path,
            mime: file.mime,
            data: file.data.slice().buffer,
          }));
          channel?.port1.postMessage(
            { type: "files", files: sent },
            sent.map((file) => file.data)
          );
        },
        (error: { message?: string }) =>
          end({ status: "failed", reason: error.message ?? "" })
      );
      let n = 0;
      lastPong = uiClock.monotonic();
      watchdog = uiClock.every(PING_EVERY_MS, () => {
        if (uiClock.monotonic() - lastPong > STALL_AFTER_MS) {
          end({ status: "stalled" });
          return;
        }
        channel?.port1.postMessage({ type: "ping", n: ++n });
      });
    };
    startup = uiClock.after(MINI_APP_START_TIMEOUT_MS, () =>
      end({ status: "failed", reason: "The app did not start within 10 seconds." })
    );
    window.addEventListener("message", onWindowMessage);
    frame.current?.contentWindow?.postMessage({ type: "comma-app:hello" }, "*");
    return () => {
      stopped = true;
      startup?.();
      watchdog?.();
      release();
      window.removeEventListener("message", onWindowMessage);
      channel?.port1.postMessage({ type: "stop", reason: "closed" });
      channel?.port1.close();
      port.current = undefined;
    };
    // The session is the frame's identity: a new one is a new frame (keyed by its parent).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [info.session]);

  return (
    <div ref={anchor} className="relative flex min-h-0 flex-1 flex-col">
      <iframe
        ref={frame}
        allow=""
        className="block min-h-0 w-full flex-1 border-0"
        data-testid="mini-app-frame"
        inert={inert}
        onLoad={() =>
          frame.current?.contentWindow?.postMessage({ type: "comma-app:hello" }, "*")
        }
        referrerPolicy="no-referrer"
        sandbox={miniAppFrameSandbox}
        src={miniAppRuntimeSrc()}
        style={{ colorScheme: theme, background: "transparent" }}
        title={info.app.name}
      />
      {prompt?.kind === "grant" ? (
        <MiniAppGrantSheet
          appName={info.app.name}
          capabilities={info.app.capabilities}
          capability={prompt.capability}
          egress={info.app.egress}
          onAllow={() => prompt.resolve(true)}
          onDeny={() => prompt.resolve(false)}
        />
      ) : prompt?.kind === "confirm" ? (
        <MiniAppConfirmSheet
          {...confirmCopy(messages, info.app.name, prompt.op, prompt.args)}
          onCancel={() => prompt.resolve(false)}
          onConfirm={() => prompt.resolve(true)}
        />
      ) : null}
    </div>
  );
}

function confirmCopy(
  messages: ReturnType<typeof useCommaMessages>,
  name: string,
  op: string,
  args: Record<string, unknown>
) {
  if (op === "tasks.propose")
    return {
      title: messages.mini_app_confirm_task_title({ name }),
      detail: String(args.text ?? ""),
      confirmLabel: messages.mini_app_confirm_task_action(),
    };
  if (op === "links.open")
    return {
      title: messages.mini_app_confirm_link_title({ name }),
      description: messages.mini_app_confirm_link_description(),
      detail: String(args.url ?? ""),
      confirmLabel: messages.mini_app_confirm_link_action(),
    };
  return {
    title: messages.mini_app_confirm_files_title({ name }),
    description: messages.mini_app_confirm_files_description(),
    confirmLabel: messages.mini_app_confirm_files_action(),
  };
}

/** The viewer's IANA time zone. */
function viewerTimeZone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {
    return "";
  }
}
