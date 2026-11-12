// The computer's screens as its agents link to them (the device connection's `screen_links`, Salix's `device.screens`):
// each one its owner could open now, with its `comma:screen/<device id>/<screen id>` link. A message line that is only
// such a link is the screen's card in the owner's Comma app (clients/packages/app/src/components/remote-screen/
// screenLinks.ts), which opens the live screen. The screen id is `display`, `android:<serial>` or `simulator:<udid>`, and
// each part is escaped as a path's part is. Only the screens the mesh's views would list are here: the station serves
// them only while its owner's app reaches it over the mesh.
import type { ScreenCatalog } from "../mesh/screens.ts";

/// The most of each list one answer says; `more` says that some were left out.
export const LINKS_MOST = 24;
/// The longest title said.
const TITLE_MOST = 120;

/// A screen's link, as a client parses it.
export function screenLink(device: string, screen: string): string {
  return `comma:screen/${encodeURIComponent(device)}/${encodeURIComponent(screen)}`;
}

export type LinkedScreen = { link: string; kind: "display" | "simulator" | "android"; title: string; phone?: true };

export type ScreenLinks = {
  device_id: string;
  screens: LinkedScreen[];
  /// iOS Simulators shut down that could boot, and Android Virtual Devices that could start: once started, list again.
  bootable_simulators: { udid: string; title: string }[];
  startable_avds: string[];
  more?: true;
  /// Why no screen can be opened now; why Android devices cannot be listed (`android_unavailable`).
  unavailable?: string;
  android_unavailable?: string;
};

/// Said where the station serves no views of its screens now.
export const NOT_SERVED = "this computer serves no screen views now: its owner's Comma desktop app reaches it over the mesh, which is off or not connected (Settings › Debug › Computers over the mesh)";

const titled = (title: string | undefined, id: string) => (title ?? id).slice(0, TITLE_MOST);

/// The links of what `catalog` lists (null: the station serves no views now) for the computer `device`.
export async function screenLinksOf(device: string, catalog: (() => Promise<ScreenCatalog>) | null): Promise<ScreenLinks> {
  const none = { device_id: device, screens: [], bootable_simulators: [], startable_avds: [] };
  if (!device) return { ...none, unavailable: "this connection does not know its device yet: try again in a moment" };
  if (!catalog) return { ...none, unavailable: NOT_SERVED };
  const listed = await catalog();
  if (listed.refused) return { ...none, unavailable: listed.refused };
  // (`app`, an app's windows, is no screen a link names)
  const screens = listed.screens.flatMap((s): LinkedScreen[] => {
    if (s.id === "display") return [{ link: screenLink(device, s.id), kind: "display", title: "Display" }];
    if ((s.kind === "simulator" || s.kind === "android") && /^(android|simulator):[^/?#\s]{1,200}$/.test(s.id))
      return [{ link: screenLink(device, s.id), kind: s.kind, title: titled(s.title, s.id), ...(s.phone ? { phone: true as const } : {}) }];
    return [];
  });
  const more = screens.length > LINKS_MOST || listed.simulators.length > LINKS_MOST || listed.avds.length > LINKS_MOST;
  return {
    device_id: device,
    screens: screens.slice(0, LINKS_MOST),
    bootable_simulators: listed.simulators.slice(0, LINKS_MOST).map((s) => ({ udid: s.udid, title: titled(s.title, s.udid) })),
    startable_avds: listed.avds.slice(0, LINKS_MOST),
    ...(more ? { more: true as const } : {}),
    ...(listed.devicesUnavailable ? { android_unavailable: listed.devicesUnavailable } : {}),
  };
}
