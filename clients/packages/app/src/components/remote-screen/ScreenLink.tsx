import { useCore, type ListedScreen, type ScreenViewEvent } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { MacbookIcon, PhoneDynamicIslandIcon } from "@comma/ui/components/icons";
import { Tag } from "@comma/ui/components/tag";
import { useEffect, useRef, useState, type RefObject } from "react";
import { useActiveWorkspaceId } from "../activeWorkspace";
import { useOptionalChatSidebar } from "../chat-sidebar/ChatSidebarContext";
import { createScreenDecoder } from "./screenDecoder";
import type { ScreenLink } from "./screenLinks";
import { useOwnComputers } from "./ScreenMenus";
import {
  screenName,
  screenNote,
  useScreenDevicesEnabled,
  useScreenListing,
} from "./useScreenListing";

/** The picture a preview asks for, in device pixels at most: the card's width, twice over. */
const PEEK_SIZE = 640;
/** A preview that could not open (no room at the station now) tries again after this, while its card is on the screen. */
const PEEK_AGAIN_MS = 5_000;
/** A preview that has no answer from its station after this gives up and tries again. The helper's own limit to open is 15 s. */
const PEEK_OPEN_MS = 20_000;

/** So many taken at most at once (still.fail's web/src/screen/frames.ts `Slots`). */
class Slots {
  #used = 0;
  readonly most: number;
  constructor(most: number) {
    this.most = most;
  }
  /** One more taken, unless all are. */
  take(): boolean {
    if (this.#used >= this.most) return false;
    this.#used++;
    return true;
  }
  free(): void {
    this.#used = Math.max(0, this.#used - 1);
  }
}

/**
 * The previews this page decodes as a video at once, two at most (an Android device's, which sends nothing else: WebCodecs,
 * with the hardware's decoders, which a phone has few of); one more is let go, its mark shown, and asks again later.
 * Ported from still.fail's web/src/screen/ScreenLink.tsx `videoPeeks`.
 */
const videoPeeks = new Slots(2);

/** Whether `element` is on the screen now, the page shown: a preview is open only then. */
function useShown(element: RefObject<HTMLElement | null>): boolean {
  const [inView, setInView] = useState(false);
  const [visible, setVisible] = useState(
    () => typeof document === "undefined" || document.visibilityState === "visible"
  );
  useEffect(() => {
    const node = element.current;
    if (!node || typeof IntersectionObserver === "undefined") return undefined;
    const watch = new IntersectionObserver(([entry]) =>
      setInView(entry?.isIntersecting === true)
    );
    watch.observe(node);
    const shown = () => setVisible(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", shown);
    return () => {
      watch.disconnect();
      document.removeEventListener("visibilitychange", shown);
    };
  }, [element]);
  return inView && visible;
}

/**
 * The screen live in its card: a preview view (`peek`: it only looks, wakes nothing, and comes small and about twice a
 * second at the station), open while the card is on the screen. Its mark shows until a picture comes. It asks JPEG and
 * H.264: a source that has JPEG (a simulator) sends a picture now and then, one with H.264 alone (an Android device) video.
 */
function ScreenPeek({
  workspace,
  device,
  screen,
  mark,
}: {
  workspace: string;
  device: string;
  screen: ListedScreen;
  mark: React.ReactNode;
}) {
  const core = useCore();
  const box = useRef<HTMLSpanElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const shown = useShown(box);
  const [drawn, setDrawn] = useState(false);
  useEffect(() => {
    const paper = canvas.current;
    if (!shown || !paper || typeof VideoDecoder === "undefined") return undefined;
    const stop = new AbortController();
    let view: number | undefined;
    let cancelAgain: (() => void) | undefined;
    let jpeg = false;
    /** This card's view holds one of the page's video decoders (`videoPeeks`), until it lets go of it. */
    let decoding = false;
    const letGo = () => {
      if (decoding) videoPeeks.free();
      decoding = false;
    };
    // The view open now: a decoder that cannot go on ends it, and the card opens another after its wait.
    let current: AbortController | undefined;
    // What it last logged of a failure: a card that asks again every few seconds says the same thing once.
    let lastFailure: string | undefined;
    const failed = (why: string) => {
      if (why === lastFailure) return;
      lastFailure = why;
      console.warn("Screen preview did not open", { device, screen: screen.id, why });
    };
    const draw = (picture: VideoFrame | ImageBitmap, ts: number) => {
      if (!stop.signal.aborted) {
        const video = "displayWidth" in picture;
        paper.width = video ? picture.displayWidth : picture.width;
        paper.height = video ? picture.displayHeight : picture.height;
        paper.getContext("2d")?.drawImage(picture, 0, 0);
        setDrawn(true);
        if (view !== undefined)
          void core
            .call("devices.sendToScreenView", { view, ack: ts })
            .catch(() => undefined);
      }
      picture.close();
    };
    const ack = (ts: number) => {
      if (view !== undefined)
        void core
          .call("devices.sendToScreenView", { view, ack: ts })
          .catch(() => undefined);
    };
    const decoder = createScreenDecoder({
      frame: (frame) => draw(frame, frame.timestamp),
      letGo: ack,
      keyframe: () => {
        if (view !== undefined)
          void core
            .call("devices.sendToScreenView", { view, keyframe: true })
            .catch(() => undefined);
      },
      reopen: () => current?.abort(),
    });
    const onEvent = (event: ScreenViewEvent) => {
      if (event.type === "open") view = event.view;
      else if (event.type === "config") {
        lastFailure = undefined;
        jpeg = event.codec === "jpeg";
        if (!jpeg && !decoding) {
          // All the page's video decoders taken: this view goes, and the card asks again later.
          if (!videoPeeks.take()) return current?.abort();
          decoding = true;
        }
        if (jpeg) decoder.reset();
        else decoder.configure(event);
      } else if (event.type === "video" && jpeg) {
        const ts = event.ts;
        void createImageBitmap(
          new Blob([event.data as BlobPart], { type: "image/jpeg" })
        ).then(
          (picture) => draw(picture, ts),
          () => undefined
        );
      } else if (event.type === "video") decoder.decode(event);
    };
    const open = () => {
      const opened = new AbortController();
      current = opened;
      const abort = () => opened.abort();
      stop.signal.addEventListener("abort", abort, { once: true });
      // (its decoder given back to the page as the view goes)
      opened.signal.addEventListener("abort", letGo, { once: true });
      // A station that never answers would hold the call, and so the next try, forever.
      let timedOut = false;
      const cancelOpenLimit = uiClock.after(PEEK_OPEN_MS, () => {
        timedOut = true;
        opened.abort();
      });
      void core
        .call(
          "devices.openScreenView",
          {
            workspace,
            device,
            target: screen.id,
            instance: screen.instance,
            codecs: ["jpeg", "h264"],
            control: false,
            peek: true,
            maxWidth: PEEK_SIZE,
            maxHeight: PEEK_SIZE,
          },
          ((event: ScreenViewEvent) => {
            if (event.type === "open") cancelOpenLimit();
            if (!opened.signal.aborted) onEvent(event);
          }) as (value: unknown) => void,
          opened.signal
        )
        .catch((error: unknown) => {
          // (a view this card let go of itself is no failure)
          if (timedOut) failed(`no answer in ${PEEK_OPEN_MS / 1000} s`);
          else if (!opened.signal.aborted)
            failed(error instanceof Error ? error.message : String(error));
        })
        .finally(() => {
          cancelOpenLimit();
          stop.signal.removeEventListener("abort", abort);
          view = undefined;
          decoder.reset();
          letGo();
          if (!stop.signal.aborted) cancelAgain = uiClock.after(PEEK_AGAIN_MS, open);
        });
    };
    open();
    return () => {
      stop.abort();
      cancelAgain?.();
      decoder.reset();
    };
  }, [core, device, screen.id, screen.instance, shown, workspace]);
  // Its shape as its station lists it, within bounds: the card does not change size as a picture comes.
  const ratio =
    screen.width > 0 && screen.height > 0
      ? Math.min(2, Math.max(0.75, screen.width / screen.height))
      : 16 / 10;
  return (
    <span
      className="comma-screen-card-peek"
      data-testid="screen-card-peek"
      ref={box}
      style={{ aspectRatio: String(ratio) }}
    >
      <canvas data-drawn={drawn || undefined} ref={canvas} />
      {drawn ? null : <span className="comma-screen-card-mark">{mark}</span>}
    </span>
  );
}

/**
 * A link to a screen alone on its line: the screen's card, as a message's file has one, with the screen live above its
 * words where its station previews it. A press shows it in a tab of the side panel.
 */
export function ScreenLinkCard({
  link,
  workspaceId,
}: {
  link: ScreenLink;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const sidebar = useOptionalChatSidebar();
  const card = useRef<HTMLButtonElement>(null);
  const display = link.screen === "display";
  const shown = useShown(card);
  // (a computer's own screen needs nothing of the list, which wakes its adb)
  const { screens, read } = useScreenListing(
    workspaceId,
    link.device,
    shown && !display
  );
  const computer = useOwnComputers(workspaceId).find(
    (one) => one.device_id === link.device
  );
  // The device the card first found there: another in its place later is not the one the message meant.
  const [meant, setMeant] = useState<string>();
  const there = screens.find((one) => one.id === link.screen);
  useEffect(() => {
    if (there && meant === undefined) setMeant(there.instance);
  }, [meant, there]);
  const screen =
    there && (meant === undefined || there.instance === meant) ? there : undefined;
  const gone = display ? !computer : read && !screen;
  const mark = display ? (
    <MacbookIcon aria-hidden />
  ) : (
    <PhoneDynamicIslandIcon aria-hidden />
  );
  // A successful listing confirms that this target has ended. A failed read keeps the last listing.
  if (gone) {
    return (
      <Tag data-testid="screen-card-ended" size="md">
        {display ? (
          <MacbookIcon aria-hidden className="size-4" />
        ) : (
          <PhoneDynamicIslandIcon aria-hidden className="size-4" />
        )}
        {messages.remote_screen_ended()}
      </Tag>
    );
  }
  const named = link.label?.trim();
  const label =
    !display &&
    (named === link.screen ||
      named === link.screen.replace(/^(android|simulator):/, ""))
      ? undefined
      : named || undefined;
  const title =
    label ??
    (screen
      ? screenName(screen)
      : display
        ? (computer?.name ?? messages.remote_screen_display())
        : link.screen.startsWith("simulator:")
          ? messages.remote_screen_simulator()
          : messages.remote_screen_device());
  const line = display
    ? messages.remote_screen_display()
    : screen
      ? (screenNote(screen) ?? messages.remote_screen_device_running())
      : messages.remote_screen_info_unavailable();
  const host = sidebar?.activeHost;
  const open = () => {
    if (!sidebar || !host) return;
    sidebar.openScreen(host, {
      workspaceId,
      device: link.device,
      apps: [],
      ...(screen ? { screen } : { target: "display" as const }),
    });
  };
  const live = screen?.peek ? screen : undefined;
  return (
    <button
      aria-label={`${title} · ${messages.remote_screen_expand()}`}
      className="comma-screen-card"
      data-live={live ? true : undefined}
      data-testid="screen-card"
      disabled={!host || (!display && !screen)}
      onClick={open}
      ref={card}
      type="button"
    >
      {live ? (
        <ScreenPeek
          device={link.device}
          mark={mark}
          screen={live}
          workspace={workspaceId}
        />
      ) : (
        <span aria-hidden className="comma-screen-card-tile">
          {mark}
        </span>
      )}
      <span className="comma-screen-card-words">
        <strong>{title}</strong>
        <span>{line}</span>
      </span>
    </button>
  );
}

/** A Task's Properties: the Android devices on the computer it runs on, each a way to its tab, where the mesh is on. */
export function TaskScreenRows({ device }: { device: string }) {
  const enabled = useScreenDevicesEnabled();
  const sidebar = useOptionalChatSidebar();
  // (a surface with no side panel, the Task panel's own window, has nowhere to show one,
  // and reads nothing for it: not even the workspace list)
  const shown = enabled && sidebar?.activeHost !== undefined;
  const workspace = useActiveWorkspaceId(shown);
  const on = shown && workspace !== undefined;
  const { screens } = useScreenListing(workspace, device, on);
  const messages = useCommaMessages();
  if (!on) return null;
  return screens.map((screen) => (
    <div
      className="comma-task-panel-row"
      data-testid="task-panel-screen"
      key={screen.id}
    >
      <button
        className="comma-task-panel-pill min-w-0"
        data-interactive="true"
        onClick={() =>
          sidebar.openScreen(sidebar.activeHost!, {
            workspaceId: workspace,
            device,
            apps: [],
            screen,
          })
        }
        title={`${screen.title} · ${messages.remote_screen_device_running()}`}
        type="button"
      >
        <PhoneDynamicIslandIcon className="size-5 shrink-0 text-quaternary" />
        <span className="truncate">{screenName(screen)}</span>
      </button>
    </div>
  ));
}
