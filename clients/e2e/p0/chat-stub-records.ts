// The fixed records of the chat stub (./chat-stub.ts): its Workspace, chat,
// Task and reply, which specs in the browser and in Node both name.
export const chatSmokeWorkspace = {
  group_id: "grp-smoke",
  id: "ws-smoke",
  name: "Smoke Workspace",
};
export const chatSmokeWorkspaceChat = {
  id: "cnv_public_chat_smoke",
  status: "active",
  title: "聊天",
  kind: "user_chat",
  group_id: chatSmokeWorkspace.group_id,
  created_at: 1_720_000_000,
  updated_at: 1_720_000_000,
};
/**
 * A Loop Task's public `loop`, as the Comma API sends it for a Task the person
 * asked to repeat or keep watching (no other Task has one). `state`: pending
 * (no Background Loop yet), active, paused or ended, with a `reason` when
 * paused or ended; `cadence`: `{every_minutes}`, `{cron, timezone}` or
 * `{events}`; `max_runs`, `ends_at`, `until`: the end the person asked for;
 * `wake_count`: runs so far; `started_at`, `last_wake_at` (after the first
 * run), `next_run_at` (an active cron Loop's), `ended_at`: unix ms.
 */
export type ChatSmokeTaskLoop = {
  state: "pending" | "active" | "paused" | "ended";
  reason?:
    | "waiting"
    | "budget"
    | "exited"
    | "failed"
    | "quota"
    | "undeliverable"
    | "completed"
    | "cancelled"
    | "max_runs"
    | "ends_at";
  cadence:
    | { every_minutes: number }
    | { cron: string; timezone: string }
    | { events: string };
  max_runs?: number;
  ends_at?: number;
  until?: string;
  started_at: number;
  wake_count: number;
  last_wake_at?: number;
  next_run_at?: number;
  ended_at?: number;
};
/**
 * A Loop a spec gives the stub's Task (`taskLoop`; it is a one-off Task
 * otherwise): every day at 09:00 in Shanghai, 3 of 10 runs made. Active, so
 * the spec pairs it with `taskStatus: "active"`.
 */
export const chatSmokeTaskLoop: ChatSmokeTaskLoop = {
  state: "active",
  cadence: { cron: "0 9 * * *", timezone: "Asia/Shanghai" },
  max_runs: 10,
  started_at: 1_720_000_002_000,
  wake_count: 3,
  last_wake_at: 1_720_227_600_000,
  next_run_at: 1_720_314_000_000,
};
export const chatSmokeTaskConversation = {
  id: "cnv_public_task_smoke",
  status: "completed",
  title: "冒烟任务",
  kind: "agent_task",
  group_id: chatSmokeWorkspace.group_id,
  created_at: 1_720_000_002,
  updated_at: 1_720_000_003,
};
export const chatSmokeAssistantReply = "收到，stub 已生成回复。";
