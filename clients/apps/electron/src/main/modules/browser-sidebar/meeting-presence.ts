/** Main-owned observation of supported meeting pages; no page gets a native bridge. */
export interface BrowserMeetingPage {
  id: string;
  tabId: string;
  visible: boolean;
  contents: {
    getURL(): string;
    getOSProcessId(): number;
    isDestroyed(): boolean;
    executeJavaScript(source: string): Promise<unknown>;
  };
}
export interface BrowserMeeting {
  id: string;
  tabId: string;
  name: string;
  processId: number;
}

export function googleMeetRoom(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    if (
      parsed.origin === "https://meet.google.com" &&
      /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}\/?$/.test(parsed.pathname)
    )
      return parsed.pathname.replace(/\/$/, "");
  } catch {
    /* An empty/destroyed page is not a meeting. */
  }
  return undefined;
}

// Meet has no supported SDK for observing an existing browser tab's joined state.
// The room URL also hosts the lobby, and joined calls can be silent/muted.
// call_end is the rendered, language-independent Material hang-up icon.
export const googleMeetJoinedSource = `(() => {
  if (location.origin !== "https://meet.google.com") return false;
  return Array.from(document.querySelectorAll('button, [role="button"]')).some(button => {
    if (!button.getClientRects().length || getComputedStyle(button).visibility === 'hidden') return false;
    return Array.from(button.querySelectorAll('i, span')).some(icon => icon.textContent?.trim() === 'call_end');
  });
})()`;

/**
 * Reuses the presence owner's 2s tick: <=4 page reads/tick, <=1 outstanding
 * read/page, 750ms wait. Main's registry is capped at 32 tabs. Cached observations
 * preserve other meetings while we rotate background pages, rather than running
 * a full per-tab RPC scan. The visible page gets one slot; others rotate fairly.
 */
export class BrowserMeetingProbe {
  #cursor = 0;
  readonly #observed = new Map<string, BrowserMeeting>();
  readonly #pending = new WeakMap<
    BrowserMeetingPage["contents"],
    { room: string | undefined; result: Promise<unknown> }
  >();

  async read(pages: readonly BrowserMeetingPage[]): Promise<BrowserMeeting[]> {
    const candidates = pages.filter(
      (page) => !page.contents.isDestroyed() && googleMeetRoom(page.contents.getURL())
    );
    const current = new Map(
      candidates.map((page) => [
        page.id,
        `${page.id}:${googleMeetRoom(page.contents.getURL())}`,
      ])
    );
    for (const [id, meeting] of this.#observed)
      if (current.get(id) !== meeting.id) this.#observed.delete(id);
    if (!candidates.length) return [];
    const preferred = candidates.find((page) => page.visible);
    const batch = preferred ? [preferred] : [];
    for (let i = 0; i < candidates.length && batch.length < 4; i++) {
      const page = candidates[this.#cursor++ % candidates.length]!;
      if (!batch.includes(page)) batch.push(page);
    }
    await Promise.all(
      batch.map(async (page) => {
        const room = googleMeetRoom(page.contents.getURL());
        let pending = this.#pending.get(page.contents);
        if (!pending) {
          pending = {
            room,
            result: Promise.resolve()
              .then(() => page.contents.executeJavaScript(googleMeetJoinedSource))
              .catch(() => false),
          };
          this.#pending.set(page.contents, pending);
          void pending.result.finally(() => this.#pending.delete(page.contents));
        }
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
          const joined = await Promise.race([
            pending.result,
            new Promise<false>((resolve) => {
              timer = setTimeout(() => resolve(false), 750);
            }),
          ]);
          const processId = page.contents.isDestroyed()
            ? 0
            : page.contents.getOSProcessId();
          if (
            joined === true &&
            pending.room === room &&
            processId > 0 &&
            googleMeetRoom(page.contents.getURL()) === room
          ) {
            this.#observed.set(page.id, {
              id: `${page.id}:${room}`,
              tabId: page.tabId,
              name: `Google Meet · ${room!.slice(1)}`,
              processId,
            });
          } else this.#observed.delete(page.id);
        } finally {
          if (timer) clearTimeout(timer);
        }
      })
    );
    return [...this.#observed.values()];
  }
}
