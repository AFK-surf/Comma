/** The clock the fake plays on: page time, and work after each frame. */
export type FakeMediaClock = {
  elapsed(): number;
  eachFrame(work: (elapsed: number) => void): () => void;
};

/**
 * Media elements that play on the test clock. A test that turns them on
 * (`useFixture(mount, { media })`) never decodes or plays a real file: the
 * browser's own media events are stopped before they reach the page, and each
 * `<audio>`/`<video>` loads, plays and seeks a described source on page time,
 * firing the events a browser fires in the order it fires them. Its work runs
 * after the timers of each test-clock frame: an event a browser queues fires on
 * the next frame, metadata one frame after a source is set, and `timeupdate`
 * every 250 ms of play.
 */
export type FakeMediaSource = {
  /** Seconds. */
  duration: number;
  /** The video's natural size; absent for audio. */
  width?: number;
  height?: number;
  /** False when another origin serves it without CORS: a fetch of it fails. */
  cors?: boolean;
};

/** Sources by file name: the last path segment of the element's `src`. */
export type FakeMediaSources = Record<string, FakeMediaSource>;

const metadataDelayMs = 16;
const timeUpdateIntervalMs = 250;

const browserMediaEvents = [
  "abort",
  "canplay",
  "canplaythrough",
  "durationchange",
  "emptied",
  "ended",
  "error",
  "loadeddata",
  "loadedmetadata",
  "loadstart",
  "pause",
  "play",
  "playing",
  "progress",
  "ratechange",
  "resize",
  "seeked",
  "seeking",
  "stalled",
  "suspend",
  "timeupdate",
  "volumechange",
  "waiting",
];

type State = {
  source: FakeMediaSource | undefined;
  networkState: number;
  readyState: number;
  paused: boolean;
  ended: boolean;
  seeking: boolean;
  // Position at page time `anchoredAt`, moving at `playbackRate` while playing.
  position: number;
  anchoredAt: number;
  playbackRate: number;
  defaultPlaybackRate: number;
  volume: number;
  muted: boolean;
  pendingPlays: { resolve: () => void; reject: (error: unknown) => void }[];
  tasks: Set<Task>;
  ticker: Task | undefined;
};
type Task = { at: number; run: () => void };

const states = new WeakMap<HTMLMediaElement, State>();
let browserEventsStopped = false;
let sources: FakeMediaSources = {};
// Page time, as of the last frame, and the work due from it in queue order.
// Page time now: read from the page's clock whenever media code runs, so work
// queued between two of its frames (a timer's callback, a jump of page time)
// is due from when it was queued.
let mediaClock: FakeMediaClock | undefined;
let lastFrame = 0;
const now = () => mediaClock?.elapsed() ?? lastFrame;
let tasks: Task[] = [];

const runFrame = (elapsed: number) => {
  lastFrame = elapsed;
  // Work queued while this runs is due on a later frame.
  const due = tasks
    .filter((task) => task.at <= elapsed)
    .toSorted((a, b) => a.at - b.at);
  tasks = tasks.filter((task) => task.at > elapsed);
  for (const task of due) task.run();
};

const stateOf = (element: HTMLMediaElement) => {
  let state = states.get(element);
  if (!state) {
    state = {
      source: undefined,
      networkState: HTMLMediaElement.NETWORK_EMPTY,
      readyState: HTMLMediaElement.HAVE_NOTHING,
      paused: true,
      ended: false,
      seeking: false,
      position: 0,
      anchoredAt: now(),
      playbackRate: 1,
      defaultPlaybackRate: 1,
      volume: 1,
      muted: false,
      pendingPlays: [],
      tasks: new Set(),
      ticker: undefined,
    };
    states.set(element, state);
  }
  return state;
};

const later = (element: HTMLMediaElement, ms: number, run: () => void) => {
  const state = stateOf(element);
  const task: Task = {
    at: now() + ms,
    run: () => {
      if (state.tasks.delete(task)) run();
    },
  };
  state.tasks.add(task);
  tasks.push(task);
  return task;
};
const fire = (element: HTMLMediaElement, ...types: string[]) => {
  for (const type of types) element.dispatchEvent(new Event(type));
};
const queue = (element: HTMLMediaElement, ...types: string[]) =>
  later(element, 0, () => fire(element, ...types));

const duration = (state: State) => state.source?.duration ?? Number.NaN;
const playing = (state: State) =>
  !state.paused &&
  !state.ended &&
  state.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA;
const position = (state: State) =>
  playing(state)
    ? Math.min(
        duration(state),
        state.position + ((now() - state.anchoredAt) / 1000) * state.playbackRate
      )
    : state.position;
const anchor = (state: State, at = position(state)) => {
  state.position = at;
  state.anchoredAt = now();
};

const settlePlays = (state: State, error?: DOMException) => {
  const plays = state.pendingPlays.splice(0);
  for (const play of plays) {
    if (error) play.reject(error);
    else play.resolve();
  }
};
const abortError = () =>
  new DOMException("The play() request was interrupted.", "AbortError");

const stopTicker = (state: State) => {
  if (state.ticker) state.tasks.delete(state.ticker);
  state.ticker = undefined;
};
// While playing: `timeupdate` every 250 ms, and the end of the source on time.
const tick = (element: HTMLMediaElement) => {
  const state = stateOf(element);
  stopTicker(state);
  if (!playing(state) || state.playbackRate <= 0) return;
  const remainingMs = ((duration(state) - position(state)) / state.playbackRate) * 1000;
  state.ticker = later(
    element,
    Math.max(0, Math.min(timeUpdateIntervalMs, remainingMs)),
    () => {
      state.ticker = undefined;
      if (position(state) >= duration(state)) {
        anchor(state, duration(state));
        state.ended = true;
        state.paused = true;
        fire(element, "timeupdate", "pause", "ended");
        return;
      }
      fire(element, "timeupdate");
      tick(element);
    }
  );
};

const notifyPlaying = (element: HTMLMediaElement) => {
  const state = stateOf(element);
  anchor(state);
  later(element, 0, () => {
    if (state.paused) return;
    fire(element, "playing");
    settlePlays(state);
  });
  tick(element);
};

// The media element load algorithm, without the network.
const runLoad = (element: HTMLMediaElement) => {
  const state = stateOf(element);
  state.tasks.clear();
  state.ticker = undefined;
  settlePlays(state, abortError());
  if (state.networkState !== HTMLMediaElement.NETWORK_EMPTY) {
    queue(element, "emptied");
    state.networkState = HTMLMediaElement.NETWORK_EMPTY;
    state.readyState = HTMLMediaElement.HAVE_NOTHING;
    state.paused = true;
    state.seeking = false;
    if (state.position !== 0) queue(element, "timeupdate");
    state.source = undefined;
  }
  anchor(state, 0);
  state.ended = false;
  state.playbackRate = state.defaultPlaybackRate;

  const src = element.getAttribute("src");
  if (!src) return;
  state.networkState = HTMLMediaElement.NETWORK_LOADING;
  queue(element, "loadstart");
  const name = new URL(src, document.baseURI).pathname.split("/").at(-1)!;
  const source = sources[name];
  later(element, metadataDelayMs, () => {
    if (!source) {
      state.networkState = HTMLMediaElement.NETWORK_NO_SOURCE;
      fire(element, "error");
      reportError(new Error(`No fake media source describes ${name}.`));
      return;
    }
    state.source = source;
    state.networkState = HTMLMediaElement.NETWORK_IDLE;
    state.readyState = HTMLMediaElement.HAVE_METADATA;
    fire(element, "durationchange");
    if (element instanceof HTMLVideoElement) fire(element, "resize");
    fire(element, "loadedmetadata");
    // A start position set before metadata applies now.
    state.position = Math.min(state.position, source.duration);
    state.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    fire(element, "loadeddata", "canplay", "canplaythrough");
    if (!state.paused) notifyPlaying(element);
  });
};

const seek = (element: HTMLMediaElement, to: number) => {
  const state = stateOf(element);
  if (state.readyState === HTMLMediaElement.HAVE_NOTHING) {
    state.position = Math.max(0, to);
    return;
  }
  anchor(state, Math.max(0, Math.min(duration(state), to)));
  state.ended = false;
  state.seeking = true;
  queue(element, "seeking");
  later(element, 0, () => {
    state.seeking = false;
    fire(element, "timeupdate", "seeked");
  });
  tick(element);
};

/** Replaces media playback in the test's page (its iframe, ./child). */
const contentTypes: Record<string, string> = {
  m4a: "audio/mp4",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  mp4: "video/mp4",
  ogg: "audio/ogg",
  wav: "audio/wav",
  webm: "video/webm",
};
// What the page's fetch did before the fakes: the harness's held fetch
// (./requests), kept when the fakes are installed.
let nativeFetch: typeof fetch = (...args) => window.fetch(...args);
let fetchFaked = false;

// The page fetches a fake source (to download it) from memory, answered on the
// next test-clock frame, as no network is involved: a source another origin
// serves without CORS fails as a browser's CORS check fails.
function fakeFetch(input: RequestInfo | URL, init?: RequestInit) {
  const href = input instanceof Request ? input.url : String(input);
  const url = new URL(href, location.href);
  const name = url.pathname.split("/").at(-1) ?? "";
  const source = sources[name];
  if (!source) return nativeFetch(input, init);
  const mode = init?.mode ?? (input instanceof Request ? input.mode : "cors");
  const blocked =
    url.origin !== location.origin && source.cors === false && mode === "cors";
  const type = contentTypes[name.split(".").at(-1) ?? ""] ?? "application/octet-stream";
  return new Promise<Response>((resolve, reject) => {
    tasks.push({
      at: now() + metadataDelayMs,
      run: () => {
        if (blocked) {
          reject(new TypeError("Failed to fetch"));
          return;
        }
        const body = new Blob([new Uint8Array(1024)], { type });
        resolve(new Response(body, { status: 200, headers: { "Content-Type": type } }));
      },
    });
  });
}

export function installFakeMedia(described: FakeMediaSources, clock: FakeMediaClock) {
  sources = described;
  if (!fetchFaked) {
    fetchFaked = true;
    nativeFetch = window.fetch.bind(window);
    window.fetch = fakeFetch;
  }
  mediaClock = clock;
  lastFrame = clock.elapsed();
  tasks = [];
  clock.eachFrame(runFrame);
  if (!browserEventsStopped) {
    browserEventsStopped = true;
    // The real elements still load their files; nothing they report reaches
    // the page. A capturing listener on the window runs before any other.
    for (const type of browserMediaEvents) {
      window.addEventListener(
        type,
        (event) => {
          if (event.isTrusted && event.target instanceof HTMLMediaElement)
            event.stopImmediatePropagation();
        },
        { capture: true }
      );
    }
  }

  const media = HTMLMediaElement.prototype;
  const nativeSrc = Object.getOwnPropertyDescriptor(media, "src")!;
  const nativeSetAttribute = Element.prototype.setAttribute;
  const nativeRemoveAttribute = Element.prototype.removeAttribute;

  const accessor = (
    prototype: object,
    key: string,
    get: (element: HTMLMediaElement, state: State) => unknown,
    set?: (element: HTMLMediaElement, state: State, value: never) => void
  ) =>
    Object.defineProperty(prototype, key, {
      configurable: true,
      enumerable: true,
      get(this: HTMLMediaElement) {
        return get(this, stateOf(this));
      },
      ...(set && {
        set(this: HTMLMediaElement, value: never) {
          set(this, stateOf(this), value);
        },
      }),
    });
  const ranges = (state: State) => {
    const end =
      state.readyState >= HTMLMediaElement.HAVE_METADATA ? duration(state) : 0;
    const length = end > 0 ? 1 : 0;
    const at = (index: number, value: number) => {
      if (index < 0 || index >= length)
        throw new DOMException("Index out of range.", "IndexSizeError");
      return value;
    };
    return {
      length,
      start: (index: number) => at(index, 0),
      end: (index: number) => at(index, end),
    } as TimeRanges;
  };

  accessor(media, "networkState", (_, state) => state.networkState);
  accessor(media, "readyState", (_, state) => state.readyState);
  accessor(media, "paused", (_, state) => state.paused);
  accessor(media, "ended", (_, state) => state.ended);
  accessor(media, "seeking", (_, state) => state.seeking);
  accessor(media, "duration", (_, state) => duration(state));
  accessor(media, "error", () => null);
  accessor(media, "currentSrc", (element, state) =>
    state.networkState === HTMLMediaElement.NETWORK_EMPTY ? "" : element.src
  );
  accessor(media, "seekable", (_, state) => ranges(state));
  accessor(media, "buffered", (_, state) => ranges(state));
  accessor(
    media,
    "currentTime",
    (_, state) => position(state),
    (element, _, value: number) => seek(element, Number(value))
  );
  accessor(
    media,
    "playbackRate",
    (_, state) => state.playbackRate,
    (element, state, value: number) => {
      if (state.playbackRate === value) return;
      anchor(state);
      state.playbackRate = value;
      queue(element, "ratechange");
      tick(element);
    }
  );
  accessor(
    media,
    "defaultPlaybackRate",
    (_, state) => state.defaultPlaybackRate,
    (element, state, value: number) => {
      if (state.defaultPlaybackRate === value) return;
      state.defaultPlaybackRate = value;
      queue(element, "ratechange");
    }
  );
  accessor(
    media,
    "volume",
    (_, state) => state.volume,
    (element, state, value: number) => {
      if (!(value >= 0 && value <= 1))
        throw new DOMException("The volume is outside [0, 1].", "IndexSizeError");
      if (state.volume === value) return;
      state.volume = value;
      queue(element, "volumechange");
    }
  );
  accessor(
    media,
    "muted",
    (_, state) => state.muted,
    (element, state, value: boolean) => {
      if (state.muted === Boolean(value)) return;
      state.muted = Boolean(value);
      queue(element, "volumechange");
    }
  );
  accessor(
    media,
    "src",
    (element) => nativeSrc.get!.call(element),
    (element, _, value: string) => {
      nativeSrc.set!.call(element, value);
      runLoad(element);
    }
  );
  accessor(HTMLVideoElement.prototype, "videoWidth", (_, state) =>
    state.readyState >= HTMLMediaElement.HAVE_METADATA ? (state.source?.width ?? 0) : 0
  );
  accessor(HTMLVideoElement.prototype, "videoHeight", (_, state) =>
    state.readyState >= HTMLMediaElement.HAVE_METADATA ? (state.source?.height ?? 0) : 0
  );

  Element.prototype.setAttribute = function setAttribute(name: string, value: string) {
    nativeSetAttribute.call(this, name, value);
    if (this instanceof HTMLMediaElement && name.toLowerCase() === "src") runLoad(this);
  };
  Element.prototype.removeAttribute = function removeAttribute(name: string) {
    const had = this.hasAttribute(name);
    nativeRemoveAttribute.call(this, name);
    if (had && this instanceof HTMLMediaElement && name.toLowerCase() === "src")
      runLoad(this);
  };

  media.load = function load(this: HTMLMediaElement) {
    runLoad(this);
  };
  media.pause = function pause(this: HTMLMediaElement) {
    const state = stateOf(this);
    if (state.networkState === HTMLMediaElement.NETWORK_EMPTY) runLoad(this);
    if (state.paused) return;
    anchor(state);
    state.paused = true;
    stopTicker(state);
    later(this, 0, () => {
      fire(this, "timeupdate", "pause");
      settlePlays(state, abortError());
    });
  };
  media.play = function play(this: HTMLMediaElement) {
    const state = stateOf(this);
    if (state.networkState === HTMLMediaElement.NETWORK_EMPTY) runLoad(this);
    if (state.ended || (state.source && position(state) >= duration(state)))
      seek(this, 0);
    const request = new Promise<void>((resolve, reject) => {
      state.pendingPlays.push({ resolve, reject });
    });
    if (state.paused) {
      state.paused = false;
      queue(this, "play");
      if (state.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA) notifyPlaying(this);
      else queue(this, "waiting");
    } else if (state.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA) {
      later(this, 0, () => settlePlays(state));
    }
    return request;
  };
}
