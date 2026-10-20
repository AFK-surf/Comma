// The test page's own requests (./child): `fetch` reaches the test server,
// another origin of the run, or nothing at all, on real time. Each response
// reaches the page only at a fixed point, whole (its body read before), in the
// order the requests completed; page time waits for a request still on its
// way (`requestsIdle`), so what the page sees does not depend on how long the
// network took.

let inFlight = 0;
let idle: (() => void)[] = [];
const completed: (() => void)[] = [];

const settleIdle = () => {
  if (inFlight > 0) return;
  const waiting = idle;
  idle = [];
  for (const resolve of waiting) resolve();
};

/** The response with its whole body in memory: reading it later is no IO. */
export async function wholly(response: Response) {
  // An opaque response (no-cors) has no body to read.
  if (response.type === "opaque") return response;
  const body = await response.arrayBuffer();
  const copy = new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
  for (const key of ["url", "redirected", "type"] as const)
    Object.defineProperty(copy, key, { value: response[key] });
  return copy;
}

/** Holds the responses of the page in `view`'s `fetch` until `deliverResponses`. */
export function holdRequests(view: typeof globalThis) {
  const fetch = view.fetch.bind(view);
  view.fetch = (input, init) =>
    new Promise<Response>((resolve, reject) => {
      inFlight += 1;
      fetch(input, init)
        .then(wholly)
        .then(
          (response) => completed.push(() => resolve(response)),
          (error: unknown) => completed.push(() => reject(error))
        )
        .finally(() => {
          inFlight -= 1;
          settleIdle();
        });
    });
}

/** Resolves once no request of the page is on its way. */
export const requestsIdle = () =>
  inFlight === 0
    ? Promise.resolve()
    : new Promise<void>((resolve) => idle.push(resolve));

/** Gives the page the responses that completed so far, in that order. */
export function deliverResponses() {
  for (const deliver of completed.splice(0)) deliver();
}

export type Download = { suggestedFilename: string; url: string };

const downloads: Download[] = [];

/**
 * A link with `download` the page clicks (`anchor.click()`, input) is kept as
 * the page's download, not handed to the browser: no file reaches the disk,
 * and the test reads what the page asked to save (`downloadsOfPage`).
 */
export function keepDownloads(view: typeof globalThis) {
  view.document.addEventListener(
    "click",
    (event) => {
      const target = event.target as Element | null;
      const anchor = target?.closest?.("a[download]") as HTMLAnchorElement | null;
      if (!anchor) return;
      event.preventDefault();
      downloads.push({
        suggestedFilename: anchor.download || "download",
        url: anchor.href,
      });
    },
    true
  );
}

/** The downloads the page asked for, in order. */
export const downloadsOfPage = (): Download[] => [...downloads];

export type Popup = { url: string };

const popups: Popup[] = [];

/**
 * A new window the page opens with `noopener` (`window.open(url, "_blank",
 * "noopener")`) is kept as the page's popup, not opened by the browser: no
 * page outside the test loads, and the test reads which URL the page opened
 * (`popupsOfPage`). As in a browser, the page gets no handle to it. A window
 * the page would keep a handle to is not offered: opening one fails.
 */
export function keepPopups(view: typeof globalThis) {
  const open = view.open.bind(view);
  view.open = (url?: string | URL, target?: string, features?: string) => {
    if (target !== undefined && target !== "" && target !== "_blank")
      return open(url, target, features);
    const href = new URL(String(url ?? "about:blank"), view.location.href).href;
    if (!/(^|[\s,])noopener($|[\s,=])/.test(features ?? ""))
      throw new Error(
        `window.open(${href}) keeps a handle to the new window: a test page offers only popups opened with noopener.`
      );
    popups.push({ url: href });
    return null;
  };
}

/** The popups the page opened, in order. */
export const popupsOfPage = (): Popup[] => [...popups];
