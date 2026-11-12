import {
  useCore,
  type ListedScreen,
  type ScreenLogEvent,
  type ScreenLogLine,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { Collapse, CollapseContent } from "@comma/ui/components/collapse";
import {
  ChevronDownSmallIcon,
  ChevronRightSmallIcon,
  CopyIcon,
  PauseIcon,
  PlayIcon,
  TrashCanIcon,
} from "@comma/ui/components/icons";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { Focusable } from "react-aria-components";
import { uiClock } from "@comma/ui/clock";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { copyTextToClipboard } from "../chat/thread/inline/linkActions";
import { ScreenStreamAction } from "./ScreenStreamChrome";
import {
  addLogLines,
  clearLogs,
  emptyLogBook,
  logText,
  pauseLogs,
  restartLogs,
  shortTime,
  type ScreenLogBook,
} from "./screenLogBook";

/** How long the pane waits before it reads again after its stream went: one stream a pane, so at most one try this often. */
const AGAIN_MS = [1_000, 3_000, 10_000];
/** Lines that come are drawn at most this often: a busy app says hundreds a second. */
const DRAW_MS = 100;
/** Whether the pane is open, across the panel's screens and their windows (it reads only while open). */
const OPEN_KEY = "comma.remoteScreen.logsOpen";

export type ScreenLogsState = "connecting" | "live" | "unavailable" | "stopped";

function wasOpen(): boolean {
  try {
    return globalThis.localStorage?.getItem(OPEN_KEY) !== "0";
  } catch {
    return true;
  }
}

function keepOpen(open: boolean) {
  try {
    globalThis.localStorage?.setItem(OPEN_KEY, open ? "1" : "0");
  } catch {
    // (it opens as it did before, next time)
  }
}

/**
 * A device's running app's log while `open`: one stream at a time (`devices.openScreenLogs`), read again after a wait
 * when it goes, until the pane closes or the computer says it has none.
 */
export function useScreenAppLogs(o: {
  workspace: string;
  device: string;
  screen: ListedScreen;
  open: boolean;
  mode: "app" | "all";
}) {
  const core = useCore();
  const [book, setBook] = useState<ScreenLogBook>(emptyLogBook);
  const [state, setState] = useState<ScreenLogsState>("connecting");
  const [why, setWhy] = useState<string | undefined>();
  const { workspace, device, open, mode } = o;
  const { id: screen, instance } = o.screen;
  useEffect(() => {
    if (!open) return;
    const stop = new AbortController();
    let tries = 0;
    let cancelAgain = () => {};
    // Batches as they come, drawn together.
    let waiting: { lines: ScreenLogLine[]; dropped: number } | null = null;
    let cancelDraw = () => {};
    const draw = () => {
      const batch = waiting;
      waiting = null;
      if (batch) setBook((was) => addLogLines(was, batch.lines, batch.dropped));
    };
    const onEvent = (event: ScreenLogEvent) => {
      if (stop.signal.aborted) return;
      if (event.type === "filter") {
        tries = 0;
        cancelDraw();
        waiting = null;
        setBook(restartLogs);
        setState("live");
        setWhy(undefined);
        return;
      }
      if (waiting) {
        waiting.lines.push(...event.lines);
        waiting.dropped += event.dropped ?? 0;
        return;
      }
      waiting = { lines: [...event.lines], dropped: event.dropped ?? 0 };
      cancelDraw = uiClock.after(DRAW_MS, draw);
    };
    const again = () => {
      if (stop.signal.aborted) return;
      const wait = AGAIN_MS[Math.min(tries++, AGAIN_MS.length - 1)]!;
      cancelAgain = uiClock.after(wait, start);
    };
    const start = () => {
      setState((was) => (was === "stopped" ? was : "connecting"));
      core
        .call(
          "devices.openScreenLogs",
          { workspace, device, screen, instance, mode },
          onEvent as (value: unknown) => void,
          stop.signal
        )
        .then(
          () => {
            draw();
            again();
          },
          (error: { code?: unknown; message?: unknown }) => {
            if (stop.signal.aborted) return;
            draw();
            if (error.code === "unsupported") return setState("unavailable");
            setState("stopped");
            setWhy(typeof error.message === "string" ? error.message : undefined);
            again();
          }
        );
    };
    start();
    return () => {
      stop.abort();
      cancelAgain();
      cancelDraw();
    };
  }, [core, workspace, device, screen, instance, open, mode]);
  return { book, setBook, state, why };
}

/**
 * The running app's logs under a device's picture: collapsible, its lines selectable, crashes marked. It reads only while
 * open. `App` shows the app's own lines (the apps installed on a simulator, the foreground app on Android), `All` the
 * device's; Pause holds new lines back, Clear empties it and what would be sent to a chat, Copy copies what it shows. Shown only for a device whose
 * computer lists its logs.
 */
export function ScreenAppLogs({
  workspace,
  device,
  screen,
  inert,
}: {
  workspace: string;
  device: string;
  screen: ListedScreen;
  /** Takes no press or focus for now (a frame is held over the panel). */
  inert?: boolean | undefined;
}) {
  const messages = useCommaMessages();
  const core = useCore();
  const [open, setOpen] = useState(wasOpen);
  const [mode, setMode] = useState<"app" | "all">("app");
  const { book, setBook, state, why } = useScreenAppLogs({
    workspace,
    device,
    screen,
    open,
    mode,
  });
  const toggle = (next: boolean) => {
    setOpen(next);
    keepOpen(next);
  };
  // The newest line stays in sight unless the person scrolled up to read.
  const viewport = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  useLayoutEffect(() => {
    const at = viewport.current;
    if (at && follow.current) at.scrollTop = at.scrollHeight;
  }, [book.lines, open]);
  const copy = () => {
    void copyTextToClipboard(logText(book.lines)).then(
      () => toast(messages.remote_screen_logs_copied()),
      () => undefined
    );
  };
  // In the lines' place while there are none; under them, why it stopped (it reads again meanwhile).
  const note =
    state === "unavailable"
      ? messages.remote_screen_logs_unavailable()
      : book.lines.length > 0
        ? undefined
        : state === "live"
          ? messages.remote_screen_logs_empty()
          : state === "connecting"
            ? messages.remote_screen_connecting()
            : undefined;
  const stopped =
    state === "stopped"
      ? messages.remote_screen_logs_stopped({ why: why ?? "" })
      : undefined;
  return (
    <section
      aria-label={messages.remote_screen_logs()}
      className="comma-remote-screen-logs"
      data-open={open}
      data-testid="remote-screen-logs"
      inert={inert}
    >
      <div className="comma-remote-screen-logs-bar">
        <Tooltip content={messages.remote_screen_logs()} placement="top">
          <Focusable>
            <button
              aria-expanded={open}
              className="comma-remote-screen-logs-toggle"
              onClick={() => toggle(!open)}
              type="button"
            >
              {open ? (
                <ChevronDownSmallIcon aria-hidden />
              ) : (
                <ChevronRightSmallIcon aria-hidden />
              )}
              <span>{messages.remote_screen_logs()}</span>
              {book.crashed ? (
                <Badge
                  color="error"
                  data-testid="remote-screen-logs-crashed"
                  dot
                  size="sm"
                >
                  {messages.remote_screen_logs_crashed()}
                </Badge>
              ) : null}
            </button>
          </Focusable>
        </Tooltip>
        {open && state !== "unavailable" ? (
          <div className="comma-remote-screen-action-group">
            <fieldset
              aria-label={messages.remote_screen_logs_filter()}
              className="comma-remote-screen-segments"
            >
              {(
                [
                  ["app", messages.remote_screen_logs_app()],
                  ["all", messages.remote_screen_logs_all()],
                ] as const
              ).map(([value, label]) => (
                <Tooltip key={value} content={label} placement="top">
                  <Button
                    aria-pressed={mode === value}
                    className={mode === value ? "bg-sidebar-bg-item" : ""}
                    hierarchy="tertiary-gray"
                    onPress={() => setMode(value)}
                    size="xs"
                  >
                    {label}
                  </Button>
                </Tooltip>
              ))}
            </fieldset>
            <ScreenStreamAction
              icon={book.paused ? <PlayIcon aria-hidden /> : <PauseIcon aria-hidden />}
              label={
                book.paused
                  ? messages.remote_screen_logs_resume()
                  : messages.remote_screen_logs_pause()
              }
              onClick={() => setBook((was) => pauseLogs(was, !was.paused))}
              pressed={book.paused}
            />
            <ScreenStreamAction
              icon={<TrashCanIcon aria-hidden />}
              label={messages.remote_screen_logs_clear()}
              onClick={() => {
                setBook(clearLogs);
                // What goes with the picture to a chat goes too. (If this fails, it is sent as it was.)
                core
                  .call("devices.clearScreenLogTail", {
                    workspace,
                    device,
                    screen: screen.id,
                  })
                  .catch(() => undefined);
              }}
            />
            <ScreenStreamAction
              disabled={book.lines.length === 0}
              icon={<CopyIcon aria-hidden />}
              label={messages.remote_screen_logs_copy()}
              onClick={copy}
            />
          </div>
        ) : null}
      </div>
      <Collapse open={open}>
        <CollapseContent containerClassName="comma-remote-screen-logs-body">
          <ScrollArea
            className="comma-remote-screen-logs-scroll"
            onScroll={(event) => {
              const at = event.currentTarget;
              follow.current = at.scrollHeight - at.scrollTop - at.clientHeight < 8;
            }}
            ref={viewport}
          >
            {note !== undefined ? (
              <p className="comma-remote-screen-logs-note">{note}</p>
            ) : (
              <ol className="comma-remote-screen-logs-lines">
                {book.lines.map((line) => (
                  <li
                    data-crash={line.crash ? "true" : undefined}
                    data-level={line.level.toLowerCase()}
                    key={line.seq}
                    title={line.at}
                  >
                    <span className="comma-remote-screen-logs-meta">
                      {shortTime(line.at)}{" "}
                      {line.pid !== undefined ? `${line.app}[${line.pid}]` : line.app}
                    </span>{" "}
                    {line.text}
                  </li>
                ))}
              </ol>
            )}
          </ScrollArea>
          {stopped !== undefined ? (
            <output className="comma-remote-screen-logs-held">{stopped}</output>
          ) : null}
          {book.paused && book.held.length > 0 ? (
            <p className="comma-remote-screen-logs-held">
              {messages.remote_screen_logs_held({ count: String(book.held.length) })}
            </p>
          ) : null}
          {book.dropped > 0 ? (
            <p className="comma-remote-screen-logs-held">
              {messages.remote_screen_logs_dropped({ count: String(book.dropped) })}
            </p>
          ) : null}
        </CollapseContent>
      </Collapse>
    </section>
  );
}
