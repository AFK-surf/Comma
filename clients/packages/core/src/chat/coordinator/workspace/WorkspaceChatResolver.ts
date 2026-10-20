import type { ChatWorkspaceResolution } from "@comma/chat-contract";
import { Effect, type Exit, Fiber } from "effect";
import { CommaApiError } from "../../api";
import type { ChatEnv } from "../../env";
import {
  StaleChatSessionError,
  type ChatSessionBoundary,
} from "../entries/sessionBoundary";

/**
 * Resolves the workspace's group chat once per session boundary, sharing a
 * resolution under way between callers. A reset cancels every resolution.
 */
export class WorkspaceChatResolver {
  readonly #openBoundary: () => ChatSessionBoundary;
  readonly #env: ChatEnv;
  #sessionEpoch = 0;
  #resolved: { key: string; value: ChatWorkspaceResolution } | undefined;
  #resolving:
    | { key: string; fiber: Fiber.Fiber<Exit.Exit<ChatWorkspaceResolution, Error>> }
    | undefined;

  constructor(openBoundary: () => ChatSessionBoundary, env: ChatEnv) {
    this.#openBoundary = openBoundary;
    this.#env = env;
  }

  /** The default workspace's chat, or with `workspaceId` that workspace's (hidden when this account has no such). */
  resolve(workspaceId?: string): Effect.Effect<ChatWorkspaceResolution, Error> {
    return Effect.suspend(() => {
      const opened = this.#openBoundary();
      opened.assertCurrent();
      const boundary = { ...opened, key: `${opened.key}\u0000${workspaceId ?? ""}` };
      if (
        this.#resolved?.key === boundary.key &&
        this.#resolved.value.status === "ready"
      ) {
        boundary.assertCurrent();
        return Effect.succeed(this.#resolved.value);
      }
      if (this.#resolving?.key === boundary.key)
        return Fiber.join(this.#resolving.fiber).pipe(Effect.flatten);
      // One resolution for every caller: it runs on its own, and is let go once it ends. Its failure (offline, a
      // session that changed) is its callers' answer, not a bug of the core's.
      const resolving = {
        key: boundary.key,
        fiber: this.#env.runner.fork(
          Effect.exit(this.#resolve(this.#sessionEpoch, boundary, workspaceId))
        ),
      };
      this.#resolving = resolving;
      return Fiber.join(resolving.fiber).pipe(
        Effect.flatten,
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#resolving === resolving) this.#resolving = undefined;
          })
        )
      );
    });
  }

  reset() {
    this.#sessionEpoch += 1;
    this.#resolved = undefined;
    this.#resolving = undefined;
  }

  #resolve(
    sessionEpoch: number,
    boundary: ChatSessionBoundary,
    workspaceId: string | undefined
  ): Effect.Effect<ChatWorkspaceResolution, Error> {
    return Effect.gen({ self: this }, function* () {
      boundary.assertCurrent();
      const api = boundary.api;
      if (workspaceId) {
        const workspace = (yield* api.listWorkspaces).find(
          (candidate) => candidate.id === workspaceId
        );
        this.#assertCurrentSession(sessionEpoch, boundary);
        if (!workspace) return { status: "hidden" } as const;
        return yield* this.#ready(sessionEpoch, boundary, workspace);
      }
      const bootstrap = yield* api.bootstrapWorkspace;
      this.#assertCurrentSession(sessionEpoch, boundary);

      if (bootstrap.status === "provisioning") {
        const result: ChatWorkspaceResolution = {
          groupId: bootstrap.workspace.group_id,
          retryAfterSeconds: bootstrap.retry_after_seconds,
          status: "provisioning",
          workspaceId: bootstrap.workspace.id,
        };
        boundary.assertCurrent();
        return result;
      }

      return yield* this.#ready(sessionEpoch, boundary, bootstrap.workspace);
    }).pipe(
      Effect.catch((error: Error) =>
        Effect.suspend((): Effect.Effect<ChatWorkspaceResolution, Error> => {
          this.#assertCurrentSession(sessionEpoch, boundary);
          if (error instanceof CommaApiError && error.status === 401)
            return Effect.succeed({ status: "unauthorized" });
          if (
            error instanceof CommaApiError &&
            (error.status === 403 || error.status === 404)
          )
            return Effect.succeed({ status: "hidden" });
          return Effect.fail(error);
        })
      )
    );
  }

  /** The workspace's group chat, made when there is none yet. */
  #ready(
    sessionEpoch: number,
    boundary: ChatSessionBoundary,
    workspace: { id: string; group_id: string }
  ): Effect.Effect<ChatWorkspaceResolution, Error> {
    return boundary.api.ensureGroupChat(workspace.group_id).pipe(
      Effect.map((conversation) => {
        this.#assertCurrentSession(sessionEpoch, boundary);
        const resolution: ChatWorkspaceResolution = {
          conversationId: conversation.id,
          ...(conversation.created_at === undefined
            ? {}
            : { createdAt: conversation.created_at }),
          groupId: workspace.group_id,
          status: "ready",
          ...(conversation.updated_at === undefined
            ? {}
            : { updatedAt: conversation.updated_at }),
          workspaceId: workspace.id,
        };
        this.#resolved = { key: boundary.key, value: resolution };
        boundary.assertCurrent();
        return resolution;
      })
    );
  }

  #assertCurrentSession(sessionEpoch: number, boundary: ChatSessionBoundary) {
    boundary.assertCurrent();
    if (sessionEpoch !== this.#sessionEpoch) {
      throw new StaleChatSessionError();
    }
  }
}
