import { renderToStaticMarkup } from "react-dom/server";
import {
  spacing,
  radius,
  compactTypeScale,
  motionDuration,
  motionEasing,
} from "@comma/ui/tokens";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { ChatMessagePart } from "@comma/chat-contract";
import { supportsDynamicUiWidgets } from "../../../nativePlatformActions";
import { Button } from "@comma/ui/components/Button";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { ClockIcon, CircleInfoIcon, TrainIcon } from "@comma/ui/components/icons";
import { useCommaUiThemeName } from "../../commaUiTheme";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import { useCall, useTopic } from "@comma/core-client";
import {
  useSessionHostController,
  useSessionLifecycleSnapshot,
} from "../../../session/react";
import { ChatLinkHoverCard } from "../thread/inline/ChatLinkHoverCard";
import { cardBrandIcons, cardCopy, cardIconMarkup, cardTokenProbe } from "./cardHost";
import { WidgetFailureNotice, type WidgetFailure } from "./WidgetFailureNotice";
import { useReportWidgetPresence } from "./widgetPresence";

export const DynamicUiDraftContext = createContext<
  ((text: string, messageId: string) => void) | undefined
>(undefined);
export const DynamicUiLinkContext = createContext<((url: string) => void) | undefined>(
  undefined
);
/** Opens the host's link menu for a right-click inside a widget, at viewport coordinates. */
export const DynamicUiLinkMenuContext = createContext<
  | ((url: string, clientX: number, clientY: number, frame: HTMLIFrameElement) => void)
  | undefined
>(undefined);
/** A link the pointer is over inside the frame, boxed in widget coordinates. */
type LinkHover = {
  url: string;
  label: string;
  left: number;
  top: number;
  width: number;
  height: number;
  open: boolean;
};
type Props = {
  part: Extract<ChatMessagePart, { kind: "dynamic-ui" }>;
  /** The surface reads the widget from the core; a static surface (a Task's report) does not. */
  live: boolean;
  groupId: string;
  workspaceId: string;
};
/** A running frame: how to take its place, and whether its widget is in view now. */
type Running = { release: (inView: boolean) => void; inView: () => boolean };
const running = new Map<symbol, Running>();
/**
 * At most three frames run at once. A fourth takes the place of the oldest one whose widget
 * is out of view. With every running widget in view, a fourth out of view waits for its turn
 * (it runs when it comes into view), and a fourth in view takes the oldest place. Returns how
 * to give the place back, or nothing when the newcomer got none.
 */
function acquire(key: symbol, entry: Running): (() => void) | undefined {
  running.delete(key);
  if (running.size >= 3) {
    const away = [...running.entries()].find(([, run]) => !run.inView());
    if (!away && !entry.inView()) {
      entry.release(false);
      return undefined;
    }
    const [gone, victim] = away ?? running.entries().next().value!;
    running.delete(gone);
    victim.release(away === undefined);
  }
  running.set(key, entry);
  return () => {
    running.delete(key);
  };
}

/** A widget's height until its runtime reports its own. */
const STARTING_HEIGHT = 160;
/**
 * Each widget's last reported height, by what it loads: a message that mounts again (the
 * turn window dropped it, or the thread remounted) holds the widget's size from its first
 * render, so nothing grows in view. Past the bound, the least recently reported go first.
 */
const heights = new Map<string, number>();
const MAX_HEIGHTS = 1024;
function rememberHeight(scope: string, value: number) {
  heights.delete(scope);
  heights.set(scope, value);
  if (heights.size > MAX_HEIGHTS) heights.delete(heights.keys().next().value!);
}

export function DynamicUiWidget(props: Props) {
  if (!supportsDynamicUiWidgets() || props.part.version !== 1)
    return <span>{props.part.summary}</span>;
  return <NativeDynamicUiWidget {...props} />;
}

function NativeDynamicUiWidget({ part, live, groupId, workspaceId }: Props) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const localeRef = useRef(locale);
  localeRef.current = locale;
  const session = useSessionHostController();
  const snapshot = useSessionLifecycleSnapshot(session.lifecycle);
  const draft = useContext(DynamicUiDraftContext);
  const openLink = useContext(DynamicUiLinkContext);
  const openLinkRef = useRef(openLink);
  openLinkRef.current = openLink;
  const openLinkMenu = useContext(DynamicUiLinkMenuContext);
  const openLinkMenuRef = useRef(openLinkMenu);
  openLinkMenuRef.current = openLinkMenu;
  useReportWidgetPresence();
  const themeName = useCommaUiThemeName();
  const currentTheme = useRef(themeName);
  currentTheme.current = themeName;
  const syncTheme = useRef<(() => void) | undefined>(undefined);
  useEffect(() => {
    syncTheme.current?.();
  }, [themeName]);
  const ref = useRef<HTMLDivElement>(null);
  const frame = useRef<HTMLIFrameElement>(null);
  const instance = useRef(Symbol("dynamic-ui"));
  const [visible, setVisible] = useState(false);
  // Why the frame is off while the widget is in band: a newer frame took its place while the
  // widget was out of view (`away`: it runs again as it comes near) or in view (`shown`:
  // Reload runs it again).
  const [released, setReleased] = useState<"away" | "shown">();
  const releasedRef = useRef(released);
  releasedRef.current = released;
  const [inView, setInView] = useState(false);
  const inViewRef = useRef(false);
  const [error, setError] = useState<WidgetFailure>();
  const [proposal, setProposal] = useState("");
  const [linkHover, setLinkHover] = useState<LinkHover>();
  const [attempt, setAttempt] = useState(0);
  const reload = useCallback(() => {
    setError(undefined);
    setReleased(undefined);
    setAttempt((value) => value + 1);
  }, []);
  const user = snapshot.principal?.userId;
  const stateKey = user
    ? JSON.stringify([
        "comma-ui:1",
        session.apiBaseUrl,
        user,
        workspaceId,
        part.contentId,
      ])
    : undefined;
  const loadScope = JSON.stringify([
    stateKey,
    groupId,
    part.conversationId,
    part.messageId,
    part.attachmentIndex,
  ]);
  // The widget's size from its first render: what its runtime last reported, else the
  // starting height.
  const [height, setHeight] = useState(() => heights.get(loadScope) ?? STARTING_HEIGHT);
  // The widget's JSON as the core reads it, from when its message is in a live thread: read
  // ahead of the viewport, the widget never waits on the network in view. A retry is a new
  // read.
  const reading = live && !!user;
  const { value: load } = useTopic(
    reading
      ? {
          topic: "dynamicUi",
          group: groupId,
          conversation: part.conversationId,
          message: part.messageId,
          index: String(part.attachmentIndex),
          read: String(attempt),
        }
      : null
  );
  const payload = load?.status === "ready" ? load.ui : undefined;
  // What this widget saved before, as the core keeps it for the account: every
  // window that shows the widget sees a save at once.
  const { value: saved } = useTopic(
    reading && stateKey ? { topic: "dynamicUiState", key: stateKey } : null
  );
  const savedRef = useRef(saved);
  savedRef.current = saved;
  const call = useCall();
  const save = useRef<(kind: "state" | "cards", value: unknown) => void>(() => {});
  save.current = (kind, value) => {
    if (!stateKey) return;
    let text: string;
    try {
      text = JSON.stringify(value);
      if (new TextEncoder().encode(text).length > 32768) throw Error();
    } catch {
      setError({ kind: "display", reason: "UI state could not be saved" });
      return;
    }
    if (kind === "cards") ownCards.current = text;
    void call("dynamicUiState.save", { key: stateKey, kind, text }).catch(() =>
      setError({ kind: "display", reason: "UI state could not be saved" })
    );
  };
  /** The card progress this copy saved last: it already shows it, so it is not sent back. */
  const ownCards = useRef<string | undefined>(undefined);
  const port = useRef<MessagePort | undefined>(undefined);
  const loadFailure: WidgetFailure | undefined =
    load?.status === "failed" ? { kind: load.kind, reason: load.reason } : undefined;
  const failure = error ?? loadFailure;
  const ready =
    !released &&
    visible &&
    payload !== undefined &&
    !!stateKey &&
    saved !== undefined &&
    !failure;
  // The widget's frame runs only once it holds one of the three places, so a widget that gets
  // none never boots a frame.
  const [hasPlace, setHasPlace] = useState(false);
  useEffect(() => {
    if (!ready) return;
    const place = acquire(instance.current, {
      release: (shown) => setReleased(shown ? "shown" : "away"),
      inView: () => inViewRef.current,
    });
    // No place now: the widget runs when it comes into view.
    if (!place) return;
    setHasPlace(true);
    return () => {
      place();
      setHasPlace(false);
    };
  }, [ready]);
  const mounted = ready && hasPlace;
  // A widget in view whose JSON has not come within a second shows its text answer meanwhile:
  // a slow network does not leave an empty slot for the length of a read.
  const waiting = reading && inView && payload === undefined && !failure;
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    if (!waiting) {
      setSlow(false);
      return;
    }
    return uiClock.after(1000, () => setSlow(true));
  }, [waiting]);
  // The text answer stands in only where the widget cannot run: a static surface, a failure,
  // a slow read in view, or a widget in view whose place a newer frame took. Loading,
  // unloaded, or waiting for a place out of view, the widget holds its size as an empty slot.
  const textStands = !reading || !!failure || slow || released === "shown";

  useEffect(() => {
    setProposal("");
    setError(undefined);
    setHeight(heights.get(loadScope) ?? STARTING_HEIGHT);
  }, [loadScope]);

  // A connection that drops and comes back reloads the widget without a click.
  useEffect(() => {
    if (failure?.kind !== "load") return;
    window.addEventListener("online", reload);
    return () => window.removeEventListener("online", reload);
  }, [failure?.kind, reload]);

  useEffect(() => {
    if (!ref.current) return;
    // The chat scrolls inside a nested viewport, which clips a document-root observer before
    // its margin applies: rooted there, the band is 480px of the thread. A frame takes about
    // 250 ms to boot and report its height, so at a reading scroll speed of 1000 px/s it
    // settles out of view.
    const root = ref.current.closest('[data-slot="scroll-area-viewport"]');
    let intersects = false;
    let releaseTimer: CancelUiTimer | undefined;
    // A widget whose place a newer frame took runs again as the reader comes to it.
    const resume = () => {
      if (releasedRef.current) setReleased(undefined);
    };
    const refresh = () => {
      releaseTimer?.();
      // Window occlusion is not a viewport exit. Keep the bounded live instance
      // so returning to the app does not recreate the iframe and Worker.
      if (document.visibilityState !== "visible") return;
      if (intersects) {
        setVisible(true);
      } else {
        // Absorb a quick scroll reversal without destroying interaction state.
        releaseTimer = uiClock.after(1500, () => setVisible(false));
      }
    };
    const band = new IntersectionObserver(
      (entries) => {
        intersects = entries.some((entry) => entry.isIntersecting);
        if (intersects) resume();
        refresh();
      },
      { root, rootMargin: "480px 0px" }
    );
    // Whether the widget itself is in view decides whose place a fourth frame takes.
    const view = new IntersectionObserver(
      (entries) => {
        inViewRef.current = entries.some((entry) => entry.isIntersecting);
        setInView(inViewRef.current);
        if (inViewRef.current) resume();
      },
      { root, rootMargin: "0px" }
    );
    document.addEventListener("visibilitychange", refresh);
    band.observe(ref.current);
    view.observe(ref.current);
    return () => {
      releaseTimer?.();
      band.disconnect();
      view.disconnect();
      document.removeEventListener("visibilitychange", refresh);
    };
  }, []);
  useEffect(() => {
    if (!mounted || !stateKey) return;
    let channel: MessageChannel | undefined;
    let initialized = false;
    // The widget's own frame must say it is ready within 5 s.
    let startup: CancelUiTimer | undefined = uiClock.after(5000, () =>
      setError({ kind: "display", reason: "UI startup timed out" })
    );
    let themeObserver: MutationObserver | undefined;
    let themeProbes: HTMLDivElement | undefined;
    let tokenProbe: ReturnType<typeof cardTokenProbe> | undefined;
    let themeFrame: CancelUiTimer | undefined;
    const onReady = (event: MessageEvent) => {
      if (
        initialized ||
        event.source !== frame.current?.contentWindow ||
        event.data?.type !== "comma-ui:ready"
      )
        return;
      initialized = true;
      channel = new MessageChannel();
      port.current = channel.port1;
      let state: unknown = {};
      let cardState: unknown = {};
      try {
        const stored = savedRef.current;
        if (stored?.state) state = JSON.parse(stored.state);
        if (stored?.cards) cardState = JSON.parse(stored.cards);
        ownCards.current = stored?.cards ?? undefined;
      } catch {
        setError({ kind: "display", reason: "Saved UI state could not be read" });
        return;
      }
      channel.port1.addEventListener("message", (incoming) => {
        const message = incoming.data;
        if (!message || typeof message !== "object") return;
        if (message.type === "ready") {
          startup?.();
          startup = undefined;
        }
        if (message.type === "error")
          setError({
            kind: "display",
            reason:
              typeof message.reason === "string"
                ? message.reason.slice(0, 200)
                : "UI failed",
          });
        if (message.type === "height" && Number.isFinite(message.value)) {
          const reported = Math.min(12000, Math.max(60, message.value));
          rememberHeight(loadScope, reported);
          setHeight(reported);
        }
        if (
          message.type === "wheel" &&
          Number.isFinite(message.deltaX) &&
          Number.isFinite(message.deltaY) &&
          [0, 1, 2].includes(message.deltaMode)
        ) {
          // The scroll itself chains natively from the frame. This event only
          // reaches the thread's wheel capture, which reads it as the reader
          // moving the transcript; a synthetic wheel never scrolls anything.
          frame.current?.dispatchEvent(
            new WheelEvent("wheel", {
              bubbles: true,
              cancelable: true,
              deltaX: Math.max(-4096, Math.min(4096, message.deltaX)),
              deltaY: Math.max(-4096, Math.min(4096, message.deltaY)),
              deltaMode: message.deltaMode,
            })
          );
        }
        if (
          message.type === "request" &&
          typeof message.value === "string" &&
          message.value.length <= 4000
        )
          setProposal(message.value);
        if (
          message.type === "open-link" &&
          typeof message.url === "string" &&
          message.url.length <= 4000
        ) {
          try {
            const url = new URL(message.url);
            if (url.protocol === "https:" && !url.username && !url.password) {
              setLinkHover((current) => current && { ...current, open: false });
              openLinkRef.current?.(url.href);
            }
          } catch {
            /* Ignore invalid navigation requests. */
          }
        }
        if (message.type === "link-hover") {
          const box = [message.x, message.y, message.width, message.height];
          let url: URL | undefined;
          try {
            if (typeof message.url === "string" && message.url.length <= 4000)
              url = new URL(message.url);
          } catch {
            /* An invalid url ends the hover like a null one. */
          }
          const placed = frame.current;
          if (
            url?.protocol === "https:" &&
            !url.username &&
            !url.password &&
            box.every(Number.isFinite) &&
            message.width >= 0 &&
            message.height >= 0 &&
            placed
          ) {
            // Frame coordinates are relative to its own viewport, and the frame
            // never scrolls. Keep the part of the box inside the frame, and let
            // the frame's offset place it in the widget.
            const left = Math.min(Math.max(message.x, 0), placed.offsetWidth);
            const top = Math.min(Math.max(message.y, 0), placed.offsetHeight);
            setLinkHover({
              url: url.href,
              label:
                typeof message.label === "string" ? message.label.slice(0, 200) : "",
              left: placed.offsetLeft + left,
              top: placed.offsetTop + top,
              width: Math.max(
                0,
                Math.min(message.x + message.width, placed.offsetWidth) - left
              ),
              height: Math.max(
                0,
                Math.min(message.y + message.height, placed.offsetHeight) - top
              ),
              open: true,
            });
          } else {
            setLinkHover((current) => current && { ...current, open: false });
          }
        }
        if (
          message.type === "link-menu" &&
          typeof message.url === "string" &&
          message.url.length <= 4000 &&
          Number.isFinite(message.x) &&
          Number.isFinite(message.y) &&
          frame.current
        ) {
          try {
            const url = new URL(message.url);
            // Frame coordinates are relative to its own viewport.
            const bounds = frame.current.getBoundingClientRect();
            if (url.protocol === "https:" && !url.username && !url.password)
              openLinkMenuRef.current?.(
                url.href,
                bounds.left + message.x,
                bounds.top + message.y,
                frame.current
              );
          } catch {
            /* Ignore invalid link menu requests. */
          }
        }
        if (message.type === "card-state") save.current("cards", message.value);
        if (message.type === "brand-icons")
          void cardBrandIcons(message.names).then((icons) =>
            channel?.port1.postMessage({ type: "brand-icons", icons })
          );
        if (message.type === "save") save.current("state", message.value);
      });
      channel.port1.start();
      // Insert every color probe together. Reading a probe must not invalidate
      // the transcript between consecutive computed-style reads.
      themeProbes = document.createElement("div");
      themeProbes.hidden = true;
      themeProbes.setAttribute("aria-hidden", "true");
      const probes = new Map<string, HTMLSpanElement>();
      for (const [name, fallback] of [
        ["--color-bg-primary", "Canvas"],
        ["--color-text-primary", "inherit"],
        ["--color-text-secondary", "inherit"],
        ["--color-text-tertiary", "#737373"],
        ["--color-border-primary", "#e5e5e5"],
        ["--color-bg-tertiary", "#f5f5f5"],
        ["--color-text-success-primary", "#067647"],
        ["--color-text-error-primary", "#b42318"],
        ["--color-text-warning-primary", "#b54708"],
        ["--color-text-brand-primary", "#6366f1"],
      ]) {
        const probe = document.createElement("span");
        probe.style.color = `var(${name}, ${fallback})`;
        themeProbes.append(probe);
        probes.set(name!, probe);
      }
      ref.current!.append(themeProbes);
      tokenProbe = cardTokenProbe(ref.current!);
      const token = (name: string) => getComputedStyle(probes.get(name)!).color;
      const readTheme = () => {
        const computed = getComputedStyle(ref.current!);
        return {
          scheme: currentTheme.current === "Dark mode" ? "dark" : "light",
          background: token("--color-bg-primary"),
          foreground: token("--color-text-primary"),
          secondary: token("--color-text-secondary"),
          muted: token("--color-text-tertiary"),
          border: token("--color-border-primary"),
          surface: token("--color-bg-tertiary"),
          shadow:
            computed.getPropertyValue("--shadow-xs").trim() || "0 1px 2px #0000000d",
          success: token("--color-text-success-primary"),
          danger: token("--color-text-error-primary"),
          warm: token("--color-text-warning-primary"),
          "motion-enter": `${motionDuration.dialogEnter}ms`,
          "motion-feedback": `${motionDuration.feedbackIn}ms`,
          "motion-stagger": `${motionDuration.revealStagger}ms`,
          "motion-ease": motionEasing.smoothOut,
          accent: token("--color-text-brand-primary"),
          font: computed.fontFamily,
          size: `${compactTypeScale.small.fontSize}px`,
          space: `${spacing.xl}px`,
          radius: `${radius["2xl"]}px`,
          h2: `${compactTypeScale.mini.fontSize}px`,
          h3: `${compactTypeScale.small.fontSize}px`,
          metric: `${compactTypeScale.title2.fontSize}px`,
          small: `${compactTypeScale.mini.fontSize}px`,
          control: `${spacing.md}px`,
        };
      };
      syncTheme.current = () => {
        if (themeFrame) return;
        themeFrame = uiClock.frame(() => {
          themeFrame = undefined;
          const theme = readTheme();
          channel?.port1.postMessage({
            type: "theme",
            theme,
            tokens: tokenProbe?.read(),
          });
        });
      };
      // ScrollArea updates these inherited variables during scrolling. They
      // cannot change the palette and must not trigger transcript style reads.
      themeObserver = new MutationObserver((records) => {
        if (
          records.some(
            (record) =>
              record.attributeName !== "style" ||
              JSON.stringify(themeStyleKey(record.oldValue)) !==
                JSON.stringify(
                  themeStyleKey((record.target as HTMLElement).getAttribute("style"))
                )
          )
        )
          syncTheme.current?.();
      });
      for (
        let ancestor: HTMLElement | null = ref.current;
        ancestor;
        ancestor = ancestor.parentElement
      ) {
        themeObserver.observe(ancestor, {
          attributes: true,
          attributeOldValue: true,
          attributeFilter: ["class", "style", "data-theme"],
        });
      }
      frame.current?.contentWindow?.postMessage(
        {
          type: "comma-ui:init",
          payload,
          state,
          icons: {
            ...cardIconMarkup(),
            train: renderToStaticMarkup(<TrainIcon />),
            clock: renderToStaticMarkup(<ClockIcon />),
            info: renderToStaticMarkup(<CircleInfoIcon />),
          },
          theme: readTheme(),
          tokens: tokenProbe.read(),
          // Card templates pick each card's layout from this widget's identity.
          seed: part.contentId,
          locale: localeRef.current,
          timeZone: viewerTimeZone(),
          copy: cardCopy(messages),
          cardState,
        },
        "*",
        [channel.port2]
      );
    };
    window.addEventListener("message", onReady);
    frame.current?.contentWindow?.postMessage({ type: "comma-ui:hello" }, "*");
    return () => {
      startup?.();
      themeObserver?.disconnect();
      themeFrame?.();
      themeProbes?.remove();
      tokenProbe?.remove();
      syncTheme.current = undefined;
      window.removeEventListener("message", onReady);
      port.current = undefined;
      channel?.port1.postMessage({ type: "stop" });
      channel?.port1.close();
      // The links under a preview leave with this runtime; a remount starts clean.
      setLinkHover(undefined);
    };
  }, [mounted, payload, stateKey, loadScope, messages, part.contentId]);

  // A save on any window reaches the running widget: its own state always (the
  // widget settles on what was kept), its cards' progress unless this copy saved it.
  const savedState = saved?.state;
  const savedCards = saved?.cards;
  useEffect(() => {
    if (!savedState) return;
    try {
      port.current?.postMessage({ type: "state", value: JSON.parse(savedState) });
    } catch {
      setError({ kind: "display", reason: "Saved UI state could not be read" });
    }
  }, [savedState]);
  useEffect(() => {
    if (!savedCards || savedCards === ownCards.current) return;
    ownCards.current = savedCards;
    try {
      port.current?.postMessage({ type: "card-state", value: JSON.parse(savedCards) });
    } catch {
      setError({ kind: "display", reason: "Saved UI state could not be read" });
    }
  }, [savedCards]);

  return (
    <div
      ref={ref}
      className="comma-chat-widget relative"
      data-testid="dynamic-ui-widget"
      style={{ minHeight: !mounted && reading && !failure ? height : undefined }}
    >
      {!mounted && textStands ? (
        <p className="text-sm text-secondary">{part.summary}</p>
      ) : null}
      {mounted ? (
        <iframe
          key={`${stateKey}:${attempt}`}
          ref={frame}
          src="comma-ui://runtime/"
          onLoad={() =>
            frame.current?.contentWindow?.postMessage({ type: "comma-ui:hello" }, "*")
          }
          sandbox="allow-scripts"
          referrerPolicy="no-referrer"
          title={part.summary.slice(0, 100)}
          className="block w-full border-0"
          style={{
            height,
            colorScheme: themeName === "Dark mode" ? "dark" : "light",
            background: "transparent",
          }}
        />
      ) : null}
      {mounted && live && linkHover ? (
        <ChatLinkHoverCard
          // Each link gets its own card, so a move between rows reads its link.
          key={`${linkHover.url}:${linkHover.left}:${linkHover.top}`}
          anchor={
            <span
              aria-hidden="true"
              className="pointer-events-none absolute"
              data-testid="dynamic-ui-link-anchor"
              style={{
                left: linkHover.left,
                top: linkHover.top,
                width: linkHover.width,
                height: linkHover.height,
              }}
            />
          }
          href={linkHover.url}
          label={linkHover.label}
          open={linkHover.open}
          workspaceId={workspaceId}
        />
      ) : null}
      {failure ? (
        <WidgetFailureNotice failure={failure} onRetry={reload} />
      ) : released === "shown" ? (
        <Button hierarchy="secondary-gray" onPress={reload} size="xs">
          {messages.chat_ui_reload()}
        </Button>
      ) : null}
      {proposal ? (
        <div className="stack">
          <p className="whitespace-pre-wrap">{proposal}</p>
          <Button
            isDisabled={!draft}
            onPress={() => {
              draft?.(
                `${proposal}${part.originTaskId ? `\n\n[Continue original task](comma:task/${part.originTaskId})` : ""}\n\n> ${part.summary.replaceAll("\n", "\n> ")}`,
                part.messageId
              );
              setProposal("");
            }}
          >
            {messages.chat_ui_add_to_chat()}
          </Button>
        </div>
      ) : null}
    </div>
  );
}

function themeStyleKey(value: string | null) {
  const style = document.createElement("span").style;
  style.cssText = value ?? "";
  return Array.from(style)
    .filter((name) => !name.startsWith("--scroll-area-"))
    .toSorted()
    .map((name) => [
      name,
      style.getPropertyValue(name),
      style.getPropertyPriority(name),
    ]);
}

/** The viewer's IANA time zone, which card templates show ISO times in. */
function viewerTimeZone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {
    return "";
  }
}
