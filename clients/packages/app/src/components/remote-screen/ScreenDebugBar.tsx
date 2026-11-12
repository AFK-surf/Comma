import {
  CoreError,
  useCall,
  type ListedScreen,
  type ScreenDebugAction,
} from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { uiClock } from "@comma/ui/clock";
import {
  ArrowsRepeatIcon,
  CameraIcon,
  DownloadIcon,
  MoonIcon,
  RecordIcon,
  StopIcon,
  SunIcon,
} from "@comma/ui/components/icons";
import { toast, type ToastAction } from "@comma/ui/components/toast";
import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  downloadFile,
  saveThroughBrowser,
  savedDownloadActions,
} from "../../runtime-files/fileDownloads";
import { ScreenStreamAction } from "./ScreenStreamChrome";

/** An iPhone Duo's picture narrower than this (short side by long) is its cover's, not its inner panel's. */
const COVER_SHAPE = 0.695;
const TOAST_ID = "comma-remote-screen-debug";
/** Larger files are refused here, before they are read. */
const MAX_APP_BYTES = 1024 ** 3;

/** `2026-11-09 11-43-09`, for a file's name. */
const stamp = (at: number) =>
  new Date(at).toISOString().slice(0, 19).replace("T", " ").replaceAll(":", "-");

/**
 * What debugs an app on the device, under its picture: the running app started again, a screenshot, a recording, an app
 * put on it, light or dark. A row of icons (still.fail's on a narrow page, apps/mbui sfpages/screen_debug.mbt) that wraps
 * in a narrow panel. Shown only in Control and only what the station lists; the station refuses the rest anyway.
 */
export function ScreenDebugBar({
  workspace,
  device,
  screen,
  live,
  inert,
  picture,
  onAskComma,
  onShutter,
  onScreenshot,
}: {
  workspace: string;
  device: string;
  screen: ListedScreen;
  /** The view shows now: the station takes these only from a view that is open in Control. */
  live: boolean;
  inert?: boolean | undefined;
  /** The picture element, to tell which panel of a foldable shows. */
  picture(): HTMLVideoElement | null;
  /** Puts a saved screenshot on the way to the chat; absent where there is no chat. */
  onAskComma?: ((png: Blob) => Promise<void>) | undefined;
  /** Take screenshot was pressed: the picture has not come back yet. */
  onShutter?: (() => void) | undefined;
  /** A screenshot was taken: its PNG and its file's name. */
  onScreenshot?: ((png: Blob, name: string) => void) | undefined;
}) {
  const call = useCall();
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [busy, setBusy] = useState<ReadonlySet<string>>(new Set());
  const [recording, setRecording] = useState(false);
  const [appearance, setAppearance] = useState<"light" | "dark" | undefined>();
  const file = useRef<HTMLInputElement>(null);
  const acted = useRef(false);
  const { id, instance } = screen;
  const target = { workspace, device, screen: id, instance: instance ?? "" };
  const debug = screen.capabilities.debug;
  const can = (action: ScreenDebugAction) => debug?.actions.includes(action) === true;

  // How it stands as the bar comes: what a recording started earlier and the device's light or dark.
  const screenKey = `${workspace}\n${device}\n${id}\n${instance ?? ""}`;
  useEffect(() => {
    if (!live) return undefined;
    let current = true;
    call("devices.screenDebug", {
      workspace,
      device,
      screen: id,
      instance: instance ?? "",
      action: "state",
    })
      .then((state) => {
        if (!current) return;
        // (what the person has pressed since it was asked says more)
        if (!acted.current) setRecording(state.recording === true);
        setAppearance((was) => was ?? state.appearance);
      })
      .catch(() => undefined);
    return () => {
      current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `screenKey` names them.
  }, [call, live, screenKey]);

  const failed = (error: unknown) =>
    toast.error(messages.remote_screen_debug_failed(), {
      ...(error instanceof Error ? { description: error.message } : {}),
      id: TOAST_ID,
      testId: TOAST_ID,
    });

  /** One thing at a time of each kind; a failure says the station's words. */
  const doing = async (what: string, run: () => Promise<void>) => {
    if (busy.has(what)) return;
    acted.current = true;
    setBusy((was) => new Set(was).add(what));
    try {
      await run();
    } catch (error) {
      failed(error);
    } finally {
      setBusy((was) => {
        const left = new Set(was);
        left.delete(what);
        return left;
      });
    }
  };

  const restart = () =>
    doing("restart", async () => {
      const { name } = await call("devices.screenDebug", {
        ...target,
        action: "restart",
      });
      toast.success(messages.remote_screen_debug_restarted({ name: name ?? "" }), {
        id: TOAST_ID,
        testId: TOAST_ID,
      });
    });

  const screenshot = () =>
    doing("screenshot", async () => {
      const name = `${screen.name ?? "Screenshot"} ${stamp(uiClock.now())}.png`;
      onShutter?.();
      const { png, saved } = await call("devices.saveScreenPicture", {
        ...target,
        name,
      });
      const blob = new Blob([png as Uint8Array<ArrayBuffer>], { type: "image/png" });
      onScreenshot?.(blob, name);
      if (!saved) saveThroughBrowser(blob, name);
      const ask: ToastAction[] = onAskComma
        ? [
            {
              hierarchy: "secondary-gray",
              label: messages.remote_screen_ask_comma(),
              onPress: () => void onAskComma(blob).catch(failed),
            },
          ]
        : [];
      toast.success(messages.remote_screen_debug_screenshot_saved(), {
        actions: [
          ...ask,
          ...(saved
            ? savedDownloadActions(getNativeBridge(), locale, saved).slice(0, 1)
            : []),
        ],
        description: saved?.fileName ?? name,
        id: TOAST_ID,
        testId: TOAST_ID,
      });
    });

  const record = () =>
    doing("record", async () => {
      if (!recording) {
        const video = picture();
        const short = video ? Math.min(video.videoWidth, video.videoHeight) : 0;
        const long = video ? Math.max(video.videoWidth, video.videoHeight) : 0;
        const panel =
          screen.capabilities.poses?.length && long > 0
            ? short / long < COVER_SHAPE
              ? ("cover" as const)
              : ("inner" as const)
            : undefined;
        await call("devices.screenDebug", {
          ...target,
          action: "record",
          ...(panel ? { panel } : {}),
        });
        setRecording(true);
        return;
      }
      const fileName = `${screen.name ?? "Recording"} ${stamp(uiClock.now())}.mp4`;
      setRecording(false);
      await downloadFile(
        {
          fileName,
          resolve: () =>
            Promise.reject(
              new CoreError({ code: "unsupported", message: "No Downloads folder." })
            ),
          save: () =>
            call("devices.saveScreenRecording", { ...target, name: fileName }),
        },
        { locale }
      );
    });

  const install = (chosen: File) =>
    doing("install", async () => {
      if (chosen.size > MAX_APP_BYTES)
        throw new Error(messages.remote_screen_debug_install_too_large());
      const bytes = new Uint8Array(await chosen.arrayBuffer());
      const { app } = await call("devices.installScreenApp", {
        ...target,
        name: chosen.name,
        bytes,
      });
      toast.success(messages.remote_screen_debug_installed(), {
        ...(app
          ? { description: messages.remote_screen_debug_installed_app({ app }) }
          : {}),
        id: TOAST_ID,
        testId: TOAST_ID,
      });
    });

  const switchAppearance = () =>
    doing("appearance", async () => {
      const value = appearance === "dark" ? "light" : "dark";
      const said = await call("devices.screenDebug", {
        ...target,
        action: "appearance",
        value,
      });
      setAppearance(said.appearance ?? value);
    });

  if (!debug) return null;
  const action = (
    key: ScreenDebugAction,
    icon: ReactNode,
    label: string,
    onClick: () => unknown,
    extra: { pressed?: boolean; recording?: boolean } = {}
  ) =>
    can(key) ? (
      <span
        className="contents"
        data-recording={extra.recording === true ? "true" : undefined}
        key={key}
      >
        <ScreenStreamAction
          disabled={!live || busy.has(key)}
          icon={icon}
          label={label}
          onClick={() => void onClick()}
          pressed={extra.pressed}
        />
      </span>
    ) : null;
  return (
    <section
      aria-label={messages.remote_screen_debug()}
      className="comma-remote-screen-debug"
      data-testid="remote-screen-debug"
      inert={inert}
    >
      {action(
        "restart",
        <ArrowsRepeatIcon aria-hidden />,
        messages.remote_screen_debug_restart(),
        restart
      )}
      {action(
        "screenshot",
        <CameraIcon aria-hidden />,
        messages.remote_screen_debug_screenshot(),
        screenshot
      )}
      {action(
        "record",
        recording ? <StopIcon aria-hidden /> : <RecordIcon aria-hidden />,
        recording
          ? messages.remote_screen_debug_record_stop()
          : messages.remote_screen_debug_record_start(),
        record,
        { pressed: recording, recording }
      )}
      {action(
        "install",
        <DownloadIcon aria-hidden />,
        messages.remote_screen_debug_install({ types: debug.install.join(", ") }),
        () => file.current?.click()
      )}
      {action(
        "appearance",
        appearance === "dark" ? <SunIcon aria-hidden /> : <MoonIcon aria-hidden />,
        appearance === "dark"
          ? messages.remote_screen_debug_light()
          : messages.remote_screen_debug_dark(),
        switchAppearance
      )}
      {can("install") ? (
        <input
          accept={debug.install.join(",")}
          data-testid="remote-screen-debug-file"
          hidden
          onChange={(event) => {
            const chosen = event.target.files?.[0];
            event.target.value = "";
            if (chosen) void install(chosen);
          }}
          ref={file}
          type="file"
        />
      ) : null}
    </section>
  );
}
