import { uiClock } from "@comma/ui/clock";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { toast } from "@comma/ui/components/toast";
import {
  detectAppKeybindingPlatform,
  matchesAppKeyStroke,
} from "@comma/ui/components/settings-shortcut";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type RefObject,
} from "react";
import { flushSync } from "react-dom";
import { useOptionalAppShortcutBindings } from "../shortcuts/commaAppShortcuts";
import type { ScreenViewMessage, ScreenViewOpen } from "./meshScreenStream";
import { screenFailureDetail } from "./screenFailure";
import {
  holdScreenStream,
  type HeldScreenStream,
  type HeldScreenStreamView,
} from "./remoteScreenStream";
import {
  screenDeviceActions,
  screenDevicePress,
  screenDeviceShape,
  screenDeviceShortcut,
  type ScreenDeviceAction,
  type ScreenDeviceState,
  type ScreenStreamCapabilities,
} from "./screenDevice";
import { ScreenDeviceButtons, ScreenDeviceFrame } from "./ScreenDeviceFrame";
import {
  deviceMods,
  goesAsKey,
  InputFrame,
  modifiers,
  pictureFraction,
  textPieces,
  typesText,
  wheelPixels,
  wireButton,
  type ScreenStreamInput,
} from "./screenStreamInput";
import type { ScreenStreamState } from "./meshScreenStream";
import { pasted, putClip, takesPaste, type ScreenClipType } from "./screenClipboard";
import { useScreenDeviceStanding } from "./useScreenDeviceStanding";
import { screenCaseCovers, type ScreenCaseButton } from "./screenCase";
import { useScreenCase } from "./useScreenCase";
import { useScreenTouchInput } from "./useScreenTouchInput";
import { viewOf } from "./screenWindows";
import { ScreenControlChoice } from "./ScreenStreamChrome";
import {
  ScreenAgentPresence,
  type ScreenAgentPresenceHandle,
} from "./ScreenAgentPresence";
import { ScreenPointerShape, cursorOf, pointerPlace } from "./ScreenPointer";
import type { ScreenCursor, ScreenStreamStats } from "./screenStreamStats";
import type { ScreenDeviceId, ScreenQuality } from "@comma/core-client";

/** What a stage shows: a computer's app or display, or one of its devices by the id the station lists it under. */
export type ScreenStreamTarget = "app" | "display" | ScreenDeviceId;

export type ScreenStreamRequest = {
  control: boolean;
  /** The stage's ground as `#rrggbb`: the computer paints it outside the captured app or phone. */
  background: string | undefined;
};

/** How a stage reaches the computer whose screen it shows. */
export type ScreenStreamSource = {
  /** Names what the source shows. Stages with the same key share one stream. */
  key: string;
  /** The way to the screen, over the mesh. */
  view: {
    open(
      request: Pick<ScreenStreamRequest, "control" | "background"> & {
        target: ScreenStreamTarget;
        /** A device's picture, its long side at most this: as large as it shows. */
        maxWidth?: number;
        maxHeight?: number;
        /** The apps to show by name, once they are known: never what is frontmost by then. */
        apps?: readonly string[];
        /** What this page decodes, the one it would rather have first. */
        codecs: readonly string[];
        /** The computer's sound too, where it captures it: `opus` where this page decodes Opus. */
        audio?: boolean | "opus";
        /** The 画质 chosen (none: 自动). */
        quality?: ScreenQuality;
      },
      onEvent: Parameters<ScreenViewOpen>[0],
      signal: AbortSignal
    ): Promise<unknown>;
    send(view: number, message: ScreenViewMessage): void;
  };
  /** What it can do besides showing a computer's screen. A computer's source has none. */
  capabilities?: ScreenStreamCapabilities | undefined;
  /** Whether it is this app's own computer: its sound is not carried (it would be played back into itself). */
  self?: (() => boolean) | undefined;
};

/**
 * A computer's screen, live: one app's windows or the whole desktop. With
 * `control`, the pointer and keyboard over the picture reach the computer.
 * The stream changes when the source or target changes; Watch and Control
 * change on the stream as it runs.
 */
export function ScreenStreamStage({
  target,
  control,
  heldFrame,
  source,
  state,
  onState,
  onTarget,
  onFailure,
  onShape,
  onControlRefused,
  onStats,
  onAudio,
  onAgent,
  quality,
  watching,
  choice,
}: {
  /**
   * Watch or Control, chosen on the stage beside the device and not in a toolbar (a simulator's): whether there is a
   * choice to show now, and what a choice does.
   */
  choice?:
    | {
        shown: boolean;
        canControl: boolean;
        attention?: boolean | undefined;
        onChoose(control: boolean): void;
      }
    | undefined;
  target: ScreenStreamTarget;
  control: boolean;
  /**
   * A frame of the screen held to ask about: it shows in the picture's place, over the stream, in the screen's shape and
   * under a device's case, so the device stands as it did. Nothing on the stage takes a press, a key or the focus while
   * it is held, so nothing reaches the screen, and the stage says nothing of its stream. Watch or Control stays as it
   * is, and the stream runs on.
   */
  heldFrame?: HTMLCanvasElement | undefined;
  source: ScreenStreamSource;
  state: ScreenStreamState;
  onState(state: ScreenStreamState): void;
  onTarget?: ((target: HeldScreenStreamView["target"]) => void) | undefined;
  onFailure?: ((failure: string | undefined) => void) | undefined;
  /** The picture's width over its height, once it has one and whenever it changes. */
  onShape?: ((ratio: number) => void) | undefined;
  /** The computer did not let this stage drive: Control is the person's to ask again. */
  onControlRefused?: ((why: string) => void) | undefined;
  /** How to read the stream's statistics while it is held (undefined once it is let go): for the stats panel. */
  onStats?: ((read: (() => ScreenStreamStats) | undefined) => void) | undefined;
  /** Whether the computer's sound comes on the stream, as that changes: for the bar's mute switch. */
  onAudio?: ((audio: boolean) => void) | undefined;
  /** Whether an agent's lease on the device lasts, each time its station says (nothing until it has). */
  onAgent?: ((on: boolean) => void) | undefined;
  /** The 画质 chosen (none: 自动): another opens the view anew. Every stage of one source passes the same. */
  quality?: ScreenQuality | undefined;
  /**
   * Where the picture is there to be used and Watch only looks at it: what to say on it, whether it is said now, and
   * what a press or typing on it in Watch calls. Absent where a press on the picture means something else (a card's: a
   * drag).
   */
  watching?: { hint: string; shown: boolean; onInput(): void } | undefined;
}) {
  const messages = useCommaMessages();
  const video = useRef<HTMLVideoElement>(null);
  // The last frame of the stream before this one, shown until this one plays.
  const still = useRef<HTMLCanvasElement>(null);
  const peer = useRef<HeldScreenStream | null>(null);
  // Hears the keys while the stage has the focus: an IME composes in it, and a paste lands in it
  // (still.fail web/src/screen/input.ts, "keys, text, an IME, a paste"). Not ported: its keys row's held modifiers
  // (Cue has no keys row). A paste of a type the screen's clipboard carries goes onto it and is pasted there
  // (screenClipboard.ts); else it is typed as text.
  const keys = useRef<HTMLTextAreaElement>(null);
  // Where the last press on the picture was, in the keys' parent's pixels: this device's input method opens its own
  // windows (a pinyin candidate list) there, by the caret the keys field says it has. Before any press, at the
  // picture's lower left corner. The screen's own caret is not known here. Ported from still.fail #3843
  // (apps/mbui/src/sfpages/screen_stage.mbt `MouseDrive.pressed`, `key_catcher_place`; the web host's `setIme`
  // puts its textarea at that place).
  const pressedAt = useRef<{ left: number; top: number } | null>(null);
  const placeKeys = useCallback(() => {
    const field = keys.current;
    const picture = video.current;
    if (!field || !picture) return;
    const at = pressedAt.current ?? pictureCorner(picture);
    field.style.left = `${at.left}px`;
    field.style.top = `${at.top}px`;
  }, []);
  const pressHere = (event: ReactPointerEvent<HTMLVideoElement>) => {
    pressedAt.current = pressPlace(event.currentTarget, event);
    placeKeys();
  };
  // The latest pointer move and the wheel summed, sent once a frame.
  const [frame] = useState(
    () =>
      new InputFrame(
        (input) => peer.current?.send(input),
        (run) => uiClock.frame(run, video.current ? viewOf(video.current) : undefined)
      )
  );
  // What undoes each button and key held down on the computer.
  const holding = useRef(new Map<string, ScreenStreamInput>());
  const letGo = (send: HeldScreenStream["send"] | undefined, buttonsOnly = false) => {
    for (const [what, release] of holding.current) {
      if (buttonsOnly && ("t" in release || release.type !== "up")) continue;
      send?.(release);
      holding.current.delete(what);
    }
  };
  const calls = useRef({
    source,
    onState,
    onShape,
    onTarget,
    onFailure,
    onControlRefused,
    onStats,
    onAudio,
    onAgent,
  });
  calls.current = {
    source,
    onState,
    onShape,
    onTarget,
    onFailure,
    onControlRefused,
    onStats,
    onAudio,
    onAgent,
  };
  // An agent at work on the device: its edge and cursor over the picture (ScreenAgentPresence.tsx).
  const [agent, setAgent] = useState(false);
  const presence = useRef<ScreenAgentPresenceHandle>(null);
  // The clipboard's types the stream carries while it drives (none: a paste is typed).
  const clipTypes = useRef<readonly ScreenClipType[]>([]);
  // What a new stream is held with; a change of it goes to the stream that runs (below).
  const controlNow = useRef(control);
  controlNow.current = control;
  // The screen's pointer (ScreenPointer.tsx): where the station says it is, drawn at once as it moves, apart from
  // React; its shape as React draws it. While this device's mouse is over the picture and drives, that mouse is the
  // pointer, in the screen's shape.
  const pointer = useRef<HTMLSpanElement>(null);
  const cursor = useRef<ScreenCursor | undefined>(undefined);
  const hovering = useRef(false);
  const driving = useRef(control);
  driving.current = control;
  const [pointerShape, setPointerShape] = useState("default");
  const drawPointer = useCallback(() => {
    const el = pointer.current;
    const picture = video.current;
    if (!el || !picture) return;
    const at = cursor.current;
    const place = pointerPlace(
      at,
      {
        left: picture.offsetLeft,
        top: picture.offsetTop,
        width: picture.clientWidth,
        height: picture.clientHeight,
      },
      { width: picture.videoWidth, height: picture.videoHeight },
      hovering.current && driving.current
    );
    el.hidden = place === null;
    if (place) {
      el.style.left = `${place.left}px`;
      el.style.top = `${place.top}px`;
      el.style.setProperty("--pointer", `${place.size}px`);
    }
    picture.style.cursor = cursorOf(at, driving.current);
    if (at) setPointerShape(at.shape);
  }, []);
  useEffect(drawPointer, [control, drawPointer]);
  const [failure, setFailure] = useState<string>();
  const capabilities = source.capabilities;
  const device = capabilities !== undefined;
  // Foldable panel changes have different mounting axes. Their source owns the transition.
  const animated = !capabilities?.poses?.length;
  const [deviceState, setDeviceState] = useState<ScreenDeviceState>();
  // The picture's shape picks the body's panel, and how it stands.
  const [pictureRatio, setPictureRatio] = useState<number>();
  // What the frame draws: it and the picture change together (useScreenDeviceStanding).
  const { stood, holdForTurn } = useScreenDeviceStanding({
    capabilities,
    pictureRatio,
    reported: deviceState?.orientation,
    animated,
    video,
    still,
  });
  const shape = capabilities?.shapes
    ? screenDeviceShape(capabilities.shapes, stood.ratio)
    : undefined;
  // A simulator's case as Xcode has it, once its pictures have come: drawn instead of the plain body.
  const cased = useScreenCase(capabilities?.chrome, stood.ratio, stood.turn);
  // What a device's picture is asked at: its long side in this screen's pixels. It only grows while the stage stays.
  const [side, setSide] = useState<number | undefined>(undefined);
  // The panel it shows now: a foldable's cover is taller than its inner screen, and asks more once it shows.
  const longest = shape
    ? Math.max(
        shape.screen.width / shape.screen.height,
        shape.screen.height / shape.screen.width
      )
    : undefined;
  useEffect(() => {
    const stage = video.current?.closest<HTMLElement>(".comma-remote-screen-stage");
    if (!stage || longest === undefined) return undefined;
    const measure = () => {
      const { width, height } = stage.getBoundingClientRect();
      setSide((was) => Math.max(was ?? 0, deviceSide(width, height, longest)));
    };
    measure();
    const watch = new (viewOf(stage).ResizeObserver)(measure);
    watch.observe(stage);
    return () => watch.disconnect();
  }, [longest]);
  const { handlers: touchHandlers, cancel: cancelTouch } = useScreenTouchInput({
    enabled: control && device,
    point: (event) => (video.current?.videoWidth ? point(event) : undefined),
    send: (input) => peer.current?.send(input),
  });
  const detail = screenFailureDetail(failure, messages);

  // A device's picture is asked at its side from the start: a view opened before that is measured would be one more
  // the station counts against the person, ended a moment later for the one at its size.
  const sized = longest === undefined || side !== undefined;
  useEffect(() => {
    if (!sized) return undefined;
    const picture = video.current;
    const kept = still.current;
    let refused: string | undefined;
    let lastState: ScreenStreamState | undefined;
    const held = holdScreenStream(
      {
        source: calls.current.source,
        target,
        control: controlNow.current,
        ...(side ? { side } : {}),
        ...(quality ? { quality } : {}),
        background: picture?.closest(".comma-remote-screen-stage")
          ? hexColor(
              getComputedStyle(picture.closest(".comma-remote-screen-stage")!)
                .backgroundColor
            )
          : undefined,
      },
      ({
        state: next,
        media,
        failure: why,
        target: showing,
        device: stands,
        refused: no,
        clipboard,
        audio,
        agent: leased,
      }) => {
        clipTypes.current = clipboard ?? [];
        calls.current.onAudio?.(audio === true);
        setAgent(leased === true);
        if (leased !== undefined) calls.current.onAgent?.(leased);
        if (no !== refused) {
          refused = no;
          if (no && controlNow.current) calls.current.onControlRefused?.(no);
        }
        setDeviceState(stands);
        if (next === "connecting" && lastState === "live") keepLastFrame(picture, kept);
        lastState = next;
        if (picture && picture.srcObject !== media) picture.srcObject = media;
        setFailure(next === "failed" ? why : undefined);
        calls.current.onState(next);
        calls.current.onTarget?.(showing);
        calls.current.onFailure?.(next === "failed" ? why : undefined);
      }
    );
    peer.current = held;
    cursor.current = undefined;
    const stopPointing = held.watchCursor((at) => {
      cursor.current = at;
      drawPointer();
    });
    drawPointer();
    const stopAgentPointing = held.watchAgentPointer((at) =>
      presence.current?.point(at)
    );
    calls.current.onStats?.(held.stats);
    return () => {
      stopPointing();
      stopAgentPointing();
      setAgent(false);
      clipTypes.current = [];
      calls.current.onAudio?.(false);
      calls.current.onStats?.(undefined);
      frame.drop();
      letGo(held.send);
      cancelTouch(held.send);
      peer.current = null;
      keepLastFrame(picture, kept);
      held.release();
    };
  }, [cancelTouch, drawPointer, frame, source.key, target, side, sized, quality]);

  // Watch or Control on the stream as it runs: what is held down is let go of first, and a move or wheel still
  // waiting for its frame is not sent.
  useEffect(() => {
    const held = peer.current;
    if (!held) return;
    if (!control) {
      frame.drop();
      letGo(held.send);
      cancelTouch(held.send);
    }
    held.control(control);
  }, [control, cancelTouch, frame]);

  // A copy made on the screen while this stage drives it: onto this device's clipboard at once where the browser lets
  // it, else offered with a press (still.fail ScreenViewer.tsx `copiedThere`, its CopiedNote as a toast's action).
  useEffect(() => {
    const held = peer.current;
    if (!held || !control) return undefined;
    return held.onCopied((clip) => {
      const done = () =>
        toast.success(
          clip.type === "text"
            ? messages.remote_screen_copied()
            : messages.remote_screen_copied_image(),
          { id: "remote-screen-copied" }
        );
      putClip(clip).then(done, () =>
        toast.info(messages.remote_screen_copy_blocked(), {
          id: "remote-screen-copied",
          actions: [
            {
              label: messages.remote_screen_copy_here(),
              onPress: () => void putClip(clip).then(done, () => undefined),
            },
          ],
        })
      );
    });
  }, [control, messages, source.key, target, side]);

  // The picture's size arrives with its first frame and changes as the app's windows do.
  useEffect(() => {
    const element = video.current;
    if (!element) return undefined;
    const measure = () => {
      if (!(element.videoWidth > 0 && element.videoHeight > 0)) return;
      const ratio = element.videoWidth / element.videoHeight;
      calls.current.onShape?.(ratio);
      drawPointer();
      placeKeys();
      // Before this picture paints in the frame of the last: the two change together, or the last is held over it.
      if (calls.current.source.capabilities) flushSync(() => setPictureRatio(ratio));
    };
    measure();
    element.addEventListener("resize", measure);
    // (a stream already playing has its size when it reaches this element)
    element.addEventListener("loadedmetadata", measure);
    // The picture fitted anew in a stage of another size: the pointer with it.
    // (on the next frame: drawing it within the observer's callback is a loop the browser reports)
    let cancelFrame: () => void = () => undefined;
    const view = viewOf(element);
    const fitted = new view.ResizeObserver(() => {
      cancelFrame();
      cancelFrame = uiClock.frame(() => {
        drawPointer();
        placeKeys();
      }, view);
    });
    fitted.observe(element);
    return () => {
      element.removeEventListener("resize", measure);
      element.removeEventListener("loadedmetadata", measure);
      fitted.disconnect();
      cancelFrame();
    };
  }, [device, drawPointer, placeKeys]);

  const point = (event: ReactPointerEvent | WheelEvent) => {
    const element = video.current!;
    return pictureFraction(event, element.getBoundingClientRect(), {
      width: element.videoWidth,
      height: element.videoHeight,
    });
  };
  // Answered once the picture is there. Nothing of it goes to the screen.
  const heardInWatch = () => {
    if (state === "live") watching?.onInput();
  };
  const press =
    (type: "down" | "up") => (event: ReactPointerEvent<HTMLVideoElement>) => {
      if (!control) {
        if (type === "down" && watching) {
          // The keys hear what is typed next, so that it is answered too; a touch does not bring up a keyboard.
          if (event.pointerType !== "touch") {
            keys.current?.focus({ preventScroll: true });
            event.preventDefault();
          }
          heardInWatch();
        }
        return;
      }
      if (type === "down") {
        // The keys follow the pointer into the picture; held back, the press moves no focus of its own.
        pressHere(event);
        keys.current?.focus({ preventScroll: true });
        event.preventDefault();
        event.currentTarget.setPointerCapture(event.pointerId);
      }
      const at = point(event);
      const button = wireButton(event.button);
      const clicks = Math.max(1, event.detail);
      if (type === "down")
        holding.current.set(`button ${button}`, {
          type: "up",
          ...at,
          button,
          clicks,
          mods: [],
        });
      else holding.current.delete(`button ${button}`);
      // Where the last move left the pointer first.
      frame.now();
      peer.current?.send({ type, ...at, button, clicks, mods: modifiers(event) });
    };
  const move = (event: ReactPointerEvent<HTMLVideoElement>) => {
    if (!control) return;
    frame.move({ type: "move", ...point(event), mods: modifiers(event) });
  };
  // A device leaves the chords that a person has bound in the app to the app.
  const macos = detectAppKeybindingPlatform() === "macos";
  const appBindings = useOptionalAppShortcutBindings();
  const appClaims = (event: ReactKeyboardEvent) =>
    device &&
    (event.defaultPrevented ||
      Object.values(appBindings ?? {}).some(
        (binding) =>
          binding?.kind === "chord" && matchesAppKeyStroke(binding.stroke, event)
      ));
  // What the case has a button for is pressed there, not beside it.
  const actions = screenDeviceActions(capabilities, control, deviceState?.pose).filter(
    (action) => !cased || !screenCaseCovers(cased.layout.buttons, action)
  );
  // A button of the case, by its HID usage, as it goes down and comes up: only while the view drives, and let go of as
  // anything held is (a switch to Watch, the keys' focus lost, the stream changed).
  const pressCase = (button: ScreenCaseButton, down: boolean) => {
    if (!button.usage) return;
    const what = `case ${button.name}`;
    const input = (pressed: boolean): ScreenStreamInput => ({
      t: "button",
      page: button.usage!.page,
      usage: button.usage!.usage,
      down: pressed,
    });
    if (down) {
      if (!control || holding.current.has(what)) return;
      holding.current.set(what, input(false));
      peer.current?.send(input(true));
    } else if (holding.current.delete(what)) peer.current?.send(input(false));
  };
  const act = (action: ScreenDeviceAction) => {
    if (action === "rotate") holdForTurn();
    for (const input of screenDevicePress(action)) peer.current?.send(input);
  };
  // A shortcut's press and its release do not reach the device as keys. Its
  // release may never come: macOS holds back what is let go under ⌘.
  const heldShortcuts = useRef(new Set<string>());
  const shortcutDown = (event: ReactKeyboardEvent) => {
    heldShortcuts.current.delete(event.code);
    if (appClaims(event)) return;
    const action = screenDeviceShortcut(event, macos);
    if (!action || !actions.includes(action)) return;
    event.preventDefault();
    event.stopPropagation();
    heldShortcuts.current.add(event.code);
    if (!event.repeat) act(action);
  };
  const shortcutUp = (event: ReactKeyboardEvent) => {
    if (heldShortcuts.current.delete(event.code)) event.stopPropagation();
  };
  const key = (type: "keydown" | "keyup") => (event: ReactKeyboardEvent) => {
    if (appClaims(event)) return;
    if (!control) {
      if (type === "keydown" && typesText(event.nativeEvent)) heardInWatch();
      return;
    }
    // An IME's keys, a paste's and a soft keyboard's make text (below); a key let go goes up if it went down.
    if (
      type === "keydown"
        ? !goesAsKey(event.nativeEvent)
        : !holding.current.has(event.code)
    )
      return;
    event.preventDefault();
    if (type === "keydown")
      holding.current.set(
        event.code,
        device
          ? { t: "key", kind: "up", key: event.key, code: event.code, mods: 0 }
          : { type: "keyup", code: event.code, key: event.key, mods: [] }
      );
    else holding.current.delete(event.code);
    frame.now();
    peer.current?.send(
      device
        ? {
            t: "key",
            kind: type === "keydown" ? "down" : "up",
            key: event.key,
            code: event.code,
            mods: deviceMods(event),
          }
        : { type, code: event.code, key: event.key, mods: modifiers(event) }
    );
  };

  // Text: what an IME composed, a soft keyboard typed or a paste carried, as text. What got into the field is taken out.
  useEffect(() => {
    const field = keys.current;
    if (!field) return undefined;
    const typed = (text: string) => {
      if (!control || !text) return;
      frame.now();
      for (const piece of textPieces(text))
        peer.current?.send(
          device ? { t: "text", text: piece } : { type: "text", text: piece }
        );
    };
    // A soft keyboard's Enter or delete: a key pressed and let go at once.
    const stroke = (name: string) => {
      frame.now();
      for (const kind of ["down", "up"] as const)
        peer.current?.send(
          device
            ? { t: "key", kind, key: name, code: name, mods: 0 }
            : {
                type: kind === "down" ? "keydown" : "keyup",
                code: name,
                key: name,
                mods: [],
              }
        );
    };
    const beforeInput = (event: InputEvent) => {
      if (!control || event.isComposing) return;
      const type = event.inputType;
      if (type === "insertText" && event.data) {
        event.preventDefault();
        typed(event.data);
      } else if (type === "insertLineBreak" || type === "insertParagraph") {
        event.preventDefault();
        stroke("Enter");
      } else if (type === "deleteContentBackward") {
        event.preventDefault();
        stroke("Backspace");
      } else if (type === "deleteContentForward") {
        event.preventDefault();
        stroke("Delete");
      }
    };
    const composed = (event: CompositionEvent) => {
      typed(event.data);
      // Emptied once the IME is done with it.
      uiClock.after(0, () => (field.value = ""));
    };
    const input = (event: Event) => {
      if ((event as InputEvent).isComposing || !field.value) return;
      typed(field.value);
      field.value = "";
    };
    const paste = (event: ClipboardEvent) => {
      event.preventDefault();
      const data = event.clipboardData;
      if (!control || !data) return;
      // Onto the screen's clipboard and pasted there, where it carries what is pasted (still.fail input.ts `paste`).
      if (takesPaste(data, clipTypes.current)) {
        frame.now();
        // Only onto the screen it was pasted on: reading an image takes a while, and the view may change meanwhile.
        const onto = peer.current;
        void pasted(data, clipTypes.current).then((clip) => {
          if (clip && onto && peer.current === onto && controlNow.current)
            onto.setClipboard(clip, true);
        });
        return;
      }
      typed(data.getData("text/plain"));
    };
    field.addEventListener("beforeinput", beforeInput);
    field.addEventListener("compositionend", composed);
    field.addEventListener("input", input);
    field.addEventListener("paste", paste);
    return () => {
      field.removeEventListener("beforeinput", beforeInput);
      field.removeEventListener("compositionend", composed);
      field.removeEventListener("input", input);
      field.removeEventListener("paste", paste);
    };
  }, [control, device, frame]);

  // React registers wheel listeners as passive; scrolling the picture must not scroll the page.
  useEffect(() => {
    const element = video.current;
    if (!element || !control) return undefined;
    // In pixels whatever the wheel counts in, summed over a frame (still.fail input.ts, "wheel").
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      const travel = wheelPixels(event, element.clientHeight);
      frame.wheel(
        device
          ? { t: "wheel", ...point(event), ...travel }
          : { type: "scroll", ...point(event), ...travel, mods: modifiers(event) }
      );
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, [control, device, frame]);

  const picture = (
    <>
      <video
        autoPlay
        muted
        playsInline
        onContextMenu={(event) => control && event.preventDefault()}
        {...(device
          ? {
              ...touchHandlers,
              // (a device takes its shortcuts by the keys, control or not)
              onPointerDown: (event: ReactPointerEvent<HTMLVideoElement>) => {
                touchHandlers.onPointerDown(event);
                if (control) pressHere(event);
                else heardInWatch();
                keys.current?.focus({ preventScroll: true });
                event.preventDefault();
              },
            }
          : {
              onPointerDown: press("down"),
              onPointerEnter: () => {
                hovering.current = true;
                drawPointer();
              },
              onPointerLeave: () => {
                hovering.current = false;
                drawPointer();
              },
              onPointerMove: move,
              onLostPointerCapture: () => letGo(peer.current?.send, true),
              onPointerUp: press("up"),
            })}
        ref={video}
      />
      <textarea
        aria-label={messages.remote_screen_keys()}
        autoCapitalize="off"
        autoComplete="off"
        autoCorrect="off"
        className="comma-remote-screen-keys"
        onBlur={() => letGo(peer.current?.send)}
        onKeyDown={key("keydown")}
        onKeyUp={key("keyup")}
        ref={keys}
        rows={1}
        spellCheck={false}
        // (a device is focused to take its shortcuts, control or not)
        tabIndex={control || device ? 0 : -1}
      />
      <canvas aria-hidden className="comma-remote-screen-still" ref={still} />
      <span
        className="comma-remote-screen-pointer"
        data-testid="remote-screen-pointer"
        hidden
        ref={pointer}
      >
        {/* (in Watch an arrow, whatever is under it on the screen: a hand or a caret says it can be used) */}
        <ScreenPointerShape shape={control ? pointerShape : "default"} />
      </span>
      <ScreenAgentPresence on={agent} picture={video} ref={presence} />
      {heldFrame ? <ScreenHeldFrame frame={heldFrame} /> : null}
    </>
  );
  const wide = (stood.ratio ?? 1) > 1;
  // Under a device taller than wide, in the middle; one wider than tall has it at the end of its buttons' row.
  const mode = choice ? (
    <ScreenControlChoice control={control} {...choice} />
  ) : undefined;
  return (
    <div
      className="comma-remote-screen-stage"
      data-choice={choice ? true : undefined}
      data-control={control}
      data-watching={watching !== undefined && !control}
      inert={heldFrame !== undefined}
      {...(capabilities
        ? {
            "data-device": true,
            "data-input": capabilities.input,
            onKeyDownCapture: shortcutDown,
            onKeyUpCapture: shortcutUp,
          }
        : {})}
    >
      {device ? (
        <ScreenDeviceFrame
          agent={agent}
          animated={animated}
          below={wide ? undefined : mode}
          buttons={
            <ScreenDeviceButtons
              actions={actions}
              macos={macos}
              onAction={act}
              placement={wide ? "bottom" : "left"}
              pose={deviceState?.pose}
              poses={control ? capabilities.poses : undefined}
              trailing={wide ? mode : undefined}
            />
          }
          cased={cased && { ...cased, control, onPress: pressCase }}
          pictureRatio={stood.ratio}
          shape={shape}
          turn={stood.turn}
        >
          {picture}
        </ScreenDeviceFrame>
      ) : (
        picture
      )}
      {heldFrame ? null : state === "failed" ? (
        <div className="comma-remote-screen-failure" role="alert">
          <strong>{messages.remote_screen_failed()}</strong>
          {detail ? <span>{detail}</span> : null}
          <Button
            hierarchy="secondary-gray"
            onPress={() => peer.current?.retry()}
            size="sm"
          >
            {messages.remote_screen_retry()}
          </Button>
        </div>
      ) : state === "live" ? null : (
        <output className="comma-remote-screen-status">
          {messages.remote_screen_connecting()}
        </output>
      )}
      {watching && !heldFrame ? (
        <output
          className="comma-remote-screen-watch-hint"
          data-shown={watching.shown && !control}
          data-testid="remote-screen-watch-hint"
        >
          <span>{watching.hint}</span>
        </output>
      ) : null}
    </div>
  );
}

/** A held frame where the picture is (`heldFrame`): the stage keeps the canvas while it holds it. */
function ScreenHeldFrame({ frame }: { frame: HTMLCanvasElement }) {
  const holder = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    holder.current?.replaceChildren(frame);
  }, [frame]);
  return (
    <div
      className="comma-remote-screen-held"
      data-testid="remote-screen-held"
      ref={holder}
    />
  );
}

/** The sizes a device's picture is asked at, in its long side: a few, so a stage that grows a little opens no new view. */
const DEVICE_SIDES = [480, 720, 1080, 1440, 1920, 2560] as const;

/**
 * The long side a device's picture shows at in a stage of this size, in the screen's pixels, whichever way it is turned
 * (`longest`: its panels' long side over their short), as one of DEVICE_SIDES: a picture the size it shows is drawn as
 * it comes. A larger one is scaled down by the page, which leaves small text soft.
 */
export function deviceSide(width: number, height: number, longest: number): number {
  const room = (side: number) => Math.max(0, side - 2 * DEVICE_GUTTER);
  const [long, short] = [
    Math.max(room(width), room(height)),
    Math.min(room(width), room(height)),
  ];
  const shown = Math.min(long, short * longest) * (globalThis.devicePixelRatio || 1);
  return DEVICE_SIDES.find((side) => side >= shown) ?? DEVICE_SIDES.at(-1)!;
}

// What a device keeps clear round it on the stage (styles.css, the device area's padding).
const DEVICE_GUTTER = 24;

/**
 * The picture's lower left corner within a `<video>` that fits it (`object-fit: contain`), in its parent's pixels:
 * where the keys say their caret is before any press (still.fail screen_stage.mbt: `ox + shown.x, oy + shown.y +
 * shown.h`).
 */
export function pictureCorner(video: HTMLVideoElement): { left: number; top: number } {
  const { offsetLeft, offsetTop, clientWidth, clientHeight, videoWidth, videoHeight } =
    video;
  if (!(videoWidth > 0 && videoHeight > 0 && clientWidth > 0 && clientHeight > 0))
    return { left: offsetLeft, top: offsetTop + clientHeight };
  const scale = Math.min(clientWidth / videoWidth, clientHeight / videoHeight);
  const width = videoWidth * scale;
  const height = videoHeight * scale;
  return {
    left: offsetLeft + (clientWidth - width) / 2,
    top: offsetTop + (clientHeight - height) / 2 + height,
  };
}

/** Where a press on the `<video>` is, in its parent's pixels (the stage may be drawn scaled). */
function pressPlace(
  video: HTMLVideoElement,
  event: { clientX: number; clientY: number }
): { left: number; top: number } {
  const box = video.getBoundingClientRect();
  const sx = box.width > 0 ? video.offsetWidth / box.width : 1;
  const sy = box.height > 0 ? video.offsetHeight / box.height : 1;
  return {
    left: video.offsetLeft + (event.clientX - box.left) * sx,
    top: video.offsetTop + (event.clientY - box.top) * sy,
  };
}

/** Draws the video's current frame on the canvas, if it has one. */
function keepLastFrame(
  video: HTMLVideoElement | null,
  canvas: HTMLCanvasElement | null
) {
  if (!video || !canvas || !(video.videoWidth > 0 && video.videoHeight > 0)) return;
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  canvas.getContext("2d")?.drawImage(video, 0, 0);
  canvas.dataset.kept = "true";
}

/** A CSS colour in any notation as `#rrggbb`, by painting it. */
function hexColor(color: string): string | undefined {
  const context = document.createElement("canvas").getContext("2d");
  if (!context) return undefined;
  context.fillStyle = color;
  context.fillRect(0, 0, 1, 1);
  const [red = 0, green = 0, blue = 0] = context.getImageData(0, 0, 1, 1).data;
  return `#${[red, green, blue].map((part) => part.toString(16).padStart(2, "0")).join("")}`;
}

/**
 * Whether the element fills the screen, and a way in and out. While it does and
 * `lockKeys` holds, Escape reaches the page (a long press still leaves), so
 * the computer being controlled gets it.
 */
export function useFullscreen(
  element: RefObject<HTMLElement | null>,
  lockKeys: boolean
): [full: boolean, toggle: () => void] {
  const [full, setFull] = useState(false);
  // (of the document it is in: the app's window, or a screen's own window)
  useEffect(() => {
    const own = element.current?.ownerDocument ?? document;
    const changed = () =>
      setFull(element.current !== null && own.fullscreenElement === element.current);
    own.addEventListener("fullscreenchange", changed);
    return () => own.removeEventListener("fullscreenchange", changed);
  }, [element]);
  useEffect(() => {
    const keyboard = (
      (element.current?.ownerDocument.defaultView ?? window).navigator as {
        keyboard?: { lock?(keys: string[]): Promise<void>; unlock?(): void };
      }
    ).keyboard;
    if (!full || !lockKeys || !keyboard?.lock) return undefined;
    void keyboard.lock(["Escape"]).catch(() => undefined);
    return () => keyboard.unlock?.();
  }, [element, full, lockKeys]);
  const toggle = useCallback(() => {
    const own = element.current?.ownerDocument ?? document;
    if (own.fullscreenElement) void own.exitFullscreen();
    else void element.current?.requestFullscreen().catch(() => undefined);
  }, [element]);
  return [full, toggle];
}
