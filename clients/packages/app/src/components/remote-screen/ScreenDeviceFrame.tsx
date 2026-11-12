import { useCommaMessages } from "@comma/i18n/react";
import {
  BookIcon,
  CircleDashedIcon,
  HomeIcon,
  LockIcon,
  PhoneDynamicIslandIcon,
  ReloadIcon,
  TabletIcon,
  VolumeDownIcon,
  VolumeOffIcon,
  VolumeUpIcon,
} from "@comma/ui/components/icons";
import type { TooltipPlacement } from "@comma/ui/components/tooltip";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import {
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type ReactNode,
  type RefObject,
} from "react";
import {
  screenCaseRoom,
  type ScreenCase,
  type ScreenCaseButton,
  type ScreenCasePictures,
  type ScreenCaseRect,
} from "./screenCase";
import { ScreenAgentEdge } from "./ScreenAgentPresence";
import { ScreenStreamAction } from "./ScreenStreamChrome";
import {
  SCREEN_DEVICE_TURN_MS,
  screenDeviceShortcutKeys,
  screenDeviceTurnFrames,
  screenCornerShape,
  screenDeviceTurnFrom,
  turnScreenDeviceShape,
  type ScreenDeviceAction,
  type ScreenDevicePose,
  type ScreenDeviceShape,
  type ScreenTurn,
} from "./screenDevice";
import { viewOf } from "./screenWindows";

const percent = (part: number, whole: number) => `${(part / whole) * 100}%`;

/**
 * The layout of a shape as it stands turned: the screen's shape and corners. The
 * body goes round the screen at one thickness (styles.css), whatever its size.
 */
function deviceLayout(shape: ScreenDeviceShape, turn: ScreenTurn) {
  const { screen, corners, shapes } = turnScreenDeviceShape(shape, turn);
  const cornerShape = screenCornerShape(shapes);
  const [topLeft, topRight, bottomRight, bottomLeft] = corners.map(
    (corner) => corner / screen.width
  ) as [number, number, number, number];
  return {
    "--comma-remote-screen-device-ratio": screen.width / screen.height,
    "--comma-remote-screen-device-corner-tl": topLeft,
    "--comma-remote-screen-device-corner-tr": topRight,
    "--comma-remote-screen-device-corner-br": bottomRight,
    "--comma-remote-screen-device-corner-bl": bottomLeft,
    "--comma-remote-screen-device-screen-radius": `${corners
      .map((radius) => percent(radius, screen.width))
      .join(
        " "
      )} / ${corners.map((radius) => percent(radius, screen.height)).join(" ")}`,
    ...(cornerShape
      ? { "--comma-remote-screen-device-corner-shape": cornerShape }
      : {}),
  } as CSSProperties;
}

/** A device's case as the frame draws it: where all is, its pictures, and its buttons pressed while it drives. */
export type ScreenDeviceCased = {
  layout: ScreenCase;
  pictures: ScreenCasePictures;
  /** Its buttons can be pressed: the view drives the device. */
  control: boolean;
  onPress(button: ScreenCaseButton, down: boolean): void;
};

/** A rect of the case's frame as a share of it, for CSS. */
const placed = (r: ScreenCaseRect, frame: ScreenCase["frame"]): CSSProperties => ({
  left: percent(r.x, frame.width),
  top: percent(r.y, frame.height),
  width: percent(r.width, frame.width),
  height: percent(r.height, frame.height),
});

/** The picture where the case's panel is, its corners cut as far in as the case covers them. */
const casedScreen = (layout: ScreenCase): CSSProperties => {
  const { screen, corners } = layout;
  return {
    ...placed(screen, layout.frame),
    borderRadius: `${corners.map((r) => percent(r, screen.width)).join(" ")} / ${corners
      .map((r) => percent(r, screen.height))
      .join(" ")}`,
    ...(layout.shapes ? { cornerShape: screenCornerShape(layout.shapes) } : {}),
  } as CSSProperties;
};

/**
 * The case's own corners, as a `border-radius` of its frame: each of the panel's corners, further out by the case's
 * rim beside it. An agent's glowing edge takes this outline (the case is a picture, with no box of that shape).
 */
const casedOutline = ({ frame, screen, corners }: ScreenCase): string => {
  const rimX = Math.min(screen.x, frame.width - screen.x - screen.width);
  const rimY = Math.min(screen.y, frame.height - screen.y - screen.height);
  return `${corners.map((r) => percent(r + rimX, frame.width)).join(" ")} / ${corners
    .map((r) => percent(r + rimY, frame.height))
    .join(" ")}`;
};

/**
 * The device as it stands: its case as Xcode draws it where it has one (`cased`), else a plain rounded body with its picture on its screen, and what it can do beside it. The picture
 * arrives as it stands: nothing here turns it. Until the source says its shape it is a plain picture, in the room a body
 * would take.
 */
export function ScreenDeviceFrame({
  shape,
  pictureRatio,
  turn,
  animated = true,
  buttons,
  cased,
  agent,
  below,
  children,
}: {
  /** An agent's lease on the device lasts: its glowing edge shows round the body. */
  agent?: boolean | undefined;
  /** What stands under the device, in the middle (Watch or Control, under one taller than wide). */
  below?: ReactNode;
  shape: ScreenDeviceShape | undefined;
  pictureRatio: number | undefined;
  turn: ScreenTurn;
  animated?: boolean | undefined;
  buttons: ReactNode;
  cased?: ScreenDeviceCased | undefined;
  children: ReactNode;
}) {
  // A turn shows as one: on a nearly square device its shape alone hardly says so.
  const device = useRef<HTMLDivElement>(null);
  const stood = useRef(turn);
  useLayoutEffect(() => {
    const was = stood.current;
    stood.current = turn;
    if (was === turn || !animated || isReducedMotionEnabled()) return;
    const element = device.current;
    const area = element?.parentElement;
    if (!element || !area) return;
    const from = screenDeviceTurnFrom(was, turn);
    const [width, height] = [element.offsetWidth, element.offsetHeight];
    // The room a device is fitted in, and what size the fit gave it as it stood.
    const look = getComputedStyle(area);
    const roomWidth =
      area.clientWidth -
      Number.parseFloat(look.paddingLeft) -
      Number.parseFloat(look.paddingRight);
    const roomHeight =
      area.clientHeight -
      Number.parseFloat(look.paddingTop) -
      Number.parseFloat(look.paddingBottom);
    const sideways = Math.abs(from) === 90;
    // The room it keeps for its buttons, and on which side: that follows how it stood.
    const kept = getComputedStyle(element);
    const keptX = Number.parseFloat(kept.marginRight) || 0;
    const keptY = Number.parseFloat(kept.marginBottom) || 0;
    const wasRatio = sideways ? height / width : width / height;
    const wasWidth = Math.min(
      roomWidth - (sideways ? keptY : keptX),
      (roomHeight - (sideways ? keptX : keptY)) * wasRatio
    );
    element.animate?.(
      screenDeviceTurnFrames({
        from,
        width,
        height,
        // Round to the very edge of the stage: its gutters are for what stays still.
        areaWidth: area.clientWidth,
        areaHeight: area.clientHeight,
        startScale: sideways ? wasWidth / height : wasWidth / width,
      }).map(({ rotate, scale, offset }) => ({
        transform: `rotate(${rotate}deg) scale(${scale})`,
        offset,
      })),
      { duration: SCREEN_DEVICE_TURN_MS, easing: "linear" }
    );
    // Its buttons are on the page, not on the body: they do not swing round with it.
    for (const beside of element.querySelectorAll(
      ".comma-remote-screen-device-buttons, .comma-remote-screen-device-below"
    ))
      beside.animate?.([{ opacity: 0 }, { opacity: 0, offset: 0.8 }, { opacity: 1 }], {
        duration: SCREEN_DEVICE_TURN_MS,
      });
  }, [animated, turn]);
  const ratio = pictureRatio ?? 1;
  const drawn = shape || {
    frame: { width: ratio, height: 1 },
    screen: { x: 0, y: 0, width: ratio, height: 1 },
    corners: [0, 0, 0, 0],
  };
  const drawnFrame = turnScreenDeviceShape(drawn, turn).frame;
  const frame = cased?.layout.frame;
  return (
    <div className="comma-remote-screen-device-area">
      <div
        className="comma-remote-screen-device"
        data-body={shape !== undefined && !cased}
        data-case={cased !== undefined}
        data-lays={
          (frame ? frame.width > frame.height : drawnFrame.width > drawnFrame.height)
            ? "wide"
            : "tall"
        }
        data-testid="remote-screen-device"
        data-turn={turn}
        ref={device}
        style={
          cased
            ? ({
                "--comma-remote-screen-device-ratio":
                  cased.layout.frame.width / cased.layout.frame.height,
              } as CSSProperties)
            : deviceLayout(drawn, turn)
        }
      >
        {agent ? (
          <ScreenAgentEdge
            outline={cased ? casedOutline(cased.layout) : undefined}
            shape={cased ? screenCornerShape(cased.layout.shapes) : undefined}
          />
        ) : null}
        <div
          className="comma-remote-screen-device-screen"
          style={cased ? casedScreen(cased.layout) : undefined}
        >
          {children}
        </div>
        {cased ? <ScreenDeviceCase cased={cased} device={device} /> : null}
        {buttons}
        {below ? <div className="comma-remote-screen-device-below">{below}</div> : null}
      </div>
    </div>
  );
}

/**
 * The case over the picture (its panel's shape cut out of it, so the picture shows through), its buttons behind it, a
 * home button on it, and, while the view drives, where each button is pressed: held as long as it is held here
 * (still.fail's screen_case.mbt `device_cased`).
 */
function ScreenDeviceCase({
  cased,
  device,
}: {
  cased: ScreenDeviceCased;
  device: RefObject<HTMLDivElement | null>;
}) {
  const messages = useCommaMessages();
  const { layout, pictures, control, onPress } = cased;
  // What is held here: told at once (a release that comes twice goes once), drawn as React draws.
  const holding = useRef(new Set<string>());
  const [hint, setHint] = useState<string>();
  const [held, setHeld] = useState<ReadonlySet<string>>(new Set());
  // The page's pixels a point of the case: what a press's room is measured in.
  const [scale, setScale] = useState(1);
  useLayoutEffect(() => {
    const element = device.current;
    if (!element) return undefined;
    const measure = () => {
      if (element.offsetWidth > 0) setScale(element.offsetWidth / layout.frame.width);
    };
    measure();
    const watch = new (viewOf(element).ResizeObserver)(measure);
    watch.observe(element);
    return () => watch.disconnect();
  }, [device, layout.frame.width]);
  // Let go when it stops driving, or the case changes under a held button.
  // (the stage lets go of what it held on the device as it stops driving)
  useLayoutEffect(() => {
    if (control) return;
    setHint(undefined);
    holding.current.clear();
    setHeld(new Set());
  }, [control]);
  const press = (button: ScreenCaseButton, down: boolean) => {
    if (holding.current.has(button.name) === down) return;
    if (down) holding.current.add(button.name);
    else holding.current.delete(button.name);
    setHeld(new Set(holding.current));
    onPress(button, down);
  };
  // What is held goes up when this page stops hearing its release: the window loses the focus or is hidden.
  const letGoAll = useRef(() => undefined as void);
  letGoAll.current = () => {
    for (const button of layout.buttons)
      if (holding.current.has(button.name)) press(button, false);
  };
  // (the window it is in: the app's, or a screen's own)
  useLayoutEffect(() => {
    const own = device.current?.ownerDocument ?? document;
    const view = own.defaultView ?? window;
    const leave = () => letGoAll.current();
    const hidden = () => {
      if (own.visibilityState === "hidden") leave();
    };
    view.addEventListener("blur", leave);
    own.addEventListener("visibilitychange", hidden);
    return () => {
      view.removeEventListener("blur", leave);
      own.removeEventListener("visibilitychange", hidden);
    };
  }, [device]);
  const words: Record<string, string> = {
    power: messages.remote_screen_side_button(),
    home: messages.remote_screen_home(),
    "volume-up": messages.remote_screen_volume_up(),
    "volume-down": messages.remote_screen_volume_down(),
    action: messages.remote_screen_action_button(),
    mute: messages.remote_screen_ring_switch(),
  };
  const icons: Record<string, ReactNode> = {
    power: <LockIcon className="size-4" />,
    home: <HomeIcon className="size-4" />,
    "volume-up": <VolumeUpIcon className="size-4" />,
    "volume-down": <VolumeDownIcon className="size-4" />,
    mute: <VolumeOffIcon className="size-4" />,
    action: <CircleDashedIcon className="size-4" />,
  };
  const sideOf = (button: ScreenCaseButton) => {
    if (button.front) return "front";
    // A panel's bounds can extend past its frame. The inward way still names the edge after a turn.
    if (button.dy !== 0) return button.dy > 0 ? "top" : "bottom";
    if (button.dx !== 0) return button.dx > 0 ? "left" : "right";
    return button.at.y < layout.screen.y
      ? "top"
      : button.at.y >= layout.screen.y + layout.screen.height
        ? "bottom"
        : button.at.x < layout.screen.x
          ? "left"
          : "right";
  };
  const look = (button: ScreenCaseButton) => {
    const picture = pictures.buttons[button.name];
    if (!picture) return null;
    const down = control && held.has(button.name);
    const revealed = control && hint === sideOf(button);
    // Xcode's normal position is inward from its rollover position. A press goes another half-way inward.
    const inward = (revealed ? 0 : 1) + (down ? 0.5 : 0);
    return (
      <img
        alt=""
        aria-hidden
        className="comma-remote-screen-case-button"
        data-button={button.name}
        data-front={button.front}
        data-down={down}
        data-revealed={revealed}
        draggable={false}
        key={`${layout.key}/${layout.turn}/${button.name}`}
        src={down && picture.down ? picture.down : picture.up}
        style={{
          ...placed(button.at, layout.frame),
          translate: `${percent(button.dx * inward, button.at.width)} ${percent(button.dy * inward, button.at.height)}`,
        }}
      />
    );
  };
  const keyed =
    (button: ScreenCaseButton, down: boolean) => (event: ReactKeyboardEvent) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      event.stopPropagation();
      if (!event.repeat) press(button, down);
    };
  return (
    <>
      {layout.buttons.filter((b) => !b.front).map(look)}
      <img
        alt=""
        aria-hidden
        className="comma-remote-screen-case"
        draggable={false}
        src={pictures.body}
      />
      {layout.buttons.filter((b) => b.front).map(look)}
      {control
        ? layout.buttons.flatMap((button) =>
            button.usage ? (
              <button
                key={button.name}
                aria-label={words[button.name] ?? button.name}
                aria-pressed={held.has(button.name)}
                className="comma-remote-screen-case-press"
                data-button={button.name}
                data-side={sideOf(button)}
                data-revealed={hint === sideOf(button)}
                // (a key's release goes where the focus went: the button lets go as it loses it)
                onBlur={() => {
                  press(button, false);
                  setHint(undefined);
                }}
                onFocus={() => setHint(sideOf(button))}
                onPointerEnter={(event) => {
                  if (event.pointerType !== "touch") setHint(sideOf(button));
                }}
                onPointerLeave={() => setHint(undefined)}
                onKeyDown={keyed(button, true)}
                onKeyUp={keyed(button, false)}
                onLostPointerCapture={() => press(button, false)}
                onPointerCancel={() => press(button, false)}
                // (the keys keep their focus: a blur there lets go of all that is held)
                onMouseDown={(event) => event.preventDefault()}
                onPointerDown={(event) => {
                  if (event.button !== 0) return;
                  event.preventDefault();
                  event.currentTarget.setPointerCapture?.(event.pointerId);
                  press(button, true);
                }}
                onPointerUp={() => press(button, false)}
                style={
                  {
                    ...placed(
                      screenCaseRoom(button.at, layout.screen, button.front, scale),
                      layout.frame
                    ),
                    "--comma-case-inward-x": `${button.dx * scale}px`,
                    "--comma-case-inward-y": `${button.dy * scale}px`,
                  } as CSSProperties
                }
                type="button"
              >
                <span aria-hidden className="comma-remote-screen-case-press-icon">
                  {icons[button.name]}
                </span>
              </button>
            ) : (
              []
            )
          )
        : null}
    </>
  );
}

/** What belongs together on a device: what it does, how loud, how it stands. */
const BUTTON_GROUPS: readonly (readonly ScreenDeviceAction[])[] = [
  ["home", "lock"],
  ["volume_up", "volume_down"],
  ["rotate"],
];

/** What takes a foldable to each way it can stand. */
const POSE_ACTIONS = {
  closed: "fold",
  book: "half_fold",
  open: "unfold",
} as const satisfies Record<ScreenDevicePose, ScreenDeviceAction>;

/** What a device can do, beside its body: those of `actions`, each with its shortcut in its tooltip. */
export function ScreenDeviceButtons({
  actions,
  macos,
  onAction,
  placement = "left",
  poses,
  pose = "open",
  trailing,
}: {
  /** What stands last among them (Watch or Control, in the row under a device wider than tall). */
  trailing?: ReactNode;
  /** The ways a foldable can stand, while they can be chosen, and how it stands. */
  poses?: readonly ScreenDevicePose[] | undefined;
  pose?: ScreenDevicePose | undefined;
  actions: readonly ScreenDeviceAction[];
  macos: boolean;
  onAction(action: ScreenDeviceAction): void;
  placement?: TooltipPlacement | undefined;
}) {
  const messages = useCommaMessages();
  if (actions.length === 0 && !poses?.length && !trailing) return null;
  const faces: Record<ScreenDeviceAction, { icon: ReactNode; label: string }> = {
    home: { icon: <HomeIcon aria-hidden />, label: messages.remote_screen_home() },
    lock: { icon: <LockIcon aria-hidden />, label: messages.remote_screen_lock() },
    volume_up: {
      icon: <VolumeUpIcon aria-hidden />,
      label: messages.remote_screen_volume_up(),
    },
    volume_down: {
      icon: <VolumeDownIcon aria-hidden />,
      label: messages.remote_screen_volume_down(),
    },
    rotate: {
      icon: <ReloadIcon aria-hidden />,
      label: messages.remote_screen_rotate(),
    },
    fold: {
      icon: <PhoneDynamicIslandIcon aria-hidden />,
      label: messages.remote_screen_fold(),
    },
    half_fold: {
      icon: <BookIcon aria-hidden />,
      label: messages.remote_screen_half_fold(),
    },
    unfold: {
      icon: <TabletIcon aria-hidden className="rotate-90" />,
      label: messages.remote_screen_unfold(),
    },
  };
  const group = (actionsOf: readonly ScreenDeviceAction[]) => {
    const shown = actionsOf.filter((action) => actions.includes(action));
    return shown.length === 0 ? null : (
      <div className="comma-remote-screen-device-group" key={actionsOf[0]}>
        {shown.map((action) => (
          <ScreenStreamAction
            key={action}
            icon={faces[action].icon}
            label={faces[action].label}
            onClick={() => onAction(action)}
            placement={placement}
            shortcut={screenDeviceShortcutKeys(action, macos)}
          />
        ))}
      </div>
    );
  };
  return (
    <div className="comma-remote-screen-device-buttons">
      {BUTTON_GROUPS.map(group)}
      {poses?.length ? (
        <div className="comma-remote-screen-device-group">
          {poses.map((one) => (
            <ScreenStreamAction
              key={one}
              icon={faces[POSE_ACTIONS[one]].icon}
              label={faces[POSE_ACTIONS[one]].label}
              onClick={() => {
                if (one !== pose) onAction(POSE_ACTIONS[one]);
              }}
              placement={placement}
              pressed={one === pose}
            />
          ))}
        </div>
      ) : null}
      {trailing}
    </div>
  );
}
