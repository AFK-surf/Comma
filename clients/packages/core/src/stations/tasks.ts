// Tasks a station hosts, made and moved from here: what a new Task can run on (`stations.profiles`, the station's
// profiles and their models), a new Task with its first message (`stations.newTask`), its status set by a person
// (`stations.setStatus`) and its labels (`stations.setLabels`, kept by the station). A Task is the station's own chat:
// it is read and written as any chat is (chat.ts), and the workspace lists it from the Task index (../station-tasks.ts).
//
// A new Task is made once per `key`: the station answers the same `POST /sessions` again with the chat it made (its
// writes are kept by key for 10 minutes), and the first message is put in the chat's outbox once, under a key made
// from it. So a call that failed is made again with the same key.
//
// Bounds: one request per call, two for a new Task (its chat, then its first message, which the outbox sends).
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "../api.ts";
import type { StationProfile, StationTaskMark } from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import type { StationChats } from "./chat.ts";
import type { StationTasks } from "../station-tasks.ts";
import type { Stations } from "./index.ts";
import { madeSchema } from "./station-api.ts";

const name = z.string().max(4_096);

/** The profiles a new Task can run on (`GET /overview`'s `profiles`), with their models. */
const profilesSchema = z.object({
  profiles: z
    .array(
      z.object({
        id: name,
        name: name.nullish(),
        runtime: name.nullish(),
        runtimes: z.array(name).max(16).optional(),
        model: name.nullish(),
        models: z.array(name).max(200).nullish(),
      })
    )
    .max(200)
    .default([]),
});

/** The most labels a Task carries (its station keeps at most these). */
const LABELS_MAX = 20;

const MARKS = new Set<string>(["done", "cancelled", "in_progress"]);

const params = {
  text(raw: unknown, key: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[key];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${key} is required`);
    return v;
  },
  optional(raw: unknown, key: string, max = 256): string | undefined {
    const v = (raw as Record<string, unknown> | null)?.[key];
    if (v === undefined || v === null || v === "") return undefined;
    if (typeof v !== "string" || v.length > max)
      throw CoreError.invalid(`${key} is at most ${max} characters`);
    return v;
  },
  thread(raw: unknown): number {
    const v = (raw as Record<string, unknown> | null)?.thread;
    if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0)
      throw CoreError.invalid("thread is required");
    return v;
  },
};

export function stationTaskCalls(
  ctx: Ctx,
  stations: Stations,
  chats: StationChats,
  stationTasks: StationTasks
): void {
  /** A request the station could not be reached for: the machine is offline (made again, it is made once). */
  const reached = <A>(work: Effect.Effect<A, CoreError>, station: string) =>
    Effect.suspend(() => {
      const link = stations.linkOf(station);
      if (link.state === "offline")
        return Effect.fail(
          new CoreError("machine_offline", link.message ?? "The machine is offline.")
        );
      return work.pipe(
        Effect.mapError((e) =>
          e.code === "unreachable" || e.code === "timeout"
            ? new CoreError("machine_offline", e.message)
            : e
        )
      );
    });

  ctx.kernel.calls({
    "stations.profiles": {
      run: (p) => {
        const workspace = params.text(p, "workspace");
        const station = params.text(p, "station");
        return reached(
          stations.ask(workspace, station, "GET", "/overview"),
          station
        ).pipe(
          Effect.flatMap((answer) => {
            const read = profilesSchema.safeParse(answer);
            if (!read.success)
              return Effect.fail(
                new CoreError("bad_response", "The station answered unexpectedly.")
              );
            return Effect.succeed(
              read.data.profiles.map(
                (profile): StationProfile => ({
                  id: profile.id,
                  name: profile.name || profile.id,
                  runtimes:
                    profile.runtimes ?? (profile.runtime ? [profile.runtime] : []),
                  model: profile.model ?? null,
                  models: profile.models ?? [],
                })
              )
            );
          })
        );
      },
    },
    "stations.newTask": {
      doing: true,
      run: (p) => {
        const workspace = params.text(p, "workspace");
        const station = params.text(p, "station");
        const key = params.text(p, "key", 120);
        const runtime = params.text(p, "runtime", 64);
        const profile = params.optional(p, "profile");
        const model = params.optional(p, "model");
        const effort = params.optional(p, "effort", 64);
        const title = params.optional(p, "title", 120);
        const raw = (p ?? {}) as Record<string, unknown>;
        const text = typeof raw.text === "string" ? raw.text.trim() : "";
        if (text === "") throw CoreError.invalid("text is required");
        if (text.length > 100_000) throw CoreError.invalid("text is too long");
        return reached(
          stations.ask(
            workspace,
            station,
            "POST",
            "/sessions",
            { runtime, profile, model, effort, title, clientKey: key },
            { onceKey: `task:${key}` }
          ),
          station
        ).pipe(
          Effect.flatMap((answer) => {
            const made = madeSchema.safeParse(answer);
            if (!made.success)
              return Effect.fail(
                new CoreError("bad_response", "The station made no Task.")
              );
            const thread = made.data.thread.id;
            return chats
              .post({ workspace, station, thread }, text, `first:${key}`)
              .pipe(Effect.as({ session: made.data.key, thread }));
          })
        );
      },
    },
    "stations.setLabels": {
      doing: true,
      run: (p) => {
        const workspace = params.text(p, "workspace");
        const station = params.text(p, "station");
        const thread = params.thread(p);
        const labels = (p as { labels?: unknown } | null)?.labels;
        if (
          !Array.isArray(labels) ||
          labels.length > LABELS_MAX ||
          !labels.every((id) => typeof id === "string" && id !== "" && id.length <= 128)
        )
          throw CoreError.invalid(`labels are at most ${LABELS_MAX} label ids`);
        return reached(
          stations.ask(
            workspace,
            station,
            "PUT",
            route`/threads/${String(thread)}/labels`,
            { labels }
          ),
          station
        ).pipe(
          Effect.map((answer) => {
            const said = (answer as { labels?: unknown } | null)?.labels;
            const kept = Array.isArray(said)
              ? said.filter((id): id is string => typeof id === "string")
              : (labels as string[]);
            stationTasks.keepLabels(station, String(thread), kept);
            return { labels: kept };
          })
        );
      },
    },
    "stations.setStatus": {
      doing: true,
      run: (p) => {
        const workspace = params.text(p, "workspace");
        const station = params.text(p, "station");
        const thread = params.thread(p);
        const status = params.text(p, "status", 32) as StationTaskMark;
        if (!MARKS.has(status))
          throw CoreError.invalid("status is done, cancelled or in_progress");
        return reached(
          stations.ask(
            workspace,
            station,
            "PUT",
            route`/threads/${String(thread)}/status`,
            { status }
          ),
          station
        ).pipe(
          Effect.map((answer) => {
            const said = (answer as { status?: unknown } | null)?.status;
            return { status: typeof said === "string" ? said : status };
          })
        );
      },
    },
  });
}
