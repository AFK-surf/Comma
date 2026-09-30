import { renderToStaticMarkup } from "react-dom/server";
import {
  spacing,
  radius,
  compactTypeScale,
  motionDuration,
  motionEasing,
} from "@comma/ui";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { ChatMessagePart } from "@comma/chat-contract";
import { supportsDynamicUiWidgets } from "../../../runtime-chat/nativePlatformActions";
import { Button, ClockIcon, CircleInfoIcon, TrainIcon } from "@comma/ui";
import { useCommaUiThemeName } from "../../commaUiTheme";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import { CommaApiError, type CommaApiClient } from "../../../api";
import {
  useSessionHostController,
  useSessionLifecycleSnapshot,
} from "../../../session/react";
import { cardBrandIcons, cardCopy, cardIconMarkup, cardTokenProbe } from "./cardHost";
import { WidgetFailureNotice, type WidgetFailure } from "./WidgetFailureNotice";

export const DynamicUiDraftContext = createContext<
  ((text: string, messageId: string) => void) | undefined
>(undefined);
export const DynamicUiLinkContext = createContext<((url: string) => void) | undefined>(
  undefined
);
type Props = {
  part: Extract<ChatMessagePart, { kind: "dynamic-ui" }>;
  api: CommaApiClient | undefined;
  groupId: string;
  workspaceId: string;
};
const running = new Map<symbol, () => void>();
function acquire(key: symbol, release: () => void) {
  running.delete(key);
  if (running.size >= 3) {
    const first = running.entries().next().value;
    if (first) {
      running.delete(first[0]);
      first[1]();
    }
  }
  running.set(key, release);
  return () => {
    running.delete(key);
  };
}

export function DynamicUiWidget(props: Props) {
  if (!supportsDynamicUiWidgets() || props.part.version !== 1)
    return <span>{props.part.summary}</span>;
  return <NativeDynamicUiWidget {...props} />;
}

function NativeDynamicUiWidget({ part, api, groupId, workspaceId }: Props) {
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
  const [active, setActive] = useState(true);
  const [error, setError] = useState<WidgetFailure>();
  const [proposal, setProposal] = useState("");
  const [height, setHeight] = useState(160);
  const measuredScope = useRef<string | undefined>(undefined);
  const [loaded, setLoaded] = useState<{
    scope: string;
    attempt: number;
    value: unknown;
  }>();
  const [attempt, setAttempt] = useState(0);
  const reload = useCallback(() => {
    setError(undefined);
    setActive(true);
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
  const payload =
    loaded?.scope === loadScope && loaded.attempt === attempt
      ? loaded.value
      : undefined;
  const mounted = active && visible && payload !== undefined && !!stateKey && !error;

  useEffect(() => {
    setProposal("");
    setError(undefined);
  }, [loadScope]);

  // A connection that drops and comes back reloads the widget without a click.
  useEffect(() => {
    if (error?.kind !== "load") return;
    window.addEventListener("online", reload);
    return () => window.removeEventListener("online", reload);
  }, [error, reload]);

  useEffect(() => {
    if (!ref.current) return;
    let intersects = false;
    let releaseTimer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => {
      clearTimeout(releaseTimer);
      // Window occlusion is not a viewport exit. Keep the bounded live instance
      // so returning to the app does not recreate the iframe and Worker.
      if (document.visibilityState !== "visible") return;
      if (intersects) {
        setVisible(true);
      } else {
        // Absorb a quick scroll reversal without destroying interaction state.
        releaseTimer = setTimeout(() => setVisible(false), 1500);
      }
    };
    const observer = new IntersectionObserver(
      (entries) => {
        intersects = entries.some((entry) => entry.isIntersecting);
        refresh();
      },
      { rootMargin: "240px 0px" }
    );
    document.addEventListener("visibilitychange", refresh);
    observer.observe(ref.current);
    return () => {
      clearTimeout(releaseTimer);
      observer.disconnect();
      document.removeEventListener("visibilitychange", refresh);
    };
  }, []);
  useEffect(() => {
    if (!visible || !active || !api || !user) return;
    if (loaded?.scope === loadScope && loaded.attempt === attempt) return;
    const controller = new AbortController();
    setLoaded(undefined);
    const load = () =>
      api.fetchConversationAttachment(
        groupId,
        part.conversationId,
        part.messageId,
        part.attachmentIndex,
        { signal: controller.signal }
      );
    void load()
      .catch(async (reason: unknown) => {
        // One quiet second try for a failure that time can fix. The text
        // answer stays in place meanwhile, so the reader sees no error.
        if (!transientLoadFailure(reason)) throw reason;
        await pause(loadRetryDelayMs, controller.signal);
        return load();
      })
      .then(
        async (blob) => {
          // The content arrived; only its own size or format can fail here.
          try {
            if (blob.size > 262144) throw Error("UI exceeds 256 KiB");
            const value: unknown = JSON.parse(await blob.text());
            if (!controller.signal.aborted)
              setLoaded({ scope: loadScope, attempt, value });
          } catch (reason) {
            if (!controller.signal.aborted)
              setError({ kind: "display", reason: failureReason(reason) });
          }
        },
        (reason) => {
          if (!controller.signal.aborted)
            setError({ kind: "load", reason: failureReason(reason) });
        }
      );
    return () => controller.abort();
  }, [
    api,
    groupId,
    part.conversationId,
    part.messageId,
    part.attachmentIndex,
    user,
    visible,
    active,
    attempt,
    loaded,
    loadScope,
  ]);

  useEffect(() => {
    if (!mounted || !stateKey) return;
    const release = acquire(instance.current, () => setActive(false));
    let channel: MessageChannel | undefined;
    let initialized = false;
    const updateState = (text: string | null) => {
      try {
        if (text && new TextEncoder().encode(text).length <= 32768)
          channel?.port1.postMessage({ type: "state", value: JSON.parse(text) });
      } catch {
        setError({ kind: "display", reason: "Saved UI state could not be read" });
      }
    };
    // Card progress syncs like widget state, except that the copy that saved
    // it already shows it and is not sent its own change back.
    const updateCardState = (text: string | null) => {
      try {
        if (text && new TextEncoder().encode(text).length <= 32768)
          channel?.port1.postMessage({ type: "card-state", value: JSON.parse(text) });
      } catch {
        setError({ kind: "display", reason: "Saved UI state could not be read" });
      }
    };
    const onStorage = (event: StorageEvent) => {
      if (event.key === `comma.dynamic-ui:${stateKey}`) updateState(event.newValue);
      if (event.key === `comma.dynamic-ui-cards:${stateKey}`)
        updateCardState(event.newValue);
    };
    const onLocalState = (event: Event) => {
      const detail = (event as CustomEvent<{ key: string; text: string }>).detail;
      if (detail.key === stateKey) updateState(detail.text);
    };
    const onLocalCardState = (event: Event) => {
      const detail = (
        event as CustomEvent<{ key: string; text: string; source: symbol }>
      ).detail;
      if (detail.key === stateKey && detail.source !== instance.current)
        updateCardState(detail.text);
    };
    window.addEventListener("storage", onStorage);
    window.addEventListener("comma-ui-state", onLocalState);
    window.addEventListener("comma-ui-card-state", onLocalCardState);
    let timeout = window.setTimeout(
      () => setError({ kind: "display", reason: "UI startup timed out" }),
      5000
    );
    let themeObserver: MutationObserver | undefined;
    let themeProbes: HTMLDivElement | undefined;
    let tokenProbe: ReturnType<typeof cardTokenProbe> | undefined;
    let themeFrame = 0;
    const onReady = (event: MessageEvent) => {
      if (
        initialized ||
        event.source !== frame.current?.contentWindow ||
        event.data?.type !== "comma-ui:ready"
      )
        return;
      initialized = true;
      channel = new MessageChannel();
      let state: unknown = {};
      let cardState: unknown = {};
      try {
        const stored = localStorage.getItem(`comma.dynamic-ui:${stateKey}`);
        if (stored && new TextEncoder().encode(stored).length <= 32768)
          state = JSON.parse(stored);
        const storedCards = localStorage.getItem(`comma.dynamic-ui-cards:${stateKey}`);
        if (storedCards && new TextEncoder().encode(storedCards).length <= 32768)
          cardState = JSON.parse(storedCards);
      } catch {
        setError({ kind: "display", reason: "Saved UI state could not be read" });
        return;
      }
      channel.port1.addEventListener("message", (incoming) => {
        const message = incoming.data;
        if (!message || typeof message !== "object") return;
        if (message.type === "ready") {
          clearTimeout(timeout);
          timeout = 0;
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
          measuredScope.current = loadScope;
          setHeight(Math.min(12000, Math.max(60, message.value)));
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
            if (url.protocol === "https:" && !url.username && !url.password)
              openLinkRef.current?.(url.href);
          } catch {
            /* Ignore invalid navigation requests. */
          }
        }
        if (message.type === "card-state") {
          try {
            const text = JSON.stringify(message.value);
            if (new TextEncoder().encode(text).length > 32768) throw Error();
            localStorage.setItem(`comma.dynamic-ui-cards:${stateKey}`, text);
            window.dispatchEvent(
              new CustomEvent("comma-ui-card-state", {
                detail: { key: stateKey, text, source: instance.current },
              })
            );
          } catch {
            setError({ kind: "display", reason: "UI state could not be saved" });
          }
        }
        if (message.type === "brand-icons")
          void cardBrandIcons(message.names).then((icons) =>
            channel?.port1.postMessage({ type: "brand-icons", icons })
          );
        if (message.type === "save") {
          try {
            const text = JSON.stringify(message.value);
            if (new TextEncoder().encode(text).length > 32768) throw Error();
            localStorage.setItem(`comma.dynamic-ui:${stateKey}`, text);
            window.dispatchEvent(
              new CustomEvent("comma-ui-state", { detail: { key: stateKey, text } })
            );
          } catch {
            setError({ kind: "display", reason: "UI state could not be saved" });
          }
        }
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
        themeFrame = requestAnimationFrame(() => {
          themeFrame = 0;
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
      clearTimeout(timeout);
      themeObserver?.disconnect();
      cancelAnimationFrame(themeFrame);
      themeProbes?.remove();
      tokenProbe?.remove();
      syncTheme.current = undefined;
      window.removeEventListener("message", onReady);
      window.removeEventListener("storage", onStorage);
      window.removeEventListener("comma-ui-state", onLocalState);
      window.removeEventListener("comma-ui-card-state", onLocalCardState);
      channel?.port1.postMessage({ type: "stop" });
      channel?.port1.close();
      release();
    };
  }, [mounted, payload, stateKey, loadScope, messages, part.contentId]);

  return (
    <div
      ref={ref}
      className="comma-chat-widget"
      data-testid="dynamic-ui-widget"
      style={{
        minHeight:
          !mounted && !error && measuredScope.current === loadScope
            ? height
            : undefined,
      }}
    >
      {!mounted ? <p className="text-sm text-secondary">{part.summary}</p> : null}
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
      {error ? (
        <WidgetFailureNotice failure={error} onRetry={reload} />
      ) : active ? null : (
        <Button hierarchy="secondary-gray" onPress={reload} size="xs">
          {messages.chat_ui_reload()}
        </Button>
      )}
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

/**
 * Load failures a second try can fix: no answer from the network, a gateway
 * that could not reach Comma, or a busy service. Anything else fails at once.
 */
const transientStatuses = new Set([408, 429, 502, 503, 504]);
const loadRetryDelayMs = 2000;

function transientLoadFailure(reason: unknown) {
  return reason instanceof CommaApiError
    ? transientStatuses.has(reason.status)
    : reason instanceof TypeError;
}

/** Resolves after `ms`, or at once when the load is abandoned. */
function pause(ms: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(done, ms);
    signal.addEventListener("abort", done, { once: true });
    function done() {
      clearTimeout(timer);
      signal.removeEventListener("abort", done);
      resolve();
    }
  });
}

function failureReason(reason: unknown) {
  return reason instanceof Error ? reason.message : "UI unavailable";
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
