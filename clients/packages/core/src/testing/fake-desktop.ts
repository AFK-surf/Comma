// The desktop app's ports in memory (`DesktopPorts`): the person's presence as a test sets it, the URLs opened in the
// "system browser", the app's returns, loopback listeners a test visits as the browser would (`visit` answers the
// page the core chose), a provider a test scripts, the app's update feed when a test gives one (`FakeUpdates`), and
// Main's chat file dialog as a test scripts it (`pick`).
import { HostError } from "@comma/core-kernel";
import { createHash } from "node:crypto";
import { Cause, Effect, Exit, type Scope } from "effect";
import type {
  ApiResponse,
  AppRelease,
  AppUpdatePorts,
  AppUpdateStatus,
  ChatPickAnswer,
  ChatPickRequest,
  DesktopPorts,
  Loopback,
  LoopbackPage,
  LoopbackVisit,
  Presence,
  ProviderRequest,
  FileRead,
  StreamRead,
  SavedStream,
} from "../host.ts";

type Listener = {
  path: string;
  source: "subscription" | "byok";
  queue: LoopbackVisit[];
  waiting: ((visit: LoopbackVisit) => void) | null;
};

/** What a scripted port answers: its value, or a HostError it fails with, now or later. */
type Scripted<A> = A | HostError | Promise<A | HostError>;

function scripted<A>(answer: () => Scripted<A>): Effect.Effect<A, HostError> {
  return Effect.promise(async () => answer()).pipe(
    Effect.filterOrFail(
      (value): value is A => !(value instanceof HostError),
      (value) => value as HostError
    )
  );
}

/** The app's update feed as a test scripts it (`script`): by default configured, with nothing newer. */
export class FakeUpdates implements AppUpdatePorts {
  script: {
    status(): Scripted<AppUpdateStatus>;
    check(): Scripted<AppRelease | null>;
    download(release: AppRelease): Scripted<boolean>;
    apply(release: AppRelease): Scripted<boolean>;
  } = {
    status: () => ({ configured: true, productName: "Comma Test" }),
    check: () => null,
    download: () => true,
    apply: () => true,
  };
  /** Each port the core asked, in order, with the release it named. */
  readonly asked: [port: "status" | "check" | "download" | "apply", AppRelease?][] = [];

  count(port: "status" | "check" | "download" | "apply"): number {
    return this.asked.filter(([asked]) => asked === port).length;
  }

  get status(): Effect.Effect<AppUpdateStatus, HostError> {
    return scripted(() => {
      this.asked.push(["status"]);
      return this.script.status();
    });
  }

  get check(): Effect.Effect<AppRelease | null, HostError> {
    return scripted(() => {
      this.asked.push(["check"]);
      return this.script.check();
    });
  }

  download(release: AppRelease): Effect.Effect<boolean, HostError> {
    return scripted(() => {
      this.asked.push(["download", release]);
      return this.script.download(release);
    });
  }

  apply(release: AppRelease): Effect.Effect<boolean, HostError> {
    return scripted(() => {
      this.asked.push(["apply", release]);
      return this.script.apply(release);
    });
  }
}

export class FakeDesktop implements DesktopPorts {
  readonly app = { urlScheme: "comma-test", productName: "Comma Test" };
  /** The app's update feed (none: the app does not update itself). */
  updates?: FakeUpdates;
  /** What Main answers about the person. */
  person: Presence = { idleSeconds: 0, homeRepliesShown: true };
  /** How often Main was asked for the presence. */
  presenceAsked = 0;
  readonly opened: string[] = [];
  returns = 0;
  /** Ports another app holds: listening on one fails. */
  readonly taken = new Set<number>();
  /** The listeners open now, by port. */
  readonly listening = new Map<number, Listener>();
  /** The provider's answers; none answers 404. */
  provider: (
    request: ProviderRequest
  ) => ApiResponse | HostError | Promise<ApiResponse | HostError> = () => ({
    status: 404,
    headers: [],
    body: new Uint8Array(),
  });
  readonly provided: ProviderRequest[] = [];
  /** What Main's chat file dialog answers; by default the person cancels it. */
  pick: (request: ChatPickRequest) => Scripted<ChatPickAnswer> = () => ({
    cancelled: true,
    errors: [],
    items: [],
  });
  /** Each pick the core asked Main for. */
  readonly picks: ChatPickRequest[] = [];
  /** Picks the core gave up before Main answered. */
  picksGivenUp = 0;
  /** What Main's Downloads folder answers a save; by default it saves under the name asked. */
  save: (
    fileName: string,
    content: Uint8Array
  ) => Scripted<{
    downloadRef: string;
    fileName: string;
  } | null> = (fileName) => ({ downloadRef: `download:${fileName}`, fileName });
  /** Each file the core saved into Downloads. */
  readonly saved: { fileName: string; content: Uint8Array }[] = [];
  /** What Main answers a stream's opening; by default a new URL. */
  stream: (input: StreamRead & { type: string }) => Scripted<string> = () =>
    `comma-file://stream/${++this.#nextStream}`;
  /** The streams open now, by URL: what each reads, as what, under which session. */
  readonly streams = new Map<string, StreamRead & { type: string }>();
  /** Each URL the core closed, in order. */
  readonly closedStreams: string[] = [];
  /** What Main answers a streamed save; by default it saves under the name asked. */
  saveStreamed: (input: FileRead & { fileName: string }) => Scripted<SavedStream> = ({
    fileName,
  }) => ({
    downloadRef: `download:${fileName}`,
    fileName,
  });
  /** Each streamed save the core asked Main for. */
  readonly streamedSaves: (FileRead & { fileName: string })[] = [];
  #nextPort = 49_152;
  #nextStream = 0;

  saveDownload(
    fileName: string,
    content: Uint8Array
  ): Effect.Effect<{ downloadRef: string; fileName: string } | null, HostError> {
    return scripted(() => {
      this.saved.push({ fileName, content });
      return this.save(fileName, content);
    });
  }

  /** Saves the core writes a part at a time, by id: their name and the parts written so far. */
  readonly #writing = new Map<number, { fileName: string; parts: Uint8Array[] }>();
  #nextSave = 1;

  saveOpen(fileName: string): Effect.Effect<{ id: number }, HostError> {
    return scripted(() => {
      const id = this.#nextSave++;
      this.#writing.set(id, { fileName, parts: [] });
      return { id };
    });
  }

  saveWrite(id: number, bytes: Uint8Array): Effect.Effect<void, HostError> {
    return scripted(() => {
      const writing = this.#writing.get(id);
      if (!writing) return new HostError("no such save");
      writing.parts.push(bytes.slice());
    });
  }

  /** Kept, the file is saved whole as `saveDownload` saves one. */
  saveClose(
    id: number,
    keep: boolean
  ): Effect.Effect<{ downloadRef: string; fileName: string } | null, HostError> {
    return scripted(() => {
      const writing = this.#writing.get(id);
      if (!writing) return new HostError("no such save");
      this.#writing.delete(id);
      if (!keep) return null;
      const content = new Uint8Array(
        writing.parts.reduce((sum, part) => sum + part.length, 0)
      );
      let at = 0;
      for (const part of writing.parts) {
        content.set(part, at);
        at += part.length;
      }
      this.saved.push({ fileName: writing.fileName, content });
      return this.save(writing.fileName, content);
    });
  }

  openStream(input: StreamRead & { type: string }): Effect.Effect<string, HostError> {
    return scripted(() => this.stream(input)).pipe(
      Effect.tap((url) => Effect.sync(() => void this.streams.set(url, input)))
    );
  }

  saveStream(
    input: FileRead & { fileName: string }
  ): Effect.Effect<SavedStream, HostError> {
    return scripted(() => {
      this.streamedSaves.push(input);
      return this.saveStreamed(input);
    });
  }

  closeStream(url: string): Effect.Effect<void, HostError> {
    return Effect.sync(() => {
      this.streams.delete(url);
      this.closedStreams.push(url);
    });
  }

  pickAttachments(request: ChatPickRequest): Effect.Effect<ChatPickAnswer, HostError> {
    return scripted(() => {
      this.picks.push(request);
      return this.pick(request);
    }).pipe(
      Effect.onExit((exit) =>
        Exit.isFailure(exit) && Cause.hasInterruptsOnly(exit.cause)
          ? Effect.sync(() => void (this.picksGivenUp += 1))
          : Effect.void
      )
    );
  }

  get presence(): Effect.Effect<Presence, HostError> {
    return Effect.sync(() => {
      this.presenceAsked += 1;
      return { ...this.person };
    });
  }

  openExternal(url: string): Effect.Effect<void, HostError> {
    return Effect.sync(() => void this.opened.push(url));
  }

  get returnToApp(): Effect.Effect<void> {
    return Effect.sync(() => void (this.returns += 1));
  }

  listen(input: {
    port: number;
    path: string;
    source: "subscription" | "byok";
  }): Effect.Effect<Loopback, HostError, Scope.Scope> {
    return Effect.acquireRelease(
      Effect.suspend(() => {
        const port = input.port || this.#nextPort++;
        if (this.taken.has(port) || this.listening.has(port))
          return Effect.fail(new HostError("authorization_port_in_use"));
        const listener: Listener = {
          path: input.path,
          source: input.source,
          queue: [],
          waiting: null,
        };
        this.listening.set(port, listener);
        return Effect.succeed({ port, listener });
      }),
      ({ port }) => Effect.sync(() => void this.listening.delete(port))
    ).pipe(
      Effect.map(({ port, listener }) => ({
        port,
        next: Effect.callback<LoopbackVisit, HostError>((resume) => {
          const queued = listener.queue.shift();
          if (queued) resume(Effect.succeed(queued));
          else {
            listener.waiting = (visit) => resume(Effect.succeed(visit));
            return Effect.sync(() => void (listener.waiting = null));
          }
        }),
      }))
    );
  }

  /**
   * The browser comes back to `url`: the page the core shows it, `notFound` for an address no listener answers, or
   * `closed` when nothing listens on its port.
   */
  visit(url: string): Promise<LoopbackPage | "notFound" | "closed"> {
    const at = new URL(url);
    const listener = this.listening.get(Number(at.port));
    if (!listener) return Promise.resolve("closed");
    if (at.pathname !== listener.path) return Promise.resolve("notFound");
    return new Promise((shown) => {
      const visit: LoopbackVisit = {
        url: at.href,
        reply: (page) => Effect.sync(() => shown(page)),
      };
      const waiting = listener.waiting;
      if (waiting) {
        listener.waiting = null;
        waiting(visit);
      } else listener.queue.push(visit);
    });
  }

  providerFetch(request: ProviderRequest): Effect.Effect<ApiResponse, HostError> {
    return Effect.promise(async () => {
      this.provided.push(request);
      return this.provider(request);
    }).pipe(
      Effect.flatMap((answer) =>
        answer instanceof HostError
          ? Effect.fail(answer)
          : answer.body.length > request.maxBytes
            ? Effect.fail(new HostError("the answer is too large"))
            : Effect.succeed(answer)
      )
    );
  }

  sha256(input: string): Effect.Effect<Uint8Array, HostError> {
    return Effect.sync(
      () => new Uint8Array(createHash("sha256").update(input, "utf8").digest())
    );
  }
}
