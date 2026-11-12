import type { ListedScreen } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  PanelRightIcon,
  SquareCursorIcon,
  WindowAppIcon,
} from "@comma/ui/components/icons";
import { OverlayPortalProvider } from "@comma/ui/components/portal";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  isDeviceTarget,
  useScreenAudioMuted,
  useScreenStreamTarget,
} from "./remoteScreenStream";
import { useScreenStreamShows } from "./useScreenStreamShows";
import type { ChosenScreen } from "./ScreenMenus";
import { ScreenComputerMenu } from "./ScreenMenus";
import { platformOf } from "./screenModels";
import { screenName, screenNote } from "./useScreenListing";
import {
  ScreenStreamAction,
  ScreenStreamFullscreenAction,
  ScreenStreamMuteAction,
  ScreenStreamName,
  ScreenStreamTargetAction,
  ScreenQualityMenu,
} from "./ScreenStreamChrome";
import { useScreenQuality } from "./screenQuality";
import {
  ScreenStreamStage,
  useFullscreen,
  type ScreenStreamSource,
  type ScreenStreamTarget,
} from "./ScreenStreamStage";
import type { ScreenStreamState } from "./meshScreenStream";
import { ScreenAppLogs } from "./ScreenAppLogs";
import { ScreenDebugBar } from "./ScreenDebugBar";
import { ScreenStatsPanel } from "./ScreenStatsPanel";
import { keepScreenControl, screenInControl } from "./screenWindows";
import { ScreenFrameMark, type ScreenSelection } from "./ScreenFrameMark";
import { ScreenShotThumb, ScreenShutter, type ScreenShot } from "./ScreenShot";
import { useScreenWatchHint } from "./useScreenWatchHint";
import { NoScreenFrame, SelectionsFull, screenFrameCanvas } from "./screenToChat";
import type { ScreenStreamStats as Stats } from "./screenStreamStats";

/**
 * A computer's screen as a side panel page: the big screen, under a toolbar as the browser's has. Here the person may
 * take control, and the page may fill the screen. While the page is not shown (`active` false) it holds no stream.
 * The same page shows a screen in a window of its own (screenWindows.ts): there it moves back to the side panel
 * (`onMoveBack`) instead of moving out (`onOpenWindow`).
 */
export function ScreenStreamPanel({
  appName,
  source,
  active,
  computer,
  initialTarget,
  via,
  controlKey,
  onOpenWindow,
  onMoveBack,
  onAskComma,
}: {
  appName: string | undefined;
  source: ScreenStreamSource;
  active: boolean;
  /** How this device's connection to the computer runs now, over the mesh. */
  via?: "direct" | "relay" | "salix" | undefined;
  /** What it shows first: an app's windows, unless asked for the whole display. */
  initialTarget?: ScreenStreamTarget | undefined;
  /** The screen's side panel page: its Watch or Control goes with it as it moves to its window and back. */
  controlKey?: string | undefined;
  /** Moves the screen to a window of its own, sized by `from` (this page: its picture and its toolbar). */
  onOpenWindow?: ((from: Element) => void) | undefined;
  /** Moves the screen from its own window back to the side panel. */
  onMoveBack?: (() => void) | undefined;
  /**
   * Puts a selection of the screen (its picture, a PNG still being encoded, and what the person wrote about it) and
   * the screen's name into the chat's composer; fails with `NoScreenFrame` when the frame has no picture, and with
   * `SelectionsFull` when the composer takes no more.
   */
  onAskComma?:
    | ((selection: ScreenSelection, name: string) => Promise<void>)
    | undefined;
  /** The computer it is on, for the menu of the person's others beside its name. */
  computer?:
    | {
        workspace: string;
        device: string;
        /** The device of its that this page shows. */
        screen?: ListedScreen | undefined;
        /** Shows another of the person's screens in this one's place; absent in its own window, which shows the one. */
        onChoose?: ((chosen: ChosenScreen) => void) | undefined;
        /** Lets this tab go, its device closed. */
        onClosed?: (() => void) | undefined;
      }
    | undefined;
}) {
  const messages = useCommaMessages();
  const [target, pickTarget] = useScreenStreamTarget(source.key, initialTarget);
  // A simulator or an emulator is the person's own to use: it is driven once its station says no agent's lease on it
  // lasts, and Watch and Control are offered only while one does. Any other screen opens on Watch, with both to choose
  // from, and so does a simulator whose station says nothing of leases (one from before), where the page cannot tell
  // when to let go of it.
  const simulated =
    computer?.screen !== undefined && platformOf(computer.screen) !== undefined;
  // Whether the page was in Control where it last showed (its tab, or its window).
  const keptControl = useRef(controlKey ? screenInControl(controlKey) : false);
  // What the person chose. It drives the computer only while Control is allowed (`canControl`).
  const [wantsControl, setControl] = useState(() => keptControl.current);
  useEffect(
    () => (controlKey ? keepScreenControl(controlKey, wantsControl) : undefined),
    [controlKey, wantsControl]
  );
  // Whether an agent's lease on the device lasts, as its station last said (none yet: undefined). A person who drives
  // it holds the agent's input off, so a lease that starts puts the page on Watch, with Control there to take it back;
  // a simulator with none, or whose lease ends, is the person's. A page that came in Control from its last place while
  // a lease lasted was taken over there, and stays so.
  const [agent, setAgent] = useState<boolean>();
  const agentWas = useRef<boolean | undefined>(undefined);
  useEffect(() => {
    const was = agentWas.current;
    agentWas.current = agent;
    if (agent === undefined || agent === was) return;
    if (agent) {
      if (!(was === undefined && keptControl.current)) setControl(false);
    } else if (simulated) setControl(true);
  }, [agent, simulated]);
  // Another screen in this page's place starts as its own does.
  const shownKey = useRef(source.key);
  useEffect(() => {
    if (shownKey.current === source.key) return;
    shownKey.current = source.key;
    keptControl.current = false;
    agentWas.current = undefined;
    setAgent(undefined);
    setHeld(undefined);
    setShot(undefined);
    if (simulated) setControl(false);
  }, [simulated, source.key]);
  // The frame held to ask about, from Ask Comma until it is sent or put away. Another screen in the page lets it go.
  const [held, setHeld] = useState<HTMLCanvasElement | undefined>();
  // A screenshot as it is taken: the presses of Take screenshot (each flashes the picture), and the one last taken,
  // in the stage's corner for a while.
  const [shutter, setShutter] = useState(0);
  const [shot, setShot] = useState<ScreenShot | undefined>();
  const taken = useRef(0);
  // (the held frame shows under the toolbar, however many rows a narrow panel gives it)
  const header = useRef<HTMLElement>(null);
  const [headerHeight, setHeaderHeight] = useState(0);
  useLayoutEffect(() => {
    const element = header.current;
    if (!element) return undefined;
    const measure = () => setHeaderHeight(element.offsetHeight);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const [state, setShown] = useState<ScreenStreamState>("connecting");
  const wasLive = useRef(false);
  const setState = useCallback((next: ScreenStreamState) => {
    if (next === "live") wasLive.current = true;
    setShown(next);
  }, []);
  const { locked, title, notice, canControl, forget, stage } = useScreenStreamShows({
    target,
    appName,
    deviceName: computer?.screen ? screenName(computer.screen) : undefined,
    dropControl: () => setControl(false),
  });
  const control = wantsControl && canControl;
  // Watch and Control to choose from. A computer's screen or a phone has them in the toolbar, always. A simulator has
  // them on the stage, beside the device, while an agent uses it or while it is not driven (so Control can be asked).
  // A station from before says nothing of leases: the page cannot tell when to let go, so both stay there once the
  // picture comes (a station that says it does so before the first picture).
  const choosesOnStage =
    simulated &&
    (agent === true ||
      (agent === false && !control) ||
      (agent === undefined && state === "live"));
  const watchHint = useScreenWatchHint({
    control,
    canControl,
    notice,
    showing: `${source.key}\n${target}`,
  });
  const choose = (next: boolean) => {
    if (next) watchHint.asked();
    setControl(next);
  };
  const showsDevice = isDeviceTarget(target);
  const version = computer?.screen ? screenNote(computer.screen) : undefined;
  const toggleTarget = () => {
    setHeld(undefined);
    forget();
    wasLive.current = false;
    pickTarget();
  };
  const panel = useRef<HTMLDivElement>(null);
  // The held stream's statistics, for the bars' panel (still.fail's NetChip).
  const [readStats, setReadStats] = useState<(() => Stats) | undefined>();
  const onStats = useCallback(
    (read: (() => Stats) | undefined) => setReadStats(() => read),
    []
  );
  const [full, toggleFull] = useFullscreen(panel, control);
  const [asking, setAsking] = useState(false);
  const noPicture = () =>
    toast.warning(messages.remote_screen_ask_comma_no_picture(), {
      id: "comma-remote-screen-ask-comma-no-picture",
      testId: "comma-remote-screen-ask-comma-no-picture",
    });
  // Ask Comma holds the frame where the stream shows it, and all round it stays as it is; pressed again, it puts the
  // frame away.
  const askComma = () => {
    if (!onAskComma || asking) return;
    if (held) return setHeld(undefined);
    const frame = screenFrameCanvas(panel.current?.querySelector("video"));
    if (frame) setHeld(frame);
    else noPicture();
  };
  // A station's own screenshot, on the way a frame takes: marked and asked about, then sent to the chat beside it.
  const holdPicture = async (png: Blob) => {
    const bitmap = await createImageBitmap(png);
    const canvas = document.createElement("canvas");
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    canvas.getContext("2d")?.drawImage(bitmap, 0, 0);
    bitmap.close();
    setHeld(canvas);
  };
  // A selection of the held frame goes to the chat's composer, and the frame stays held for the next one.
  const sendToComma = async (selection: ScreenSelection) => {
    if (!onAskComma) return;
    setAsking(true);
    try {
      // (asked at once, the picture still being encoded: the chat it goes to is the one beside it now)
      await onAskComma(selection, title);
    } catch (error) {
      if (error instanceof NoScreenFrame) noPicture();
      else if (error instanceof SelectionsFull)
        toast.warning(messages.chat_selections_full(), {
          id: "comma-remote-screen-ask-comma-full",
        });
      else
        toast.error(messages.chat_unavailable(), {
          id: "comma-remote-screen-ask-comma-failed",
          testId: "comma-remote-screen-ask-comma-failed",
        });
    } finally {
      setAsking(false);
    }
  };

  // The computer's sound, where the stream carries it: muted here or played.
  const [audio, setAudio] = useState(false);
  const [muted, toggleMuted] = useScreenAudioMuted(source.key);
  // 画质, one choice for every view.
  const [quality, chooseQuality] = useScreenQuality();
  const way =
    via === "direct"
      ? messages.remote_screen_via_direct()
      : via === "relay"
        ? messages.remote_screen_via_relay()
        : via === "salix"
          ? messages.remote_screen_via_salix()
          : undefined;
  // Under the name while it plays: what the device runs, and no more (how it is reached is the line's tip).
  const line =
    state === "live"
      ? agent === true && !control
        ? // (in words too: the edge round the picture is not all that says an agent is at work)
          [version, messages.remote_screen_agent_using()].filter(Boolean).join(" · ")
        : (version ?? "")
      : state === "failed"
        ? messages.remote_screen_not_connected()
        : wasLive.current
          ? messages.remote_screen_reconnecting()
          : messages.remote_screen_connecting();
  const detail =
    notice ??
    watchHint.refusal ??
    (state === "live"
      ? [version, messages.remote_screen_live(), way].filter(Boolean).join(" · ")
      : line);

  // In a window of its own, the window is named after the screen.
  useEffect(() => {
    const own = panel.current?.ownerDocument;
    if (own && own !== document) own.title = title;
  }, [title]);

  return (
    // Menus and tips open in the document the page is in: the app's window, or the screen's own.
    <OverlayPortalProvider
      getContainer={() =>
        (full ? panel.current : null) ??
        panel.current?.ownerDocument.body ??
        document.body
      }
    >
      <div
        className="comma-remote-screen-panel"
        data-full={full}
        data-locked={locked}
        data-state={state}
        data-testid="remote-screen-panel"
        ref={panel}
      >
        <header className="comma-remote-screen-header" ref={header}>
          <div className="comma-remote-screen-toolbar">
            {/* What shows and how it is held, then what else is done with it: one row, or two in a narrow panel. */}
            <div className="comma-remote-screen-toolbar-lead">
              {/* (its menu: other screens to show here, and the device shut down; a window of its own has the last) */}
              {computer &&
              (computer.onChoose || computer.screen?.capabilities.closable) ? (
                <ScreenComputerMenu
                  closable={
                    computer.screen?.capabilities.closable
                      ? {
                          screen: computer.screen,
                          onClosed: () => computer.onClosed?.(),
                        }
                      : undefined
                  }
                  current={computer.device}
                  currentScreen={computer.screen?.instance}
                  detail={detail}
                  line={notice ?? watchHint.refusal ?? line}
                  onChoose={computer.onChoose}
                  title={title}
                  workspace={computer.workspace}
                />
              ) : (
                <ScreenStreamName
                  detail={detail}
                  line={notice ?? watchHint.refusal ?? line}
                  title={title}
                />
              )}
              {simulated ? null : (
                <fieldset
                  aria-label={messages.remote_screen_control()}
                  className="comma-remote-screen-segments"
                >
                  {[
                    [false, messages.remote_screen_watch()] as const,
                    [true, messages.remote_screen_control()] as const,
                  ].map(([value, label]) => (
                    <Tooltip key={label} content={label} placement="bottom">
                      <Button
                        aria-pressed={control === value}
                        className={control === value ? "bg-sidebar-bg-item" : ""}
                        data-attention={(value && watchHint.attention) || undefined}
                        hierarchy="tertiary-gray"
                        disabled={value && !canControl}
                        onPress={() => choose(value)}
                        size="xs"
                      >
                        {label}
                      </Button>
                    </Tooltip>
                  ))}
                </fieldset>
              )}
            </div>
            <div className="comma-remote-screen-toolbar-tools">
              <ScreenQualityMenu onChoose={chooseQuality} quality={quality} />
              <span className="comma-remote-screen-action-group">
                {onAskComma ? (
                  <ScreenStreamAction
                    disabled={asking || state !== "live"}
                    icon={<SquareCursorIcon aria-hidden />}
                    label={messages.remote_screen_ask_comma()}
                    onClick={askComma}
                    pressed={held !== undefined}
                    placement="bottom"
                  />
                ) : null}
                <ScreenStatsPanel read={readStats} way={way} />
                {audio ? (
                  <ScreenStreamMuteAction
                    muted={muted}
                    onToggle={toggleMuted}
                    placement="bottom"
                  />
                ) : null}
                {showsDevice ? null : (
                  <ScreenStreamTargetAction
                    onToggle={toggleTarget}
                    placement="bottom"
                    target={target}
                  />
                )}
                {onOpenWindow ? (
                  <ScreenStreamAction
                    icon={<WindowAppIcon aria-hidden />}
                    label={messages.remote_screen_open_window()}
                    onClick={() => {
                      if (panel.current) onOpenWindow(panel.current);
                    }}
                    placement="bottom"
                  />
                ) : null}
                {onMoveBack ? (
                  <ScreenStreamAction
                    icon={<PanelRightIcon aria-hidden />}
                    label={messages.window_move_back()}
                    onClick={onMoveBack}
                    placement="bottom"
                  />
                ) : null}
                <ScreenStreamFullscreenAction
                  full={full}
                  onToggle={toggleFull}
                  placement="bottom"
                />
              </span>
            </div>
          </div>
        </header>
        {active ? (
          <ScreenStreamStage
            control={control}
            heldFrame={held}
            onControlRefused={(why) => {
              setControl(false);
              watchHint.refused(why);
            }}
            {...stage}
            choice={
              simulated
                ? {
                    shown: choosesOnStage,
                    canControl,
                    attention: watchHint.attention,
                    onChoose: choose,
                  }
                : undefined
            }
            onAgent={setAgent}
            onAudio={setAudio}
            onState={setState}
            onStats={onStats}
            quality={quality}
            source={source}
            state={state}
            target={target}
            watching={watchHint.watching}
          />
        ) : null}
        {/* (only while it is driven: a station from before lists none, and neither does a phone or a computer's screen) */}
        {active && control && computer?.screen?.capabilities.debug?.actions.length ? (
          <ScreenDebugBar
            key={`${computer.workspace}\n${computer.device}\n${computer.screen.id}\n${computer.screen.instance ?? ""}`}
            device={computer.device}
            inert={held !== undefined}
            live={state === "live"}
            onAskComma={onAskComma ? holdPicture : undefined}
            onScreenshot={(png, name) => {
              taken.current += 1;
              setShot({ id: taken.current, png, name });
            }}
            onShutter={() => setShutter((count) => count + 1)}
            picture={() => panel.current?.querySelector("video") ?? null}
            screen={computer.screen}
            workspace={computer.workspace}
          />
        ) : null}
        {/* (a device whose computer lists its app's logs: a station from before lists none, and shows no pane) */}
        {active && computer?.screen?.capabilities.logs ? (
          <ScreenAppLogs
            device={computer.device}
            inert={held !== undefined}
            screen={computer.screen}
            workspace={computer.workspace}
          />
        ) : null}
        {/* A screenshot as it is taken: the shutter over the picture, then the picture in the stage's corner a while. */}
        <ScreenShutter
          panel={() => panel.current}
          picture={() => panel.current?.querySelector("video") ?? null}
          shot={shutter}
        />
        {shot && !held ? (
          <ScreenShotThumb
            key={shot.id}
            onAsk={
              onAskComma
                ? () => {
                    setShot(undefined);
                    void holdPicture(shot.png);
                  }
                : undefined
            }
            onGone={() => setShot(undefined)}
            panel={() => panel.current}
            picture={() => panel.current?.querySelector("video") ?? null}
            shot={shot}
            stage={() =>
              panel.current?.querySelector(":scope > .comma-remote-screen-stage") ??
              null
            }
          />
        ) : null}
        {held ? (
          <ScreenFrameMark
            frame={held}
            onAsk={(selection) => void sendToComma(selection)}
            onCancel={() => setHeld(undefined)}
            top={headerHeight}
          />
        ) : null}
      </div>
    </OverlayPortalProvider>
  );
}
