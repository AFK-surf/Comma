import { useCall, useTopic } from "@comma/core-client";
import {
  getNativeBridge,
  type SystemLocationAuthorization,
} from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";
import { location as devicePosition } from "../apps/miniAppDevices";
import { useCommaAppPreferences } from "../commaAppPreferences";

/** The browser's first reading, which also asks the person, may take this long. */
const READ_TIMEOUT_MS = 15_000;

type Report = (position: GeolocationPosition) => void;

function positionOf(position: GeolocationPosition) {
  return {
    latitude: position.coords.latitude,
    longitude: position.coords.longitude,
    accuracy: position.coords.accuracy,
    readAt: Math.round(position.timestamp),
  };
}

/**
 * The desktop asks macOS before a position read: without Comma's grant the read neither prompts nor fails, it only
 * times out. macOS prompts while undecided; when Comma is already off Main opens System Settings on it and this is
 * `denied`. Elsewhere `unknown`, and the read itself asks.
 */
export function authorizeSystemLocation(): Promise<SystemLocationAuthorization> {
  const bridge = getNativeBridge();
  if (bridge.platform !== "electron") return Promise.resolve("unknown");
  return bridge.appPreferences
    .requestLocationAuthorization()
    .catch(() => "unknown" as const);
}

/**
 * Settings › Share location on the desktop and the web: the core's `locationSharing` switch. Turning it on asks the
 * browser (or macOS, through Electron) for the location first; when the person refuses it stays off and `denied` says
 * why.
 */
export function useLocationSharing(read: boolean) {
  const call = useCall();
  const { value } = useTopic(read ? { topic: "locationSharing" } : null);
  const [denied, setDenied] = useState(false);
  const [pending, setPending] = useState(false);
  const available = typeof navigator !== "undefined" && "geolocation" in navigator;

  const set = useCallback(
    async (on: boolean) => {
      setDenied(false);
      if (on) {
        setPending(true);
        if ((await authorizeSystemLocation()) === "denied") {
          setPending(false);
          return setDenied(true);
        }
        const allowed = await new Promise<GeolocationPosition | "denied" | null>(
          (resolve) =>
            navigator.geolocation.getCurrentPosition(
              resolve,
              (error) =>
                resolve(error.code === error.PERMISSION_DENIED ? "denied" : null),
              { timeout: READ_TIMEOUT_MS, maximumAge: 60_000 }
            )
        );
        setPending(false);
        if (allowed === "denied") return setDenied(true);
        await call("locationSharing.set", { enabled: true }).catch(() => undefined);
        if (allowed)
          await call("locationSharing.report", { position: positionOf(allowed) }).catch(
            () => undefined
          );
        return;
      }
      await call("locationSharing.set", { enabled: false }).catch(() => undefined);
    },
    [call]
  );

  // On, but location was taken away in the browser or the system since: say so, as nothing is sent until it is back.
  const [blocked, setBlocked] = useState(false);
  const enabled = value?.enabled;
  useEffect(() => {
    if (!read || enabled !== true || !navigator.permissions) return setBlocked(false);
    let status: PermissionStatus | null = null;
    let live = true;
    const show = () => setBlocked(status?.state === "denied");
    void navigator.permissions
      .query({ name: "geolocation" })
      .then((s) => {
        if (!live) return;
        status = s;
        s.addEventListener("change", show);
        show();
      })
      .catch(() => undefined);
    return () => {
      live = false;
      status?.removeEventListener("change", show);
    };
  }, [read, enabled]);

  // Turns sharing on without a reading: for when the system refuses Comma
  // now and the person has asked to allow it there.
  const keepOn = useCallback(
    () => call("locationSharing.set", { enabled: true }).catch(() => undefined),
    [call]
  );

  return {
    available,
    enabled,
    denied: denied || blocked,
    pending,
    set,
    keepOn,
  };
}

/**
 * While the person shares their location, this window follows the device's position and gives each reading to the
 * core, which sends the newest with each message. A computer seldom moves, so the browser reports only changes.
 * Turning sharing off makes the core forget the position (`locationSharing.set`). It also answers the Agent's
 * requests for the position, as an open phone does (`useAnswerLocationRequests`).
 */
export function useFollowLocationSharing() {
  const call = useCall();
  const { value } = useTopic({ topic: "locationSharing" });
  const enabled = value?.enabled === true;
  // macOS taking Comma's location away does not reach a running watch as an
  // error, so Main's readback decides: refused, nothing is followed and no
  // later message carries the last position.
  const systemStatus = useCommaAppPreferences().preferences?.systemLocationStatus;
  const systemDenied = systemStatus === "denied";
  useEffect(() => {
    if (!enabled) return;
    if (systemDenied) {
      void call("locationSharing.report", { position: null }).catch(() => undefined);
      return;
    }
    if (typeof navigator === "undefined" || !("geolocation" in navigator)) return;
    const report: Report = (position) =>
      void call("locationSharing.report", { position: positionOf(position) }).catch(
        () => undefined
      );
    // Location taken away in the browser or the system: no later message carries the last position.
    const lost = (error: GeolocationPositionError) => {
      if (error.code === error.PERMISSION_DENIED)
        void call("locationSharing.report", { position: null }).catch(() => undefined);
    };
    const watch = navigator.geolocation.watchPosition(report, lost, {
      maximumAge: 60_000,
    });
    return () => navigator.geolocation.clearWatch(watch);
  }, [call, enabled, systemDenied]);
  // macOS not yet asked: a read would only wait out its timeout, so the cards ask.
  useAnswerLocationRequests(
    enabled && !systemDenied && systemStatus !== "notDetermined"
  );
}

/** Whether the browser lets this window read the position now, so a read asks the person nothing. */
async function locationGranted(): Promise<boolean> {
  if (typeof navigator === "undefined" || !navigator.permissions) return false;
  return navigator.permissions
    .query({ name: "geolocation" })
    .then((status) => status.state === "granted")
    .catch(() => false);
}

/**
 * Answers the location requests the person's own messages led to (the core's `agentLocationRequests`, in any
 * conversation) while they share their location, as an open phone does: the window reads the position and sends it,
 * and the card does not ask. Only while the browser already allows it, so nothing prompts; otherwise, or when the
 * position cannot be read, the request stays on its card. Each request is tried once while it waits.
 */
function useAnswerLocationRequests(sharing: boolean) {
  const call = useCall();
  const { value } = useTopic(sharing ? { topic: "agentLocationRequests" } : null);
  const requests = sharing ? value?.requests : undefined;
  const tried = useRef(new Set<string>());
  // Read after the position arrives: sharing turned off or this window gone meanwhile sends nothing.
  const current = useRef(sharing);
  useEffect(() => {
    current.current = sharing;
    return () => {
      current.current = false;
    };
  }, [sharing]);
  useEffect(() => {
    const waiting = new Set(requests?.map((request) => request.id));
    for (const id of tried.current) if (!waiting.has(id)) tried.current.delete(id);
    const fresh = (requests ?? []).filter((request) => !tried.current.has(request.id));
    if (fresh.length === 0) return;
    for (const request of fresh) tried.current.add(request.id);
    void (async () => {
      const position = (await locationGranted()) ? await devicePosition() : null;
      if (!position?.ok) {
        // Not allowed or not known now: the cards ask, and a later change of the requests tries these again.
        for (const request of fresh) tried.current.delete(request.id);
        return;
      }
      if (!current.current) return;
      const { latitude, longitude, accuracy, at } = position.value as {
        latitude: number;
        longitude: number;
        accuracy: number;
        at: string;
      };
      // A computer seldom moves, so the follow reports seldom: the next message carries this newer reading.
      void call("locationSharing.report", {
        position: { latitude, longitude, accuracy, readAt: Date.parse(at) },
      }).catch(() => undefined);
      for (const request of fresh)
        // Answered elsewhere or refused: the card shows how it stands.
        void call("agentRequests.shareLocation", {
          group: request.group,
          conversation: request.conversation,
          request: request.id,
          latitude,
          longitude,
          accuracy,
        }).catch(() => undefined);
    })();
  }, [call, requests]);
}
