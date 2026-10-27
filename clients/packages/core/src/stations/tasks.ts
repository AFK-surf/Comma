// Tasks a station hosts, made and moved from here: what a new Task can run on (`stations.profiles`, the station's
// profiles and their models), a new Task with its first message (`stations.newTask`), and what its list and page do to
// it (`StationTaskActions`): its status set by a person, its labels (kept by the station) and its name. A Task is the station's
// own chat: it is read and written as any chat is (chat.ts), and the workspace lists it from the Task index
// (../station-tasks.ts). The same changes made to it as to any Task (conversation.ts) come here too.
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
import { attachmentsOf, type ChatAt, type StationChats } from "./chat.ts";
import { hostedId, type StationTasks } from "../station-tasks.ts";
import type { Stations } from "./index.ts";
import { madeSchema } from "./station-api.ts";

const name = z.string().max(4_096);

/** The profiles a new Task can run on (`GET /overview`'s `profiles`), with their models. */
const profilesSchema = z.object({
  profiles: z
    .array(
      z.object({
        id: name,
        machine: z.boolean().optional(),
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
};

/** What is changed of a Task a station hosts, on its station. */
export interface StationTaskActions {
  setStatus(
    at: ChatAt,
    status: StationTaskMark
  ): Effect.Effect<{ status: string }, CoreError>;
  setLabels(
    at: ChatAt,
    labels: string[]
  ): Effect.Effect<{ labels: string[] }, CoreError>;
  /** Names the Task (its chat), at most 200 characters. */
  rename(at: ChatAt, title: string): Effect.Effect<void, CoreError>;
  /**
   * Archives the Task's chat on its station (`archived`), or takes it out of the archive: every list shows it so at
   * once, and again as it was when the station refused. Out of the archive it is at work until its station says how it
   * stands (its Task index).
   */
  archive(at: ChatAt, archived: boolean): Effect.Effect<void, CoreError>;
  /**
   * Runs the Task on `station`, another station, with `runtime` and `model` (null: the runtime's default there): its
   * Session there takes it up (`POST /threads/:id/run`). Without `station`, on its own station again, with them. Its
   * station refuses what cannot run (a station offline, a model it lacks), and it runs as it did.
   */
  runOn(
    at: ChatAt,
    run: { station?: string; runtime?: string; model: string | null }
  ): Effect.Effect<void, CoreError>;
  /**
   * Runs the Task's session with `runtime` (unchanged when absent) on `model` from its next turn (null: the runtime's
   * default there). Another runtime goes on afresh there, its past read back.
   */
  setRun(
    at: ChatAt,
    session: string,
    run: { runtime?: string; model: string | null }
  ): Effect.Effect<void, CoreError>;
}

export function stationTaskCalls(
  ctx: Ctx,
  stations: Stations,
  chats: StationChats,
  stationTasks: StationTasks
): StationTaskActions {
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

  const actions: StationTaskActions = {
    setStatus: (at, status) =>
      reached(
        stations.ask(
          at.workspace,
          at.station,
          "PUT",
          route`/threads/${String(at.thread)}/status`,
          {
            status,
          }
        ),
        at.station
      ).pipe(
        Effect.map((answer) => {
          const said = (answer as { status?: unknown } | null)?.status;
          const kept = typeof said === "string" ? said : status;
          stationTasks.keepStatus(at.station, String(at.thread), kept);
          return { status: kept };
        })
      ),
    setLabels: (at, labels) =>
      reached(
        stations.ask(
          at.workspace,
          at.station,
          "PUT",
          route`/threads/${String(at.thread)}/labels`,
          {
            labels,
          }
        ),
        at.station
      ).pipe(
        Effect.map((answer) => {
          const said = (answer as { labels?: unknown } | null)?.labels;
          const kept = Array.isArray(said)
            ? said.filter((id): id is string => typeof id === "string")
            : labels;
          stationTasks.keepLabels(at.station, String(at.thread), kept);
          return { labels: kept };
        })
      ),
    rename: (at, title) =>
      reached(
        stations.ask(
          at.workspace,
          at.station,
          "PUT",
          route`/threads/${String(at.thread)}/title`,
          {
            title,
          }
        ),
        at.station
      ).pipe(
        Effect.tap(() =>
          Effect.sync(() =>
            stationTasks.keepTitle(at.station, String(at.thread), title)
          )
        ),
        Effect.asVoid
      ),
    runOn: (at, run) =>
      reached(
        stations.ask(
          at.workspace,
          at.station,
          "POST",
          `${route`/threads/${String(at.thread)}`}/run`,
          run
        ),
        at.station
      ).pipe(
        Effect.tap(() => Effect.sync(() => chats.refresh(at))),
        Effect.asVoid
      ),
    setRun: (at, session, run) =>
      reached(
        stations.ask(
          at.workspace,
          at.station,
          "POST",
          `${route`/sessions/${session}`}/settings`,
          run.runtime === undefined
            ? { model: run.model }
            : { runtime: run.runtime, model: run.model }
        ),
        at.station
      ).pipe(
        Effect.tap(() =>
          Effect.sync(() => stationTasks.keepRun(at.station, String(at.thread), run))
        ),
        Effect.asVoid
      ),
    archive: (at, archived) =>
      Effect.suspend(() => {
        const account = ctx.session.current();
        const id = hostedId(at.station, at.thread);
        const was = account
          ? stationTasks.task(account, at.workspace, id)?.status
          : undefined;
        stationTasks.keepStatus(
          at.station,
          String(at.thread),
          archived ? "archived" : "in_progress"
        );
        return reached(
          stations.ask(
            at.workspace,
            at.station,
            archived ? "POST" : "DELETE",
            route`/threads/${String(at.thread)}/archive`
          ),
          at.station
        ).pipe(
          Effect.tapError(() =>
            Effect.sync(() => {
              if (was !== undefined)
                stationTasks.keepStatus(at.station, String(at.thread), was);
            })
          ),
          Effect.asVoid
        );
      }),
  };

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
        if (text.length > 100_000) throw CoreError.invalid("text is too long");
        // Files the station has already (`stations.upload`) go with the first message, which may be them alone.
        const attachments = attachmentsOf(raw.attachments);
        if (text === "" && attachments.length === 0)
          throw CoreError.invalid("text is required");
        return Effect.gen(function* () {
          const group = yield* stationTasks.group(workspace);
          const answer = yield* reached(
            stations.ask(
              workspace,
              station,
              "POST",
              "/sessions",
              { runtime, profile, model, effort, title, clientKey: key },
              { onceKey: `task:${key}` }
            ),
            station
          );
          return { group, answer };
        }).pipe(
          Effect.flatMap(({ group, answer }) => {
            const made = madeSchema.safeParse(answer);
            if (!made.success)
              return Effect.fail(
                new CoreError("bad_response", "The station made no Task.")
              );
            const thread = made.data.thread.id;
            return chats
              .post({ workspace, station, thread }, text, `first:${key}`, attachments)
              .pipe(
                Effect.as({
                  session: made.data.key,
                  thread,
                  groupId: group,
                  conversationId: hostedId(station, thread),
                })
              );
          })
        );
      },
    },
  });
  return actions;
}
