import type { ListedScreen } from "@comma/core-client";
import type { ScreenListing } from "./useScreenListing";
import { screenName, screenNote } from "./useScreenListing";

/** The kinds of device a computer can boot by model: its iOS Simulators, its Android Virtual Devices. A phone is neither. */
export type ScreenPlatform = "ios" | "android";

/** What can start in place of a model that is not running: an AVD by its name, or a simulator by its UDID. */
export type StartableScreen = { avd: string } | { simulator: string; title: string };

/** One model of a computer's: a running device of it to show, or one to start. */
export type ScreenModel = {
  name: string;
  /** Its runtime, as its title says it ("iOS 27.1"); none for an AVD that is not running. */
  runtime?: string | undefined;
  running?: ListedScreen | undefined;
  start?: StartableScreen | undefined;
};

/** At most this many models show in the menu itself, every running one among them; the rest are behind its "More…". */
const SHOWN_MODELS = 10;
/** So many models a person chose last are kept, for each computer and platform. */
const RECENT_MODELS = 5;

/** The platform of a device that boots by model; none for a phone. */
export function platformOf(
  screen: Pick<ListedScreen, "id" | "phone">
): ScreenPlatform | undefined {
  if (screen.id.startsWith("simulator:")) return "ios";
  if (screen.id.startsWith("android:") && !screen.phone) return "android";
  return undefined;
}

/** A runtime's version, "iOS 27.1" → [27, 1] ([0] where it says none). */
const versionOf = (runtime: string | undefined) =>
  (/(\d+(?:\.\d+)*)/.exec(runtime ?? "")?.[1] ?? "0").split(".").map(Number);

/** "iOS 27.1" against "iOS 17.0": the later first (none counts as 0). */
function newerFirst(a: string | undefined, b: string | undefined): number {
  const [x, y] = [versionOf(a), versionOf(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const diff = (y[i] ?? 0) - (x[i] ?? 0);
    if (diff) return diff;
  }
  return 0;
}

/**
 * A computer's models of `platform`, each once by its hardware model (name on older stations): the device the tab shows for its own model, else a running
 * one, else the one on the newest runtime that could boot. The current model first, then those chosen lately (`recent`,
 * the latest first), then the newest runtime first and by name. `more`: those that would make the list long, and those
 * only on an older runtime, which a person rarely wants.
 */
export function screenModels(
  listing: Pick<ScreenListing, "screens" | "avds" | "simulators">,
  platform: ScreenPlatform,
  current: ListedScreen | undefined,
  recent: readonly string[] = []
): { shown: ScreenModel[]; more: ScreenModel[] } {
  const byName = new Map<string, ScreenModel>();
  const offer = (model: ScreenModel) => {
    const had = byName.get(model.name);
    const better =
      !had ||
      (model.running !== undefined &&
        (had.running === undefined || model.running.instance === current?.instance)) ||
      (had.running === undefined && newerFirst(model.runtime, had.runtime) < 0);
    if (better) byName.set(model.name, model);
  };
  for (const screen of listing.screens)
    if (platformOf(screen) === platform)
      offer({
        name: screen.model || screen.name || screenName(screen),
        runtime: screenNote(screen),
        running: screen,
      });
  if (platform === "ios")
    for (const simulator of listing.simulators)
      offer({
        name: simulator.model || screenName(simulator),
        runtime: screenNote(simulator),
        start: { simulator: simulator.udid, title: simulator.title },
      });
  else for (const avd of listing.avds) offer({ name: avd, start: { avd } });

  const models = [...byName.values()];
  const newest = models.reduce<string | undefined>(
    (best, model) => (newerFirst(model.runtime, best) < 0 ? model.runtime : best),
    undefined
  );
  const rank = (model: ScreenModel) => {
    if (model.running && model.running.instance === current?.instance) return -1;
    const at = recent.indexOf(model.name);
    return at < 0 ? recent.length : at;
  };
  models.sort(
    (a, b) =>
      rank(a) - rank(b) ||
      newerFirst(a.runtime, b.runtime) ||
      a.name.localeCompare(b.name, undefined, { numeric: true })
  );
  // A running model is never behind "More…": each keeps the place it has, and what could start takes the room left.
  let room = Math.max(SHOWN_MODELS - models.filter((model) => model.running).length, 0);
  const shown: ScreenModel[] = [];
  const more: ScreenModel[] = [];
  for (const model of models) {
    if (model.running) {
      shown.push(model);
      continue;
    }
    const older =
      rank(model) >= recent.length &&
      // (an AVD not running says no runtime: it is never older)
      model.runtime !== undefined &&
      newerFirst(model.runtime, newest) > 0;
    if (older || room === 0) more.push(model);
    else {
      shown.push(model);
      room -= 1;
    }
  }
  return { shown, more };
}

const recentKey = (workspace: string, device: string, platform: ScreenPlatform) =>
  `comma.screenModels.recent\n${workspace}\n${device}\n${platform}`;

/** The models of a computer's a person chose lately on this device, the latest first (none where storage is not to be had). */
export function recentScreenModels(
  workspace: string,
  device: string,
  platform: ScreenPlatform
): string[] {
  try {
    const kept: unknown = JSON.parse(
      localStorage.getItem(recentKey(workspace, device, platform)) ?? "[]"
    );
    return Array.isArray(kept)
      ? kept.filter((one): one is string => typeof one === "string")
      : [];
  } catch {
    return [];
  }
}

/** Keeps `name` as the model chosen last. */
export function rememberScreenModel(
  workspace: string,
  device: string,
  platform: ScreenPlatform,
  name: string
) {
  const kept = [
    name,
    ...recentScreenModels(workspace, device, platform).filter((one) => one !== name),
  ].slice(0, RECENT_MODELS);
  try {
    localStorage.setItem(recentKey(workspace, device, platform), JSON.stringify(kept));
  } catch {
    // (a private window, storage turned off: the order is newest first alone)
  }
}

/**
 * The simulator or emulator of a computer's to show first: of those running, the model chosen last on this device,
 * else the first listed; none where none runs.
 */
export function latestRunningModel(
  listing: Pick<ScreenListing, "screens">,
  workspace: string,
  device: string
): ListedScreen | undefined {
  const running = listing.screens.filter((screen) => platformOf(screen));
  const rank = (screen: ListedScreen) => {
    const at = recentScreenModels(workspace, device, platformOf(screen)!).indexOf(
      screen.model || screen.name || screenName(screen)
    );
    return at < 0 ? Number.POSITIVE_INFINITY : at;
  };
  return running.reduce<ListedScreen | undefined>(
    (best, screen) => (!best || rank(screen) < rank(best) ? screen : best),
    undefined
  );
}

/** Whether a computer has simulators or emulators at all: running, or that could start. */
export const hasScreenModels = (
  listing: Pick<ScreenListing, "screens" | "avds" | "simulators">
) =>
  listing.simulators.length > 0 ||
  listing.avds.length > 0 ||
  listing.screens.some((screen) => platformOf(screen));
