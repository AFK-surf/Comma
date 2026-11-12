// The screens the Computer Use helper shows (an app's windows, a whole display), as sources of views. Each view is a
// connection to the helper (`{control: "screen.view", view, auth_token}`, CommaComputerUseSocketServer.swift) that then
// speaks still.fail Helper's messages (CUStream/ScreenView.swift, ported from still.fail's): screen-pipe.ts's
// `HelperView` reads it, the view Windows' desktop has too, and asks for each frame, so a slow link gets fewer frames
// and never a queue of them.
//
// Opening is still.fail's desktop.ts `Desktop.open` (afk/main 7470ca2abe): H.265 where the client takes it (the helper
// makes H.264 where this Mac has no hardware encoder of it), and a helper that was granted Screen Recording since it
// started says so (`code: "restart"`) and ends; it is started again and asked once more. A grant missing says where it
// is given (`station.screen.captureOff`). Cue's own: the helper is the Computer Use daemon, started by the connector
// (`ScreenHelper.ensure`), not an app of the station's own; there is no window asking for the grant.
//
// As still.fail's desktop: a view a person drives carries the Mac's clipboard both ways (text, PNG; the helper's
// CUStream/ScreenClipboard.swift), and a view that asks for it the system output (`audio: true`, never a preview's: its
// CUStream/SystemAudio.swift), of the display, or of an app's view only those apps, never a Comma app's (Cue's: a
// Core Audio process tap or ScreenCaptureKit's filter, docs/desktop-screen.md "Clipboard and sound").
import type { ScreenCatalog } from "../mesh/screens.ts";
import { Context, Layer } from "effect";
import { connect } from "node:net";
import { wall } from "../ops/fibers.ts";
import { ScreenRefused } from "./hub.ts";
import { AS_IS, HelperView } from "./screen-pipe.ts";
import type { Codec, ScreenSource, ViewOptions } from "./source.ts";
import { codecFor } from "./source.ts";

/// What a view of the helper's screens asks besides a source's own: whether its input is taken, which apps it shows,
/// what shows where the picture has no window.
export type HelperViewOptions = ViewOptions & { control?: boolean; apps?: string[]; background?: string };

/// The name macOS lists the helper under in System Settings (apps/electron's packaged "Comma Computer Use.app").
export const HELPER_APP = "Comma Computer Use";
const OPEN_TIMEOUT_MS = 15_000;

/// A helper a connector keeps running: how to start it, the token and socket that reach it.
export type ScreenHelper = {
  ensure(): Promise<void>;
  authToken(): string;
  socketPath: string;
};

/// The helpers this station's connectors keep, the latest attached first: the mesh's views use it.
export class ScreenHelpers {
  readonly #helpers: ScreenHelper[] = [];

  /// Gives the function that takes it away again.
  attach(helper: ScreenHelper): () => void {
    this.#helpers.unshift(helper);
    return () => {
      const at = this.#helpers.indexOf(helper);
      if (at >= 0) this.#helpers.splice(at, 1);
    };
  }

  current(): ScreenHelper | null {
    return this.#helpers[0] ?? null;
  }

  #catalog: (() => Promise<ScreenCatalog>) | null = null;

  /// What the mesh's views would list for the computer's owner, while the station serves them (mesh/mesh.ts); gives the
  /// function that takes it away again.
  offerCatalog(catalog: () => Promise<ScreenCatalog>): () => void {
    this.#catalog = catalog;
    return () => {
      if (this.#catalog === catalog) this.#catalog = null;
    };
  }

  /// Null while the station serves no views of its screens: its owner's app cannot open one now.
  catalog(): (() => Promise<ScreenCatalog>) | null {
    return this.#catalog;
  }
}

export class ScreenHelpersService extends Context.Service<ScreenHelpersService, ScreenHelpers>()("comma/ScreenHelpers") {
  static readonly layer = Layer.sync(ScreenHelpersService, () => new ScreenHelpers());
}

type HelperError = Error & { code?: string };

/// One view on the helper, once its info says it runs: `make` reads the connection (a desktop's or a simulator's
/// input). Started again once when the helper says it ends to take a grant (still.fail desktop.ts `open`'s attempts);
/// a grant missing is refused saying where it is given.
export async function openView<View extends HelperView>(helper: ScreenHelper, view: Record<string, unknown>, make: (socket: ReturnType<typeof connect>) => View): Promise<View> {
  for (let attempt = 0; ; attempt++) {
    await helper.ensure();
    const socket = connect({ path: helper.socketPath });
    socket.once("connect", () => socket.write(`${JSON.stringify({ control: "screen.view", view, auth_token: helper.authToken() })}\n`));
    const opened = make(socket);
    let unarm = () => {};
    try {
      await Promise.race([
        opened.ready,
        new Promise((_, reject) => (unarm = wall.after(OPEN_TIMEOUT_MS, () => reject(new Error("the screen did not start"))))),
      ]);
      return opened;
    } catch (error) {
      opened.close();
      const code = (error as HelperError).code;
      // Granted since the helper started: it has left its socket, and starts again for the next connection.
      if (code === "restart" && attempt === 0) continue;
      if (code === "capture" || code === "restart") throw new ScreenRefused(503, "station.screen.captureOff", { app: HELPER_APP });
      throw new ScreenRefused(503, "station.screen.failed", { said: (error as Error).message });
    } finally {
      unarm();
    }
  }
}

/// The screens a helper shows: an app's windows, the main display. Their sizes are the helper's to say as they open.
export function helperSources(helper: () => ScreenHelper | null): ScreenSource[] {
  // H.265 where the client takes it and this Mac's hardware encodes it (the helper's info says which it made).
  const codecs: readonly Codec[] = ["h265", "h264"];
  const source = (id: "app" | "display"): ScreenSource => ({
    id,
    kind: "desktop",
    codecs,
    // Text and pictures (still.fail desktop.ts `clipboard`): a helper from before lets their messages be.
    clipboard: () => ["text", "png"],
    open: async (options: HelperViewOptions) => {
      const running = helper();
      if (running === null) throw new ScreenRefused(501, "station.screen.failed", { said: "this computer does not stream screens" });
      const codec = codecFor(options, codecs);
      if (codec === undefined) throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264" });
      const audio = options.audio === true && !options.peek;
      return openView(
        running,
        {
          target: id,
          codec,
          control: options.control === true,
          maxWidth: options.maxWidth,
          maxHeight: options.maxHeight,
          ...(id === "app" && options.apps?.length ? { apps: options.apps } : {}),
          ...(options.bitrate !== undefined ? { bitrate: Math.round(options.bitrate) } : {}),
          ...(options.background !== undefined ? { background: options.background } : {}),
          // The pointer apart from the pictures (message 6), which the client draws.
          ...(options.cursor ? { cursor: true } : {}),
          // The system output too (still.fail desktop.ts `open`): a helper from before says no `audio` in its info.
          ...(audio ? { audio: true, ...(options.opus ? { audioCodec: "opus" } : {}) } : {}),
          // Each frame's times (message 66): a helper from before lets it be, and says none.
          ...(options.timing ? { timing: true } : {}),
        },
        (socket) => new HelperView(codec, socket, () => {}, AS_IS, "ScreenCaptureKit", wall.now, audio, options.timing === true),
      );
    },
  });
  return [source("app"), source("display")];
}
