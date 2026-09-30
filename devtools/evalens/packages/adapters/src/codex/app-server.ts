import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { Trajectory } from "@evalens/core/message";
import type { JSONType } from "zod";
import { z } from "zod";

import { CodexCliAdapterConfig } from "./config";
import type { Codex } from "./types";

type JsonObject = Record<string, JSONType>;

const JsonObjectSchema = z.record(z.string(), z.json());
const CodexThreadStatusSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("notLoaded") }).passthrough(),
  z.object({ type: z.literal("idle") }).passthrough(),
  z.object({ type: z.literal("systemError") }).passthrough(),
  z
    .object({
      type: z.literal("active"),
      activeFlags: z.array(z.json()),
    })
    .passthrough(),
]);
const CodexTurnStatusSchema = z.enum([
  "completed",
  "interrupted",
  "failed",
  "inProgress",
]);
const CodexThreadItemSchema = JsonObjectSchema;
const CodexTurnSchema = z
  .object({
    id: z.string().min(1),
    items: z.array(CodexThreadItemSchema),
    status: CodexTurnStatusSchema,
    error: z.json().nullable().optional(),
    startedAt: z.number().nullable().optional(),
    completedAt: z.number().nullable().optional(),
  })
  .passthrough();
const CodexThreadSchema = z
  .object({
    id: z.string().min(1),
    sessionId: z.string().min(1).optional(),
    parentThreadId: z.string().min(1).nullable().optional(),
    forkedFromId: z.string().min(1).nullable().optional(),
    createdAt: z.number().optional(),
    model: z.string().min(1).nullable().optional(),
    status: CodexThreadStatusSchema.optional(),
    cwd: z.string().optional(),
    agentNickname: z.string().nullable().optional(),
    agentRole: z.string().nullable().optional(),
    turns: z.array(CodexTurnSchema).optional(),
  })
  .passthrough();
const ThreadStartResponseSchema = z.object({ thread: CodexThreadSchema }).strip();
const ThreadReadResponseSchema = z.object({ thread: CodexThreadSchema }).strip();
const ThreadListResponseSchema = z
  .object({
    data: z.array(CodexThreadSchema),
    nextCursor: z.string().nullable().optional(),
  })
  .strip();
const TurnStartResponseSchema = z
  .object({
    turn: z.object({ id: z.string().min(1) }).passthrough(),
  })
  .strip();
const CollabAgentStateSchema = z
  .object({
    status: z.string().min(1),
    message: z.string().nullable().optional(),
  })
  .strip();
const CollabToolCallItemSchema = z
  .object({
    type: z.literal("collabAgentToolCall"),
    id: z.string().min(1),
    tool: z.string().min(1),
    status: z.string().min(1),
    senderThreadId: z.string().min(1),
    receiverThreadIds: z.array(z.string().min(1)).optional(),
    receiverThreadId: z.string().min(1).optional(),
    newThreadId: z.string().min(1).optional(),
    prompt: z.string().nullable().optional(),
    model: z.string().nullable().optional(),
    reasoningEffort: z.string().nullable().optional(),
    agentsStates: z.record(z.string(), CollabAgentStateSchema).optional(),
    agentStatus: z.string().nullable().optional(),
  })
  .strip();
const CollabItemNotificationSchema = z
  .object({
    method: z.enum(["item/started", "item/completed"]),
    params: z
      .object({
        threadId: z.string().min(1),
        turnId: z.string().min(1),
        item: CollabToolCallItemSchema,
      })
      .strip(),
  })
  .strip();

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
};

type NotificationWaiter = {
  predicate: (message: JsonObject) => boolean;
  resolve: (message: JsonObject) => void;
  reject: (reason: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

export type CodexAppServerHistoryItem = JsonObject;

export type CodexAppServerThread = {
  threadId: string;
  workspaceDir: string;
};

export type CodexAppServerThreadRecord = z.infer<typeof CodexThreadSchema>;

type CodexAppServerThreadPage = {
  data: CodexAppServerThreadRecord[];
  nextCursor: string | null;
};

export type CodexAppServerThreadTreeObservation = {
  settled: boolean;
  activeThreadIds: string[];
  systemErrorThreadIds: string[];
  unknownStatusThreadIds: string[];
  threads: CodexAppServerThreadRecord[];
  trajectories: Trajectory[];
};

export type CodexAppServerThreadStartInput = {
  workspaceDir?: string;
  model?: string;
  reasoningEffort?: string;
  baseInstructions?: string;
  developerInstructions?: string;
  sandbox?: Codex.Sandbox;
  approvalPolicy?: Codex.ApprovalPolicy;
  ephemeral?: boolean;
  configOverrides?: Record<string, JSONType>;
  dynamicTools?: JSONType[];
  environments?: JSONType[];
};

type CodexAppServerThreadListInput = {
  cursor?: string;
  ancestorThreadId?: string;
};

export type CodexAppServerCollaborationEvent = {
  lifecycle: "started" | "completed";
  threadId: string;
  turnId: string;
  id: string;
  tool: string;
  status: string;
  senderThreadId: string;
  receiverThreadIds: string[];
  prompt?: string;
  model?: string;
  reasoningEffort?: string;
  agentsStates: Record<string, { status: string; message?: string | null }>;
};

export type CodexAppServerTokenUsage = {
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
};

export type CodexAppServerTurnResult = {
  threadId: string;
  turnId: string;
  answer: string;
  trajectory: Trajectory;
  startedAt: Date;
  finishedAt: Date;
  durationMs: number;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  aggregateInputTokens: number;
  aggregateOutputTokens: number;
  aggregateTotalTokens: number;
  usageByThread: Record<string, CodexAppServerTokenUsage>;
  collaborationEvents: CodexAppServerCollaborationEvent[];
  events: JsonObject[];
  timedOut: boolean;
};

export class CodexAppServerNotificationTimeoutError extends Error {
  constructor(readonly timeoutMs: number) {
    super(`Codex app-server notification timed out after ${timeoutMs}ms`);
    this.name = "CodexAppServerNotificationTimeoutError";
  }
}

export type CodexAppServerOptions = Codex.CliAdapterOptions & {
  requestTimeoutMs?: number;
  trajectoryHistoryMode?: "full" | "digest";
};

type ThreadTrajectory = {
  model?: string;
  steps: Trajectory["steps"];
};

/**
 * Minimal newline-delimited app-server client for controlled history experiments.
 *
 * Each adapter instance owns exactly one Codex process. Experiments should create
 * one instance per causal branch so process and thread state cannot cross branches.
 */
export class CodexAppServerAdapter {
  private readonly config: CodexCliAdapterConfig;
  private readonly requestTimeoutMs: number;
  private readonly trajectoryHistoryMode: "full" | "digest";
  private readonly rootPromise: Promise<string>;
  private process?: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private nextId = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly waiters = new Set<NotificationWaiter>();
  private readonly threadTrajectories = new Map<string, ThreadTrajectory>();
  private readonly events: JsonObject[] = [];
  private stderr = "";
  private closed = false;
  private initialized?: Promise<void>;

  constructor(options: CodexAppServerOptions = {}) {
    const {
      requestTimeoutMs = 60_000,
      trajectoryHistoryMode = "full",
      ...adapterOptions
    } = options;
    this.config = CodexCliAdapterConfig.parse(adapterOptions);
    this.requestTimeoutMs = requestTimeoutMs;
    this.trajectoryHistoryMode = trajectoryHistoryMode;
    this.rootPromise = mkdtemp(path.join(os.tmpdir(), "evalens-codex-app-server-"));
  }

  async startThread(
    input: CodexAppServerThreadStartInput
  ): Promise<CodexAppServerThread> {
    await this.ensureInitialized();
    const root = await this.rootPromise;
    const workspaceDir = path.resolve(
      input.workspaceDir ?? path.join(root, `workspace-${this.nextId}`)
    );
    await mkdir(workspaceDir, { recursive: true });
    const configOverrides = z
      .record(z.string(), z.json())
      .parse(input.configOverrides ?? {});
    const response = ThreadStartResponseSchema.parse(
      await this.request("thread/start", {
        cwd: workspaceDir,
        model: input.model ?? this.config.model ?? null,
        approvalPolicy: input.approvalPolicy ?? this.config.approvalPolicy,
        sandbox: input.sandbox ?? this.config.sandbox,
        ephemeral: input.ephemeral ?? this.config.ephemeral,
        dynamicTools: z.array(z.json()).parse(input.dynamicTools ?? []),
        ...(input.environments === undefined
          ? {}
          : { environments: z.array(z.json()).parse(input.environments) }),
        baseInstructions: input.baseInstructions ?? null,
        developerInstructions: input.developerInstructions ?? null,
        config: {
          ...configOverrides,
          model_reasoning_effort:
            input.reasoningEffort ??
            configOverrides["model_reasoning_effort"] ??
            "medium",
        },
      })
    );
    const threadId = response.thread.id;
    this.threadTrajectories.set(threadId, {
      model: input.model ?? this.config.model,
      steps: [],
    });
    return { threadId, workspaceDir };
  }

  async injectItems(
    threadId: string,
    items: readonly CodexAppServerHistoryItem[]
  ): Promise<void> {
    await this.ensureInitialized();
    await this.request("thread/inject_items", { threadId, items: [...items] });
    const trajectory = this.requireThreadTrajectory(threadId);
    const timestamp = new Date();
    for (const item of items) {
      trajectory.steps.push(
        ...historyItemToTrajectorySteps(
          item,
          trajectory.model,
          timestamp,
          this.trajectoryHistoryMode
        )
      );
    }
  }

  async compactThread(threadId: string, timeoutMs = 300_000): Promise<void> {
    await this.ensureInitialized();
    const startIndex = this.events.length;
    const completion = this.waitForNotification(
      (message) =>
        message.method === "turn/completed" &&
        asOptionalString(asOptionalObject(message.params)?.threadId) === threadId,
      timeoutMs,
      startIndex
    );
    await this.request("thread/compact/start", { threadId });
    const event = await completion;
    assertCompletedTurn(event, "Codex compaction");
  }

  async runTurn(input: {
    threadId: string;
    message: string;
    model?: string;
    reasoningEffort?: string;
    approvalPolicy?: Codex.ApprovalPolicy;
    environments?: JSONType[];
    outputSchema?: JSONType;
    collaborationMode?: JSONType;
    timeoutMs?: number;
    returnOnTimeout?: boolean;
  }): Promise<CodexAppServerTurnResult> {
    await this.ensureInitialized();
    const startIndex = this.events.length;
    const startedAtDate = new Date();
    const startedAt = performance.now();
    const response = TurnStartResponseSchema.parse(
      await this.request("turn/start", {
        threadId: input.threadId,
        input: [{ type: "text", text: input.message }],
        model: input.model ?? this.config.model ?? null,
        effort: input.reasoningEffort ?? null,
        approvalPolicy: input.approvalPolicy ?? this.config.approvalPolicy,
        ...(input.environments === undefined
          ? {}
          : { environments: z.array(z.json()).parse(input.environments) }),
        outputSchema:
          input.outputSchema === undefined ? null : z.json().parse(input.outputSchema),
        collaborationMode:
          input.collaborationMode === undefined
            ? null
            : z.json().parse(input.collaborationMode),
      })
    );
    const turnId = response.turn.id;
    let completed: JsonObject | undefined;
    let timedOut = false;
    try {
      completed = await this.waitForNotification(
        (message) => {
          if (message.method !== "turn/completed") return false;
          const params = asOptionalObject(message.params);
          return (
            asOptionalString(params?.threadId) === input.threadId &&
            asOptionalString(asOptionalObject(params?.turn)?.id) === turnId
          );
        },
        input.timeoutMs ?? 900_000,
        startIndex
      );
      assertCompletedTurn(completed, "Codex turn");
    } catch (error) {
      if (
        input.returnOnTimeout !== true ||
        !(error instanceof CodexAppServerNotificationTimeoutError)
      ) {
        throw error;
      }
      timedOut = true;
    }

    const branchEvents = this.events.slice(startIndex);
    const answer = latestFinalAnswer(branchEvents, input.threadId, turnId);
    const usage = latestTokenUsage(branchEvents, input.threadId);
    const usageByThread = latestTokenUsageByThread(branchEvents);
    const aggregateUsage = sumTokenUsage(Object.values(usageByThread));
    const completedTurn = completed ? asObject(asObject(completed.params).turn) : {};
    const finishedAt = new Date();
    const trajectory = this.createTrajectory({
      threadId: input.threadId,
      turnId,
      message: input.message,
      answer,
      model: input.model,
      startedAt: startedAtDate,
      finishedAt,
    });
    const threadTrajectory = this.requireThreadTrajectory(input.threadId);
    threadTrajectory.model = input.model ?? threadTrajectory.model;
    threadTrajectory.steps = trajectory.steps.map((step) => ({ ...step }));
    return {
      threadId: input.threadId,
      turnId,
      answer,
      trajectory,
      startedAt: startedAtDate,
      finishedAt,
      durationMs:
        asOptionalNumber(completedTurn.durationMs) ??
        Math.max(0, Math.round(performance.now() - startedAt)),
      ...usage,
      aggregateInputTokens: aggregateUsage.inputTokens,
      aggregateOutputTokens: aggregateUsage.outputTokens,
      aggregateTotalTokens: aggregateUsage.totalTokens,
      usageByThread,
      collaborationEvents: collaborationEvents(branchEvents),
      events: branchEvents,
      timedOut,
    };
  }

  private async readThread(
    threadId: string,
    includeTurns = true
  ): Promise<CodexAppServerThreadRecord> {
    await this.ensureInitialized();
    const response = ThreadReadResponseSchema.parse(
      await this.request("thread/read", { threadId, includeTurns })
    );
    return response.thread;
  }

  private async listThreads(
    input: CodexAppServerThreadListInput = {}
  ): Promise<CodexAppServerThreadPage> {
    await this.ensureInitialized();
    const response = ThreadListResponseSchema.parse(
      await this.request("thread/list", {
        cursor: input.cursor ?? null,
        limit: 100,
        parentThreadId: null,
        ancestorThreadId: input.ancestorThreadId ?? null,
        archived: false,
      })
    );
    return {
      data: response.data,
      nextCursor: response.nextCursor ?? null,
    };
  }

  private async listDescendantThreads(
    ancestorThreadId: string
  ): Promise<CodexAppServerThreadRecord[]> {
    const descendants: CodexAppServerThreadRecord[] = [];
    let cursor: string | undefined;
    const seenCursors = new Set<string>();
    let hasNextPage = true;
    while (hasNextPage) {
      const page = await this.listThreads({ ancestorThreadId, cursor });
      descendants.push(...page.data);
      if (!page.nextCursor) {
        hasNextPage = false;
        continue;
      }
      if (seenCursors.has(page.nextCursor)) {
        throw new Error("Codex thread/list returned a repeated pagination cursor");
      }
      seenCursors.add(page.nextCursor);
      cursor = page.nextCursor;
    }
    return descendants;
  }

  private async readThreadTree(
    rootThreadId: string,
    includeTurns = true
  ): Promise<CodexAppServerThreadRecord[]> {
    const [root, listedDescendants] = await Promise.all([
      this.readThread(rootThreadId, includeTurns),
      this.listDescendantThreads(rootThreadId),
    ]);
    const candidatesById = new Map(
      listedDescendants.map((thread) => [thread.id, thread] as const)
    );
    for (const thread of eventDescendantThreads(rootThreadId, this.events)) {
      if (thread.id !== rootThreadId) candidatesById.set(thread.id, thread);
    }
    const descendants = [...candidatesById.values()];
    const detailedDescendants = includeTurns
      ? await Promise.all(
          descendants.map((thread) =>
            thread.turns ? thread : this.readThread(thread.id, true)
          )
        )
      : descendants;
    return [root, ...detailedDescendants];
  }

  /**
   * Reads the current state of a native Codex collaboration tree without
   * sending input to, interrupting, or otherwise scheduling any agent.
   */
  async observeThreadTree(
    rootThreadId: string,
    includeTurns = true
  ): Promise<CodexAppServerThreadTreeObservation> {
    const threads = await this.readThreadTree(rootThreadId, includeTurns);
    return threadTreeObservation(threads, includeTurns);
  }

  async deleteThread(threadId: string): Promise<void> {
    await this.ensureInitialized();
    await this.request("thread/delete", { threadId });
  }

  createTrajectory(input: {
    threadId: string;
    turnId: string;
    message?: string;
    answer?: string;
    failure?: string;
    model?: string;
    startedAt: Date;
    finishedAt: Date;
  }): Trajectory {
    const thread = this.requireThreadTrajectory(input.threadId);
    const steps: Trajectory["steps"] = thread.steps.map((step) => ({ ...step }));
    if (input.message !== undefined) {
      steps.push({
        type: "user",
        content: input.message,
        timestamp: input.startedAt,
      });
    }
    if (input.answer !== undefined) {
      steps.push({
        type: "assistant",
        content: input.answer,
        model: input.model ?? thread.model,
        timestamp: input.finishedAt,
      });
    } else if (input.failure !== undefined) {
      steps.push({
        type: "system",
        content: `Branch execution failed: ${input.failure}`,
        timestamp: input.finishedAt,
      });
    }
    return { id: `${input.threadId}:${input.turnId}`, steps };
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    const process = this.process;
    if (process) {
      process.stdin.end();
      process.kill();
      await process.exited.catch(() => undefined);
    }
    const error = new Error("Codex app-server adapter closed");
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    this.waiters.clear();
    this.threadTrajectories.clear();
    await rm(await this.rootPromise, { recursive: true, force: true });
  }

  private async ensureInitialized(): Promise<void> {
    if (this.initialized) return this.initialized;
    this.initialized = this.initialize();
    return this.initialized;
  }

  private async initialize(): Promise<void> {
    if (this.closed) throw new Error("Codex app-server adapter is closed");
    const root = await this.rootPromise;
    const command = ["/usr/bin/env", this.config.command, "app-server", "--stdio"];
    this.process = Bun.spawn({
      cmd: command,
      cwd: root,
      env: { ...process.env, ...this.config.env },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    void this.readStdout(this.process.stdout);
    void this.readStderr(this.process.stderr);
    void this.observeExit(this.process);
    await this.request("initialize", {
      clientInfo: { name: "evalens", title: "Evalens", version: "1" },
      capabilities: { experimentalApi: true },
    });
    this.notify("initialized", {});
  }

  private async request(method: string, params: JsonObject): Promise<unknown> {
    if (!this.process) {
      if (method !== "initialize") await this.ensureInitialized();
      if (!this.process) throw new Error("Codex app-server process did not start");
    }
    const id = this.nextId++;
    const response = new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new Error(
            `Codex app-server ${method} timed out after ${this.requestTimeoutMs}ms`
          )
        );
      }, this.requestTimeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timeout);
          resolve(value);
        },
        reject: (reason) => {
          clearTimeout(timeout);
          reject(reason);
        },
      });
    });
    this.write({ id, method, params });
    return response;
  }

  private notify(method: string, params: JsonObject): void {
    this.write({ method, params });
  }

  private write(message: JsonObject): void {
    if (!this.process) throw new Error("Codex app-server process is unavailable");
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
    this.process.stdin.flush();
  }

  private async readStdout(stream: ReadableStream<Uint8Array>): Promise<void> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        while (true) {
          const newline = buffer.indexOf("\n");
          if (newline < 0) break;
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line) this.receive(parseMessage(line));
        }
      }
      buffer += decoder.decode();
      const tail = buffer.trim();
      if (tail) this.receive(parseMessage(tail));
    } catch (error) {
      this.failAll(asError(error));
    } finally {
      reader.releaseLock();
    }
  }

  private async readStderr(stream: ReadableStream<Uint8Array>): Promise<void> {
    this.stderr = await new Response(stream).text();
  }

  private async observeExit(
    process: Bun.Subprocess<"pipe", "pipe", "pipe">
  ): Promise<void> {
    const exitCode = await process.exited;
    if (!this.closed && exitCode !== 0) {
      this.failAll(
        new Error(
          `Codex app-server exited with ${exitCode}: ${this.stderr.trim() || "no stderr"}`
        )
      );
    }
  }

  private receive(message: JsonObject): void {
    const id = asOptionalNumber(message.id);
    if (id !== undefined) {
      const pending = this.pending.get(id);
      if (!pending) return;
      this.pending.delete(id);
      if (message.error !== undefined) {
        pending.reject(
          new Error(`Codex app-server request failed: ${JSON.stringify(message.error)}`)
        );
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    this.events.push(message);
    for (const waiter of this.waiters) {
      if (!waiter.predicate(message)) continue;
      clearTimeout(waiter.timeout);
      this.waiters.delete(waiter);
      waiter.resolve(message);
    }
  }

  private waitForNotification(
    predicate: NotificationWaiter["predicate"],
    timeoutMs: number,
    startIndex = 0
  ): Promise<JsonObject> {
    for (let index = this.events.length - 1; index >= startIndex; index -= 1) {
      const existing = this.events[index];
      if (existing && predicate(existing)) return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const waiter = {
        predicate,
        resolve,
        reject,
        timeout: setTimeout(() => {
          this.waiters.delete(waiter);
          reject(new CodexAppServerNotificationTimeoutError(timeoutMs));
        }, timeoutMs),
      };
      this.waiters.add(waiter);
    });
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    this.waiters.clear();
  }

  private requireThreadTrajectory(threadId: string): ThreadTrajectory {
    const trajectory = this.threadTrajectories.get(threadId);
    if (!trajectory) throw new Error(`Unknown Codex app-server thread: ${threadId}`);
    return trajectory;
  }
}

function threadTreeObservation(
  threads: CodexAppServerThreadRecord[],
  includeTurns: boolean
): CodexAppServerThreadTreeObservation {
  const activeThreadIds: string[] = [];
  const systemErrorThreadIds: string[] = [];
  const unknownStatusThreadIds: string[] = [];
  for (const thread of threads) {
    if (!thread.status) {
      unknownStatusThreadIds.push(thread.id);
    } else if (thread.status.type === "active") {
      activeThreadIds.push(thread.id);
    } else if (thread.status.type === "systemError") {
      systemErrorThreadIds.push(thread.id);
    }
  }
  return {
    settled: activeThreadIds.length === 0 && unknownStatusThreadIds.length === 0,
    activeThreadIds,
    systemErrorThreadIds,
    unknownStatusThreadIds,
    threads,
    trajectories: includeTurns ? threads.map(threadRecordToTrajectory) : [],
  };
}

function threadRecordToTrajectory(thread: CodexAppServerThreadRecord): Trajectory {
  const fallbackTimestamp = unixTimestamp(thread.createdAt) ?? new Date(0);
  const model = thread.model ?? undefined;
  const steps: Trajectory["steps"] = [];
  for (const turn of thread.turns ?? []) {
    const startedAt = unixTimestamp(turn.startedAt) ?? fallbackTimestamp;
    const completedAt = unixTimestamp(turn.completedAt) ?? startedAt;
    for (const item of turn.items) {
      steps.push(...threadItemToTrajectorySteps(item, startedAt, completedAt, model));
    }
    if (turn.status === "failed" && turn.error != null) {
      steps.push({
        type: "system",
        content: JSON.stringify({
          source: "codex.thread.read",
          turnId: turn.id,
          status: turn.status,
          error: turn.error,
        }),
        timestamp: completedAt,
      });
    }
  }
  return { id: thread.id, steps };
}

function threadItemToTrajectorySteps(
  item: JsonObject,
  startedAt: Date,
  completedAt: Date,
  model: string | undefined
): Trajectory["steps"] {
  const type = asOptionalString(item.type);
  const id =
    asOptionalString(item.id) ?? `item-${sha256(JSON.stringify(item)).slice(0, 12)}`;

  if (type === "userMessage") {
    return [
      { type: "user", content: codexUserInputText(item.content), timestamp: startedAt },
    ];
  }
  if (type === "agentMessage") {
    return [
      {
        type: "assistant",
        content: asOptionalString(item.text) ?? "",
        ...(model ? { model } : {}),
        timestamp: completedAt,
      },
    ];
  }
  if (type === "hookPrompt" || type === "plan" || type === "reasoning") {
    return [
      {
        type: "system",
        content: JSON.stringify({ source: "codex.thread.read", item }),
        timestamp: type === "hookPrompt" ? startedAt : completedAt,
      },
    ];
  }
  if (type === "commandExecution") {
    const call = {
      type: "tool_call" as const,
      id,
      name: "commandExecution",
      arguments: z.json().parse({
        command: item.command ?? null,
        cwd: item.cwd ?? null,
        source: item.source ?? null,
      }),
      timestamp: startedAt,
    };
    if (item.status === "inProgress") return [call];
    return [
      call,
      {
        type: "tool_result",
        toolCallId: id,
        name: "commandExecution",
        output: z.json().parse({
          aggregatedOutput: item.aggregatedOutput ?? null,
          exitCode: item.exitCode ?? null,
        }),
        timestamp: completedAt,
        durationMs: asOptionalNumber(item.durationMs),
        status: asOptionalString(item.status),
      },
    ];
  }
  if (type === "fileChange") {
    return toolItemSteps({
      id,
      name: "fileChange",
      arguments: item.changes ?? [],
      output: { status: item.status ?? null },
      status: asOptionalString(item.status),
      startedAt,
      completedAt,
    });
  }
  if (type === "mcpToolCall") {
    const server = asOptionalString(item.server) ?? "mcp";
    const tool = asOptionalString(item.tool) ?? "tool";
    return toolItemSteps({
      id,
      name: `${server}.${tool}`,
      arguments: item.arguments ?? null,
      output: {
        result: item.result ?? null,
        error: item.error ?? null,
      },
      status: asOptionalString(item.status),
      durationMs: asOptionalNumber(item.durationMs),
      startedAt,
      completedAt,
    });
  }
  if (type === "dynamicToolCall") {
    const namespace = asOptionalString(item.namespace);
    const tool = asOptionalString(item.tool) ?? "tool";
    return toolItemSteps({
      id,
      name: namespace ? `${namespace}.${tool}` : tool,
      arguments: item.arguments ?? null,
      output: {
        contentItems: item.contentItems ?? null,
        success: item.success ?? null,
      },
      status: asOptionalString(item.status),
      durationMs: asOptionalNumber(item.durationMs),
      startedAt,
      completedAt,
    });
  }
  if (type === "collabAgentToolCall") {
    const tool = asOptionalString(item.tool) ?? "collab";
    return toolItemSteps({
      id,
      name: `collaboration.${tool}`,
      arguments: {
        prompt: item.prompt ?? null,
        model: item.model ?? null,
        reasoningEffort: item.reasoningEffort ?? null,
        senderThreadId: item.senderThreadId ?? null,
        receiverThreadIds: item.receiverThreadIds ?? [],
      },
      output: {
        status: item.status ?? null,
        agentsStates: item.agentsStates ?? {},
      },
      status: asOptionalString(item.status),
      startedAt,
      completedAt,
    });
  }

  return [
    {
      type: "system",
      content: JSON.stringify({
        source: "codex.thread.read",
        unsupportedItemType: type ?? null,
        item,
      }),
      timestamp: completedAt,
    },
  ];
}

function toolItemSteps(input: {
  id: string;
  name: string;
  arguments: JSONType;
  output: JSONType;
  status?: string;
  durationMs?: number;
  startedAt: Date;
  completedAt: Date;
}): Trajectory["steps"] {
  const call: Trajectory["steps"][number] = {
    type: "tool_call",
    id: input.id,
    name: input.name,
    arguments: z.json().parse(input.arguments),
    timestamp: input.startedAt,
  };
  if (input.status === "inProgress") return [call];
  return [
    call,
    {
      type: "tool_result",
      toolCallId: input.id,
      name: input.name,
      output: z.json().parse(input.output),
      timestamp: input.completedAt,
      durationMs: input.durationMs,
      status: input.status,
    },
  ];
}

function codexUserInputText(value: unknown): string {
  if (!Array.isArray(value)) return "";
  return value
    .flatMap((part) => {
      if (!part || typeof part !== "object") return [];
      const record = part as Record<string, unknown>;
      if (typeof record.text === "string") return [record.text];
      if (typeof record.image_url === "string") return [`[image: ${record.image_url}]`];
      if (typeof record.audio_url === "string") return [`[audio: ${record.audio_url}]`];
      return [];
    })
    .join("\n");
}

function unixTimestamp(value: number | null | undefined): Date | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? new Date(value * 1000)
    : undefined;
}

function historyItemToTrajectorySteps(
  item: CodexAppServerHistoryItem,
  model: string | undefined,
  timestamp: Date,
  historyMode: "full" | "digest"
): Trajectory["steps"] {
  if (item.type === "message") {
    const role = item.role;
    const originalContent = codexItemText(item.content);
    const content =
      historyMode === "full"
        ? originalContent
        : JSON.stringify({
            elided: true,
            source: "codex.thread.inject_items",
            role,
            bytes: Buffer.byteLength(originalContent),
            sha256: sha256(originalContent),
          });
    if (role === "assistant") {
      return [{ type: "assistant", content, model, timestamp }];
    }
    if (role === "system") {
      return [{ type: "system", content, timestamp }];
    }
    return [{ type: "user", content, timestamp }];
  }
  if (item.type === "function_call") {
    return [
      {
        type: "tool_call",
        id:
          typeof item.call_id === "string"
            ? item.call_id
            : `call-${sha256(JSON.stringify(item)).slice(0, 12)}`,
        name: typeof item.name === "string" ? item.name : "function",
        arguments: z.json().parse(item.arguments ?? null),
        timestamp,
      },
    ];
  }
  if (item.type === "function_call_output") {
    return [
      {
        type: "tool_result",
        toolCallId:
          typeof item.call_id === "string"
            ? item.call_id
            : `call-${sha256(JSON.stringify(item)).slice(0, 12)}`,
        name: "function",
        output: z.json().parse(item.output ?? null),
        timestamp,
        status: "completed",
      },
    ];
  }
  return [
    {
      type: "system",
      content: JSON.stringify({
        source: "codex.thread.inject_items",
        unsupportedItemType: item.type ?? null,
        sha256: sha256(JSON.stringify(item)),
      }),
      timestamp,
    },
  ];
}

function codexItemText(value: unknown): string {
  if (!Array.isArray(value)) return "";
  return value
    .flatMap((part) => {
      if (!part || typeof part !== "object") return [];
      const text = (part as Record<string, unknown>).text;
      return typeof text === "string" ? [text] : [];
    })
    .join("\n");
}

function sha256(value: string): string {
  return new Bun.CryptoHasher("sha256").update(value).digest("hex");
}

function parseMessage(line: string): JsonObject {
  try {
    return JsonObjectSchema.parse(JSON.parse(line));
  } catch (error) {
    throw new Error(`Invalid Codex app-server JSONL: ${line}`, { cause: error });
  }
}

function latestFinalAnswer(
  events: readonly JsonObject[],
  threadId: string,
  turnId: string
): string {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]!;
    if (event.method !== "item/completed") continue;
    const params = asOptionalObject(event.params);
    if (
      asOptionalString(params?.threadId) !== threadId ||
      asOptionalString(params?.turnId) !== turnId
    ) {
      continue;
    }
    const item = asOptionalObject(params?.item);
    if (item?.type === "agentMessage" && typeof item.text === "string") {
      return item.text;
    }
  }
  return "";
}

function latestTokenUsage(
  events: readonly JsonObject[],
  threadId: string
): CodexAppServerTokenUsage {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]!;
    if (event.method !== "thread/tokenUsage/updated") continue;
    const params = asOptionalObject(event.params);
    if (asOptionalString(params?.threadId) !== threadId) continue;
    const total = asOptionalObject(asOptionalObject(params?.tokenUsage)?.total);
    return {
      inputTokens: asOptionalNumber(total?.inputTokens) ?? 0,
      outputTokens: asOptionalNumber(total?.outputTokens) ?? 0,
      totalTokens: asOptionalNumber(total?.totalTokens) ?? 0,
    };
  }
  return { inputTokens: 0, outputTokens: 0, totalTokens: 0 };
}

function latestTokenUsageByThread(
  events: readonly JsonObject[]
): Record<string, CodexAppServerTokenUsage> {
  const usageByThread: Record<string, CodexAppServerTokenUsage> = {};
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]!;
    if (event.method !== "thread/tokenUsage/updated") continue;
    const params = asOptionalObject(event.params);
    const threadId = asOptionalString(params?.threadId);
    if (!threadId || usageByThread[threadId]) continue;
    const total = asOptionalObject(asOptionalObject(params?.tokenUsage)?.total);
    usageByThread[threadId] = {
      inputTokens: asOptionalNumber(total?.inputTokens) ?? 0,
      outputTokens: asOptionalNumber(total?.outputTokens) ?? 0,
      totalTokens: asOptionalNumber(total?.totalTokens) ?? 0,
    };
  }
  return usageByThread;
}

function sumTokenUsage(
  usages: readonly CodexAppServerTokenUsage[]
): CodexAppServerTokenUsage {
  return usages.reduce<CodexAppServerTokenUsage>(
    (total, usage) => ({
      inputTokens: total.inputTokens + usage.inputTokens,
      outputTokens: total.outputTokens + usage.outputTokens,
      totalTokens: total.totalTokens + usage.totalTokens,
    }),
    { inputTokens: 0, outputTokens: 0, totalTokens: 0 }
  );
}

function collaborationEvents(
  events: readonly JsonObject[]
): CodexAppServerCollaborationEvent[] {
  const normalized: CodexAppServerCollaborationEvent[] = [];
  for (const event of events) {
    const parsed = CollabItemNotificationSchema.safeParse(event);
    if (!parsed.success) continue;
    const { method, params } = parsed.data;
    const { item } = params;
    const receiverThreadIds = [
      ...(item.receiverThreadIds ?? []),
      ...(item.receiverThreadId ? [item.receiverThreadId] : []),
      ...(item.newThreadId ? [item.newThreadId] : []),
    ].filter((threadId, index, all) => all.indexOf(threadId) === index);
    const agentsStates = item.agentsStates ? { ...item.agentsStates } : {};
    if (
      item.agentStatus &&
      receiverThreadIds.length === 1 &&
      !agentsStates[receiverThreadIds[0]!]
    ) {
      agentsStates[receiverThreadIds[0]!] = { status: item.agentStatus };
    }
    const normalizedEvent: CodexAppServerCollaborationEvent = {
      lifecycle: method === "item/started" ? "started" : "completed",
      threadId: params.threadId,
      turnId: params.turnId,
      id: item.id,
      tool: item.tool,
      status: item.status,
      senderThreadId: item.senderThreadId,
      receiverThreadIds,
      agentsStates,
    };
    if (item.prompt != null) normalizedEvent.prompt = item.prompt;
    if (item.model != null) normalizedEvent.model = item.model;
    if (item.reasoningEffort != null) {
      normalizedEvent.reasoningEffort = item.reasoningEffort;
    }
    normalized.push(normalizedEvent);
  }
  return normalized;
}

function eventDescendantThreads(
  rootThreadId: string,
  events: readonly JsonObject[]
): CodexAppServerThreadRecord[] {
  const threads = new Map<string, CodexAppServerThreadRecord>();
  for (const event of events) {
    if (event.method !== "thread/started") continue;
    const thread = CodexThreadSchema.safeParse(asOptionalObject(event.params)?.thread);
    if (thread.success) threads.set(thread.data.id, thread.data);
  }

  const descendantIds = new Set([rootThreadId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const thread of threads.values()) {
      const parentId = thread.parentThreadId ?? thread.forkedFromId;
      if (!parentId || !descendantIds.has(parentId) || descendantIds.has(thread.id)) {
        continue;
      }
      descendantIds.add(thread.id);
      changed = true;
    }
  }
  return [...threads.values()].filter((thread) => descendantIds.has(thread.id));
}

function assertCompletedTurn(event: JsonObject, label: string): void {
  const turn = asObject(asObject(event.params).turn);
  if (turn.status !== "completed") {
    const detail =
      turn.error ?? turn.failureReason ?? turn.failure_reason ?? turn.message ?? null;
    throw new Error(
      `${label} ended with status ${String(turn.status)}${
        detail === null ? "" : `: ${JSON.stringify(detail)}`
      }`
    );
  }
}

function asObject(value: unknown): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Expected object, received ${JSON.stringify(value)}`);
  }
  return value as JsonObject;
}

function asOptionalObject(value: unknown): JsonObject | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonObject)
    : undefined;
}

function asOptionalString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asOptionalNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function asError(value: unknown): Error {
  return value instanceof Error ? value : new Error(String(value));
}
