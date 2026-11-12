import type { CoreClient, ScreenLogLine } from "@comma/core-client";
import type { AttachmentUploadInput } from "@comma/core/chat";

/** The most lines the pane holds: the oldest go past it. */
export const SHOWN_LINES = 1000;

/**
 * What the logs pane shows of a device's running app's log: the lines (at most SHOWN_LINES), those held back while it is
 * paused (as many), how many the station skipped, whether the app crashed since the pane was last cleared, and the
 * newest line's `seq` this stream gave (`last`), so a line given again is not shown twice.
 */
export type ScreenLogBook = {
  lines: readonly ScreenLogLine[];
  held: readonly ScreenLogLine[];
  paused: boolean;
  dropped: number;
  crashed: boolean;
  last: number;
};

export const emptyLogBook: ScreenLogBook = {
  lines: [],
  held: [],
  paused: false,
  dropped: 0,
  crashed: false,
  last: -1,
};

const kept = (lines: readonly ScreenLogLine[]) =>
  lines.length > SHOWN_LINES ? lines.slice(-SHOWN_LINES) : lines;

/** Lines come: shown, or held while it is paused. A reader that joins is given lines it may have: each is kept once. */
export function addLogLines(
  book: ScreenLogBook,
  lines: readonly ScreenLogLine[],
  dropped = 0
): ScreenLogBook {
  const fresh = lines.filter((line) => line.seq > book.last);
  if (fresh.length === 0 && dropped === 0) return book;
  const said = {
    dropped: book.dropped + dropped,
    crashed: book.crashed || fresh.some((line) => line.crash),
    last: fresh.at(-1)?.seq ?? book.last,
  };
  return book.paused
    ? { ...book, ...said, held: kept([...book.held, ...fresh]) }
    : { ...book, ...said, lines: kept([...book.lines, ...fresh]) };
}

/**
 * Another stream starts (the pane opened again, another filter, the link back): the station gives what it holds first,
 * which is what is shown from then on. Paused stays as it was.
 */
export const restartLogs = (book: ScreenLogBook): ScreenLogBook => ({
  ...emptyLogBook,
  paused: book.paused,
});

export function pauseLogs(book: ScreenLogBook, paused: boolean): ScreenLogBook {
  if (paused === book.paused) return book;
  return paused
    ? { ...book, paused }
    : { ...book, paused, lines: kept([...book.lines, ...book.held]), held: [] };
}

/** What was shown goes; lines that come on are shown (or held) as before, none of those cleared again. */
export const clearLogs = (book: ScreenLogBook): ScreenLogBook => ({
  ...emptyLogBook,
  paused: book.paused,
  last: book.last,
});

/** One line as text, as the pane shows it and as it is copied: its time, level, app (and process), its words. */
export function logLineText(line: ScreenLogLine): string {
  const app = line.pid !== undefined ? `${line.app}[${line.pid}]` : line.app;
  return [line.at, line.level, `${app}:`, line.text]
    .filter((part) => part !== "")
    .join(" ");
}

/** A line's time as the pane shows it: its time of day (`02:12:06.192`), the date and zone left to Copy. */
export function shortTime(at: string): string {
  return /\b(\d\d:\d\d:\d\d(?:\.\d{1,3})?)/.exec(at)?.[1] ?? at;
}

export const logText = (lines: readonly ScreenLogLine[]): string =>
  lines.map(logLineText).join("\n");

/**
 * The newest `count` lines this app has kept of a device's app log, of the filter read last, as they stand now: what
 * sends an agent the screen attaches with it. With the pane closed they are those kept from when it was open. Empty
 * where none was read, or they were cleared.
 */
export async function recentScreenLogs(
  core: Pick<CoreClient, "call">,
  screen: { workspace: string; device: string; screen: string },
  count = 100
): Promise<string> {
  const { lines } = (await core.call("devices.screenLogTail", {
    ...screen,
    lines: count,
  })) as {
    lines: ScreenLogLine[];
  };
  return logText(lines);
}

/**
 * The lines kept of a device's app log (`recentScreenLogs`), as what goes with its picture to a chat: a text file, or
 * none where none are kept (a station from before lists no logs, and a person not its owner is given none).
 */
export async function recentScreenLogFiles(
  core: Pick<CoreClient, "call">,
  screen: { workspace: string; device: string; screen: string },
  count = 100
): Promise<AttachmentUploadInput[]> {
  const text = await recentScreenLogs(core, screen, count);
  if (!text) return [];
  const data = new Blob([text], { type: "text/plain" });
  return [{ name: "app-logs.txt", size: data.size, data }];
}
