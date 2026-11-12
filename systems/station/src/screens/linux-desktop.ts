// This Linux computer's desktop as the screen source `display` (docs/desktop-screen.md, "Linux"): the station user's
// active X11 session, looked up as a view asks for it (linux-session.ts), captured and driven by x11-desktop.ts.
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 9967fe35be) station/src/screens/linux-desktop.ts
// `LinuxDesktop`, with its X11 path only. Not ported: its Wayland portal and its GStreamer/XTest X11 fallback
// (linux-portal.ts, linux-portal.py, linux-x11.py). Both send only JPEG, and Cue's desktop viewer decodes H.264 and
// H.265 only (docs/desktop-screen.md, "Deviations"). A Wayland session is said so (`linuxWayland`), as still.fail's
// X11Desktop says it.
import { hostname } from "node:os";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import { desktopEnvironment } from "./linux-session.ts";
import { LinuxScreenTools } from "./linux-tools.ts";
import type { Codec, ScreenSource, ScreenView, ViewOptions } from "./source.ts";
import { type ScreenAccess, X11Desktop, type X11DesktopOptions } from "./x11-desktop.ts";

type LinuxOptions = { data: string; changed?: () => void; title?: () => string; env?: NodeJS.ProcessEnv; discover?: (env: NodeJS.ProcessEnv) => Promise<NodeJS.ProcessEnv> };

/// Whether this station serves a Linux desktop (`display`): on Linux. What the mesh's views (mesh/mesh.ts) and the
/// connector's `screen_view` capability go by; a view says why it cannot open (no desktop, the tools, Wayland).
export const hasLinuxDesktop = (): boolean => platform.hasLinuxDesktop;

export class LinuxDesktop implements ScreenSource {
  readonly id = "display";
  readonly kind = "desktop" as const;
  readonly codecs: readonly Codec[] = ["h264", "jpeg"];
  readonly #o: LinuxOptions;
  readonly #x11Options: X11DesktopOptions;
  readonly #tools: LinuxScreenTools;
  readonly #x11: X11Desktop;
  #refreshing: Promise<void> | null = null;
  #looked = 0;

  constructor(options: LinuxOptions) {
    this.#o = options;
    const env = { ...(options.env ?? process.env) };
    this.#tools = new LinuxScreenTools(options.data);
    this.#x11Options = { changed: () => options.changed?.(), title: options.title, env, tools: this.#tools };
    this.#x11 = new X11Desktop(this.#x11Options);
  }
  title(): string { return this.#o.title?.() ?? hostname(); }
  size(): { width: number; height: number } { return this.#x11.size(); }
  access(): ScreenAccess { return this.#x11.access(); }
  async refresh(force = false): Promise<void> {
    if (!force && wall.now() - this.#looked < 2_000) return;
    this.#refreshing ??= (async () => {
      this.#x11Options.env = await (this.#o.discover ?? desktopEnvironment)(this.#o.env ?? process.env);
      await this.#x11.refresh(force);
    })().finally(() => { this.#looked = wall.now(); this.#refreshing = null; });
    await this.#refreshing;
  }
  async open(options: ViewOptions): Promise<ScreenView> {
    await this.refresh(true);
    return this.#x11.open(options);
  }
  async close(): Promise<void> { await this.#x11.close(); }
}
