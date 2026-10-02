/* oxlint-disable jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/no-noninteractive-tabindex, jsx-a11y/prefer-tag-over-role -- the crop frame is a focusable pan surface; pointer drag, wheel zoom, and arrow/+/- keys have no native element. */
import { Dialog, Slider } from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import {
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent as ReactWheelEvent,
} from "react";
import {
  avatarCropAt,
  encodeAvatar,
  initialAvatarCrop,
  type AvatarSource,
} from "./avatarImage";

const frameSize = 280;
const maxZoom = 4;
/** Never zoom past 64 source pixels across the frame. */
const minCropSide = 64;
const keyboardStep = 10;

interface LoadedImage extends AvatarSource {
  element: HTMLImageElement;
  url: string;
}

export interface AvatarCropDialogProps {
  file: File;
  onCancel: () => void;
  /** The dialog stays pending until the returned promise settles. */
  onConfirm: (file: File) => Promise<void>;
}

export function AvatarCropDialog({ file, onCancel, onConfirm }: AvatarCropDialogProps) {
  const m = useCommaMessages();
  const [image, setImage] = useState<LoadedImage>();
  const [zoom, setZoom] = useState(1);
  const [center, setCenter] = useState({ x: 0, y: 0 });
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  const drag = useRef<{ pointerId: number; x: number; y: number }>(undefined);
  // Escape still dismisses while encoding; a late result must not upload.
  const cancelled = useRef(false);
  const cancel = () => {
    cancelled.current = true;
    onCancel();
  };

  useEffect(() => {
    const url = URL.createObjectURL(file);
    const element = new Image();
    let active = true;
    element.addEventListener("load", () => {
      if (!active) return;
      const source = { width: element.naturalWidth, height: element.naturalHeight };
      const crop = initialAvatarCrop(source);
      setImage({ ...source, element, url });
      setCenter({ x: crop.x + crop.size / 2, y: crop.y + crop.size / 2 });
    });
    element.addEventListener("error", () => {
      if (active) setFailed(true);
    });
    element.src = url;
    return () => {
      active = false;
      URL.revokeObjectURL(url);
    };
  }, [file]);

  const zoomLimit = image
    ? Math.max(1, Math.min(maxZoom, Math.min(image.width, image.height) / minCropSide))
    : 1;
  const crop = image ? avatarCropAt(image, zoom, center) : undefined;
  const scale = crop ? frameSize / crop.size : 1;

  const moveBy = (dx: number, dy: number) => {
    if (!crop) return;
    setCenter({ x: crop.x + crop.size / 2 + dx, y: crop.y + crop.size / 2 + dy });
  };
  const zoomTo = (next: number) => {
    if (crop) setCenter({ x: crop.x + crop.size / 2, y: crop.y + crop.size / 2 });
    setZoom(Math.min(Math.max(next, 1), zoomLimit));
  };

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!image || pending) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const last = drag.current;
    if (!last || last.pointerId !== event.pointerId) return;
    drag.current = { ...last, x: event.clientX, y: event.clientY };
    moveBy((last.x - event.clientX) / scale, (last.y - event.clientY) / scale);
  };
  const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (drag.current?.pointerId === event.pointerId) drag.current = undefined;
  };
  const onWheel = (event: ReactWheelEvent<HTMLDivElement>) => {
    if (!image || pending) return;
    zoomTo(zoom * Math.exp(-event.deltaY * 0.002));
  };
  const onKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const step = keyboardStep / scale;
    const moves: Record<string, [number, number]> = {
      ArrowLeft: [-step, 0],
      ArrowRight: [step, 0],
      ArrowUp: [0, -step],
      ArrowDown: [0, step],
    };
    const move = moves[event.key];
    if (move) moveBy(...move);
    else if (event.key === "+" || event.key === "=") zoomTo(zoom * 1.1);
    else if (event.key === "-") zoomTo(zoom / 1.1);
    else return;
    event.preventDefault();
  };

  const save = async () => {
    if (!image || !crop || pending) return;
    setPending(true);
    setFailed(false);
    try {
      const encoded = await encodeAvatar(file, image.element, image, crop);
      if (!cancelled.current) await onConfirm(encoded);
    } catch {
      if (cancelled.current) return;
      setFailed(true);
      setPending(false);
    }
  };

  return (
    <Dialog
      actions={[
        {
          label: m.settings_profile_cancel(),
          hierarchy: "secondary-gray",
          disabled: pending,
          onPress: cancel,
        },
        {
          label: m.settings_profile_save(),
          hierarchy: "primary",
          // Disabling the focused button would drop focus to <body>, and
          // the dialog could not restore it to Settings on close.
          disabled: !crop,
          onPress: () => void save(),
        },
      ]}
      description={m.settings_profile_crop_avatar_description()}
      isDismissable={!pending}
      isOpen
      onOpenChange={(open) => {
        if (!open) cancel();
      }}
      title={m.settings_profile_crop_avatar()}
    >
      <div className="flex flex-col items-center gap-lg">
        <div
          aria-label={m.settings_profile_crop_avatar_area()}
          className="relative shrink-0 cursor-grab touch-none select-none overflow-hidden rounded-md bg-secondary outline-none focus-visible:shadow-focus-gray-shadow-xs active:cursor-grabbing"
          data-testid="avatar-crop-area"
          onKeyDown={onKeyDown}
          onPointerCancel={onPointerUp}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onWheel={onWheel}
          role="group"
          style={{ height: frameSize, width: frameSize }}
          tabIndex={0}
        >
          {image && crop ? (
            <img
              alt=""
              className="pointer-events-none absolute left-0 top-0"
              draggable={false}
              src={image.url}
              style={{
                height: image.height * scale,
                // The theme maps `max-w-none` to a zero spacing token.
                maxWidth: "none",
                transform: `translate(${-crop.x * scale}px, ${-crop.y * scale}px)`,
                width: image.width * scale,
              }}
            />
          ) : null}
          <div
            aria-hidden
            className="pointer-events-none absolute inset-0"
            style={{
              background:
                "radial-gradient(circle closest-side, transparent calc(100% - 1.5px), rgb(255 255 255 / 0.8) calc(100% - 0.5px), rgb(0 0 0 / 0.55) 100%)",
            }}
          />
        </div>
        <Slider
          className="w-[280px]"
          disabled={!image || pending || zoomLimit <= 1}
          formatValue={(value) => `${value}%`}
          max={Math.round(zoomLimit * 100)}
          min={100}
          onValueChange={(value) => zoomTo(value / 100)}
          value={Math.round(zoom * 100)}
        />
        {failed ? (
          <p className="w-full text-xs text-error-primary" role="alert">
            {m.settings_profile_avatar_unreadable()}
          </p>
        ) : null}
      </div>
    </Dialog>
  );
}
