import { useCall, type ListedPhones, type ListedScreen } from "@comma/core-client";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { uiClock } from "@comma/ui/clock";
import { useEffect, useState } from "react";
import { useOptionalCommaClientSettings } from "../commaClientSettings";

// One read of one computer's station, at most this often, while something on the screen shows its devices, however
// many things do, and only where the mesh is on (`useScreenDevicesEnabled`). A person has few computers, and a listing
// is one request.
const LIST_EVERY_MS = 5_000;

export type ScreenListing = {
  screens: readonly ListedScreen[];
  avds: readonly string[];
  /** The iOS Simulators shut down that could boot. */
  simulators: readonly { udid: string; title: string; model?: string }[];
  /** The computer's phones, as its owner chooses them; none from a station without. */
  phones?: ListedPhones | undefined;
  /** A read has answered: a screen not in `screens` is not there. */
  read: boolean;
};

const NOTHING: ScreenListing = { screens: [], avds: [], simulators: [], read: false };

type Call = ReturnType<typeof useCall>;
type Followed = {
  listing: ScreenListing;
  listeners: Set<(listing: ScreenListing) => void>;
  stop(): void;
};

const followed = new Map<string, Followed>();

function follow(
  call: Call,
  workspace: string,
  device: string,
  listen: (listing: ScreenListing) => void
) {
  const key = `${workspace}\n${device}`;
  let entry = followed.get(key);
  if (!entry) {
    let stopped = false;
    let cancel: (() => void) | undefined;
    const made: Followed = {
      listing: NOTHING,
      listeners: new Set(),
      stop() {
        stopped = true;
        cancel?.();
      },
    };
    entry = made;
    followed.set(key, made);
    const read = () => {
      void call("devices.listScreens", { workspace, device })
        .then((answer) => {
          if (stopped) return;
          made.listing = {
            screens: answer.screens,
            avds: answer.avds,
            // (a core from before simulators says none)
            simulators: answer.simulators ?? [],
            phones: answer.phones,
            read: true,
          };
          for (const listener of made.listeners) listener(made.listing);
        })
        // A station out of reach now keeps what it last listed: opening one says why.
        .catch(() => undefined)
        .finally(() => {
          if (!stopped) cancel = uiClock.after(LIST_EVERY_MS, read);
        });
    };
    read();
  }
  const held = entry;
  held.listeners.add(listen);
  listen(held.listing);
  return () => {
    held.listeners.delete(listen);
    if (held.listeners.size > 0) return;
    held.stop();
    if (followed.get(key) === held) followed.delete(key);
  };
}

/**
 * Whether this app reaches the person's computers over the mesh, which their screens' cards, devices and views need:
 * the desktop app and the web page, unless the desktop's Settings › Debug turns it off. Off: nothing here asks anything.
 */
export function useScreenDevicesEnabled(): boolean {
  const mesh =
    useOptionalCommaClientSettings()?.computerMesh ??
    defaultCommaClientSettings.computerMesh;
  return mesh !== "off";
}

/**
 * One computer's Android devices and iOS Simulators, and what could start, kept current while `enabled`. What it last said stays when it
 * stops being enabled, so what goes off the screen and comes back shows at once.
 */
export function useScreenListing(
  workspace: string | undefined,
  device: string | undefined,
  enabled: boolean
): ScreenListing {
  const call = useCall();
  const [listing, setListing] = useState(NOTHING);
  useEffect(() => {
    if (!enabled || !workspace || !device) return undefined;
    return follow(call, workspace, device, (next) => {
      if (next !== NOTHING) setListing(next);
    });
  }, [call, device, enabled, workspace]);
  return listing;
}

/** What a person calls a device: the title without its version. */
export const screenName = (screen: Pick<ListedScreen, "title">) =>
  screen.title.split(" · ")[0] ?? screen.title;
/** Its version, as its title says it. */
export const screenNote = (screen: Pick<ListedScreen, "title">) =>
  screen.title.split(" · ")[1];
