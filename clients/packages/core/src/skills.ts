// A workspace's skills: the catalog (kept on the device, `doc` "skills:<workspace>"; read when shown if older than 5
// minutes, and on `skills.refresh`), and one skill's content and files, read when a page opens them.
//
// Bounds: one catalog read in flight per workspace; a skill page reads its skill once and each file it opens once.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { route } from "./api.ts";
import {
  pageSchema,
  skillDetailSchema,
  skillFileSchema,
  skillSchema,
} from "./comma/schemas.ts";
import type { Skill, SkillsValue } from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";

const FRESH_MS = 5 * 60 * 1000;
const doc = (workspace: string) => `skills:${workspace}`;
const skillsPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/skills`;

const params = {
  string(raw: unknown, name: string, max = 512): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
};

export class Skills {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #failed = new Set<string>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("skills", {
      start: (topic) =>
        this.#live.run(topic, this.#keep(topic.workspace as string, false)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#value(topic.workspace as string) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#failed.clear();
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#keep(topic.workspace as string, false));
      }
    });
    kernel.calls({
      "skills.refresh": {
        run: (p) =>
          this.#read(params.string(p, "workspace", 256), Priority.asked).pipe(
            Effect.as(null)
          ),
      },
      "skills.detail": {
        cancellable: true,
        run: (p) => {
          const workspace = params.string(p, "workspace", 256);
          const skill = params.string(p, "skill");
          return ctx.session
            .account()
            .pipe(
              Effect.flatMap((account) =>
                ctx.api.request(
                  account,
                  "GET",
                  `${skillsPath(workspace)}/${encodeURIComponent(skill)}`,
                  skillDetailSchema
                )
              )
            );
        },
      },
      "skills.file": {
        cancellable: true,
        run: (p) => {
          const workspace = params.string(p, "workspace", 256);
          const skill = params.string(p, "skill");
          const path = params.string(p, "path", 1024);
          return ctx.session
            .account()
            .pipe(
              Effect.flatMap((account) =>
                ctx.api.request(
                  account,
                  "GET",
                  `${skillsPath(workspace)}/${encodeURIComponent(skill)}/file?path=${encodeURIComponent(path)}`,
                  skillFileSchema
                )
              )
            );
        },
      },
    });
  }

  /** A workspace's skills: as kept when read in the last 5 minutes, else read now. */
  list(workspace: string): Effect.Effect<Skill[], CoreError> {
    return this.#keep(workspace, false).pipe(
      Effect.andThen(
        Effect.suspend(() => {
          const kept = this.#ctx.session.current()?.doc<Skill[]>(doc(workspace));
          return kept
            ? Effect.succeed(kept.value)
            : Effect.fail(
                new CoreError("unavailable", "The skills could not be read.")
              );
        })
      )
    );
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "skills");
  }

  #invalidate(workspace: string): void {
    for (const topic of this.#topics())
      if (topic.workspace === workspace) this.#ctx.kernel.store.invalidate(topic);
  }

  /** Reads the catalog when what is kept is older than 5 minutes (or nothing is kept). */
  #keep(workspace: string, always: boolean): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const kept = account.value.doc<Skill[]>(doc(workspace));
      if (!always && kept && this.#ctx.now() - kept.readAt < FRESH_MS) return;
      yield* this.#read(workspace, Priority.shown).pipe(Effect.ignore);
    });
  }

  #read(workspace: string, priority: number): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${doc(workspace)}`,
          priority,
          ctx.api
            .request(account, "GET", skillsPath(workspace), pageSchema(skillSchema))
            .pipe(
              Effect.tap((page) =>
                Effect.sync(() => {
                  this.#failed.delete(workspace);
                  account.putDoc(doc(workspace), page.data, ctx.now());
                  this.#invalidate(workspace);
                })
              ),
              // A failed read is not an empty catalog: it says so, and a retry reads again at once.
              Effect.tapError(() =>
                Effect.sync(() => {
                  this.#failed.add(workspace);
                  this.#invalidate(workspace);
                })
              ),
              Effect.asVoid
            )
        )
      )
    );
  }

  #value(workspace: string): SkillsValue {
    const kept = this.#ctx.session.current()?.doc<Skill[]>(doc(workspace));
    if (kept) return { status: "ready", skills: kept.value };
    return { status: this.#failed.has(workspace) ? "error" : "loading", skills: [] };
  }
}
