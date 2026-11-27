import {
  lazy,
  Suspense,
  useEffect,
  useRef,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type Ref,
  type RefObject,
} from "react";
import type { DuoStageHandle } from "./devices/DuoStage";
import type { DuoPosture, DuoScreen } from "./devices/duoScreens";
import type { ScreenTurn } from "./screenDevice";

// three.js and the model come only with a device that folds: other views load none of it.
const DuoStage = lazy(() => import("./devices/DuoStage"));

type PointerHandlers = {
  onPointerDown(event: ReactPointerEvent<HTMLElement>): void;
  onPointerMove(event: ReactPointerEvent<HTMLElement>): void;
  onPointerUp(event: ReactPointerEvent<HTMLElement>): void;
  onPointerCancel(event: ReactPointerEvent<HTMLElement>): void;
  onLostPointerCapture(event: ReactPointerEvent<HTMLElement>): void;
};

/**
 * A device that folds (an iPhone Duo), drawn as a 3D model in the posture shown, with the simulator's picture on the
 * screen that shows it. The picture's own `<video>` (`children`) stays under the model, unseen: it is what the model's
 * screen shows. A press on that screen reaches the device through `handlers` (the stage asks `handle` where it is).
 */
export function ScreenDuoFrame({
  video,
  screen,
  pictureTurn,
  posture,
  modelTurn,
  handle,
  handlers,
  onWheel,
  onUnavailable,
  buttons,
  children,
}: {
  /** No 3D here: the stage draws the device flat instead. */
  onUnavailable(): void;
  video: RefObject<HTMLVideoElement | null>;
  screen: DuoScreen;
  pictureTurn: ScreenTurn;
  posture: DuoPosture;
  modelTurn: ScreenTurn;
  handle: Ref<DuoStageHandle>;
  handlers?: PointerHandlers | undefined;
  /** A wheel over the model (it is not passive: a scroll of the screen does not scroll the page). */
  onWheel?: ((event: WheelEvent) => void) | undefined;
  buttons: ReactNode;
  children: ReactNode;
}) {
  const input = useRef<HTMLDivElement>(null);
  const wheel = useRef(onWheel);
  wheel.current = onWheel;
  useEffect(() => {
    const element = input.current;
    if (!element) return undefined;
    const listener = (event: WheelEvent) => wheel.current?.(event);
    element.addEventListener("wheel", listener, { passive: false });
    return () => element.removeEventListener("wheel", listener);
  }, []);
  return (
    <div className="comma-remote-screen-device-area">
      <div
        className="comma-remote-screen-duo"
        data-lays="wide"
        data-posture={posture.id}
        data-testid="remote-screen-device"
      >
        <div className="comma-remote-screen-duo-picture">{children}</div>
        <div className="comma-remote-screen-duo-input" ref={input} {...handlers}>
          <Suspense fallback={null}>
            <DuoStage
              handle={handle}
              onUnavailable={onUnavailable}
              modelTurn={modelTurn}
              pictureTurn={pictureTurn}
              posture={posture}
              screen={screen}
              source={video}
            />
          </Suspense>
        </div>
        {buttons}
      </div>
    </div>
  );
}
