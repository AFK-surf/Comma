// How the view goes, from the bars in the panel's toolbar: ported from still.fail's web viewer
// (web/src/screen/ScreenPanel.tsx `NetChip`), its groups and rows: frame latency and capture to sent (the station's
// `state.latency`), frame rate and bandwidth (the frames as they come, counted over each second while it is open), the
// route, the picture's size and codec, what captures it and whether it is encoded on the hardware (`state.video`).
// Deviations: no round trip, packet loss, decode time, remote system or "copy diagnostics" (Cue's view has no such
// figures to show); a row with no figure is left out, not drawn as a dash; and the
// bars are an icon, not coloured by the round trip.
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { SignalBarsIcon } from "@comma/ui/components/icons";
import { menuSurfaceClasses } from "@comma/ui/components/menu";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
  Popover as AriaPopover,
} from "react-aria-components";
import {
  bitrateText,
  codecText,
  streamRate,
  type ScreenStreamStats as Stats,
} from "./screenStreamStats";

/** The stats as they are now and the rate over the last second, read each second while `on`. */
function useReading(read: (() => Stats) | undefined, on: boolean) {
  const [reading, setReading] = useState<{
    stats: Stats;
    rate: { fps: number; bps: number } | null;
  } | null>(null);
  const last = useRef<{
    at: number;
    frames?: number | undefined;
    bytes?: number | undefined;
  } | null>(null);
  useEffect(() => {
    last.current = null;
    if (!on || !read) {
      setReading(null);
      return undefined;
    }
    const take = () => {
      const stats = read();
      const now = uiClock.monotonic();
      const was = last.current;
      setReading({
        stats: { ...stats },
        rate: was ? streamRate(was, stats, now - was.at) : null,
      });
      last.current = { at: now, frames: stats.frames, bytes: stats.bytes };
    };
    take();
    return uiClock.every(1000, take);
  }, [read, on]);
  return reading;
}

/** The bars that open the view's figures, and the figures. `way`: the route it comes by, as the toolbar says it. */
export function ScreenStatsPanel({
  read,
  way,
}: {
  read: (() => Stats) | undefined;
  way: string | undefined;
}) {
  const messages = useCommaMessages();
  const [open, setOpen] = useState(false);
  const reading = useReading(read, open);
  const stats = reading?.stats;
  const rate = reading?.rate;
  // Only what is had: a row with nothing to say (scrcpy names no encoder) is left
  // out, rather than drawn empty.
  const groups: [string, ReactNode][][] = [
    [
      ...(stats?.latency
        ? ([
            [messages.remote_screen_stat_frame_latency(), `${stats.latency.frame} ms`],
            [messages.remote_screen_stat_before_sent(), `${stats.latency.before} ms`],
          ] as [string, ReactNode][])
        : []),
      ...(rate
        ? ([
            [messages.remote_screen_stat_fps(), String(Math.round(rate.fps))],
            [messages.remote_screen_stat_bitrate(), bitrateText(rate.bps)],
          ] as [string, ReactNode][])
        : []),
    ],
    way ? ([[messages.remote_screen_stat_path(), way]] as [string, ReactNode][]) : [],
    [
      ...(stats?.width && stats.height
        ? ([
            [messages.remote_screen_stat_picture(), `${stats.width}×${stats.height}`],
          ] as [string, ReactNode][])
        : []),
      ...(stats?.codec
        ? ([[messages.remote_screen_stat_codec(), codecText(stats.codec)]] as [
            string,
            ReactNode,
          ][])
        : []),
      ...(stats?.video?.capture
        ? ([[messages.remote_screen_stat_capture(), stats.video.capture]] as [
            string,
            ReactNode,
          ][])
        : []),
      ...(stats?.video?.hardware !== undefined
        ? ([
            [
              messages.remote_screen_stat_encoder(),
              <span key="encoder" title={stats.video.encoder}>
                {stats.video.hardware
                  ? messages.remote_screen_stat_hardware()
                  : messages.remote_screen_stat_software()}
              </span>,
            ],
          ] as [string, ReactNode][])
        : []),
    ],
  ].filter((group) => group.length > 0);
  return (
    <DialogTrigger isOpen={open} onOpenChange={setOpen}>
      <Tooltip content={messages.remote_screen_stats()} placement="bottom">
        <AriaButton
          aria-label={messages.remote_screen_stats()}
          className="comma-remote-screen-action"
          data-testid="remote-screen-stats"
          isDisabled={!read}
        >
          <SignalBarsIcon aria-hidden />
        </AriaButton>
      </Tooltip>
      <AriaPopover
        className="motion-reduce:animate-none"
        offset={4}
        placement="bottom end"
      >
        <AriaDialog
          aria-label={messages.remote_screen_stats()}
          className={cx(
            menuSurfaceClasses,
            // Its figures can be copied, also where it opens inside the panel (full screen).
            "flex w-64 flex-col gap-md p-lg outline-none select-text"
          )}
          data-testid="remote-screen-stats-panel"
        >
          <h3 className="m-0 text-sm font-semibold text-primary">
            {messages.remote_screen_stats()}
          </h3>
          {groups.map((group, i) => (
            <dl
              className={cx(
                "m-0 flex flex-col gap-xs",
                i > 0 && "border-t border-secondary pt-md"
              )}
              key={group[0]![0]}
            >
              {group.map(([name, value]) => (
                <div
                  className="flex items-baseline justify-between gap-lg text-xs"
                  key={name}
                >
                  <dt className="text-quaternary">{name}</dt>
                  <dd className="m-0 text-primary tabular-nums">{value}</dd>
                </div>
              ))}
            </dl>
          ))}
        </AriaDialog>
      </AriaPopover>
    </DialogTrigger>
  );
}
