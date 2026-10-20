// A runtime's stream as live steps (runtime/claude.rs LiveFromClaude, runtime/codex.rs LiveFromCodex): a step starts,
// grows by deltas and ends; the phase says where the turn stands with the model. What each keeps between frames is
// plain data (`state`), so a station taking a session up goes on with the steps in flight.
import type { LiveEvent } from "./runtime.ts";
import { wall } from "../ops/fibers.ts";

type Json = any;
type Phase = "starting" | "requesting" | "responding" | "working";
type Step = "text" | "thinking" | "tool";

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const nonEmpty = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
/// At most `n` characters (Rust's chars().take(n)).
export const chars = (text: string, n: number): string => {
  if (text.length <= n) return text;
  return Array.from(text).slice(0, n).join("");
};

/// Claude Code's step event, as LiveEvent::Start serializes: fields that are none left out.
function start(id: string, step: Step, tool?: string, input?: string, subagent?: boolean, parent?: string): LiveEvent {
  const event: LiveEvent = { kind: "start", id, step };
  if (tool !== undefined) event.tool = tool;
  if (input !== undefined) event.input = input;
  if (subagent !== undefined) event.subagent = subagent;
  if (parent !== undefined) event.parent = parent;
  return event;
}

type Block = { id: string; step: Step; tool?: string; input?: string; subagent?: string };
export type ClaudeLiveState = { message: string; blocks: [number, Block][]; tools: string[] };

/// Claude Code's partial messages (--include-partial-messages) as live steps. Each content block of a model response is
/// a step: text and thinking end with their block; a tool call ends when its result comes back, which also carries the
/// output (Claude Code does not stream tool output).
export class LiveFromClaude {
  private message = "";
  private blocks = new Map<number, Block>();
  private tools = new Set<string>();

  constructor(state?: ClaudeLiveState) {
    if (state) {
      this.message = state.message;
      this.blocks = new Map(state.blocks);
      this.tools = new Set(state.tools);
    }
  }

  state(): ClaudeLiveState {
    return { message: this.message, blocks: [...this.blocks.entries()], tools: [...this.tools] };
  }

  feed(frame: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    const kind = str(frame?.type) ?? "";
    if (kind === "system" && frame.subtype === "status" && frame.status === "requesting") {
      out.push({ kind: "phase", phase: "requesting" });
    } else if (kind === "stream_event") {
      const e = frame.event ?? null;
      // A sub-agent's steps name the tool call (Task/Agent) that started it.
      const parent = nonEmpty(frame.parent_tool_use_id);
      const event = str(e?.type) ?? "";
      if (event === "message_stop" && parent === undefined) out.push({ kind: "phase", phase: "working" });
      const index = Number.isInteger(e?.index) ? (e.index as number) : -1;
      if (event === "message_start") {
        this.message = str(e?.message?.id) ?? String(wall.now());
        this.blocks.clear();
        if (parent === undefined) out.push({ kind: "phase", phase: "responding" });
      } else if (event === "content_block_start") {
        const b = e?.content_block ?? null;
        const type = str(b?.type);
        const step: Step | undefined = type === "text" ? "text" : type === "thinking" ? "thinking" : type === "tool_use" ? "tool" : undefined;
        if (step === undefined) return out;
        const id = step === "tool" && typeof b?.id === "string" ? (b.id as string) : `${this.message}:${index}`;
        const tool = step === "tool" ? (str(b?.name) ?? "tool") : undefined;
        if (step === "tool") this.tools.add(id);
        out.push(start(id, step, tool, undefined, parent !== undefined ? true : undefined, parent));
        this.blocks.set(index, { id, step, tool, input: tool !== undefined ? "" : undefined, subagent: parent });
      } else if (event === "content_block_delta") {
        const block = this.blocks.get(index);
        if (!block) return out;
        const d = e?.delta ?? null;
        const type = str(d?.type);
        if (type === "text_delta") {
          const t = nonEmpty(d.text);
          if (t !== undefined) out.push({ kind: "delta", id: block.id, field: "text", text: t });
        } else if (type === "thinking_delta") {
          const t = nonEmpty(d.thinking);
          if (t !== undefined) out.push({ kind: "delta", id: block.id, field: "text", text: t });
        } else if (type === "input_json_delta") {
          const partial = nonEmpty(d.partial_json);
          if (partial !== undefined) {
            // A call's input streams in after it starts; kept (its start, a moment before, came without it).
            if (block.input !== undefined && block.input.length < 4096) block.input += partial;
            out.push({ kind: "delta", id: block.id, field: "input", text: partial });
          }
        }
      } else if (event === "content_block_stop") {
        const block = this.blocks.get(index);
        if (block) {
          if (block.step !== "tool") out.push({ kind: "end", id: block.id });
          else if (block.input !== undefined && block.input !== "") {
            // Its input complete, the call starts again with it: what it runs can be said now.
            out.push(start(block.id, "tool", block.tool, block.input, block.subagent !== undefined ? true : undefined, block.subagent));
          }
        }
      }
    } else if (kind === "user") {
      const content = Array.isArray(frame.message?.content) ? frame.message.content : [];
      for (const c of content) {
        const id = str(c?.tool_use_id) ?? "";
        if (c?.type !== "tool_result" || !this.tools.has(id)) continue;
        const text =
          typeof c.content === "string"
            ? c.content
            : Array.isArray(c.content)
              ? c.content.map((x: Json) => str(x?.text) ?? "").join("\n")
              : "";
        if (text !== "") out.push({ kind: "delta", id, field: "output", text: chars(text, 8000) });
        out.push({ kind: "end", id });
        this.tools.delete(id);
      }
    }
    return out;
  }
}

const TOOL_ITEMS = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"];

export type CodexLiveState = { open: string[]; phase: Phase | null };

/// Rust's serde_json::to_string_pretty: two-space indent, "key": value.
const pretty = (v: unknown) => JSON.stringify(v ?? {}, null, 2) ?? "{}";

/// The app-server's item notifications as live steps: an item starts, grows by deltas (the reply, reasoning, a
/// command's output as it runs) and completes.
export class LiveFromCodex {
  private open = new Set<string>();
  private phase: Phase | null = null;

  constructor(state?: CodexLiveState) {
    if (state) {
      this.open = new Set(state.open);
      this.phase = state.phase;
    }
  }

  state(): CodexLiveState {
    return { open: [...this.open], phase: this.phase };
  }

  feed(method: string, params: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    const to = (next: Phase) => {
      if (this.phase !== next) {
        this.phase = next;
        out.push({ kind: "phase", phase: next });
      }
    };
    const itemType = str(params?.item?.type) ?? "";
    if (method === "turn/started") to("requesting");
    else if (method === "turn/completed") this.phase = null;
    else if (method === "item/agentMessage/delta" || method.startsWith("item/reasoning/")) to("responding");
    else if (method === "item/started" && TOOL_ITEMS.includes(itemType)) to("working");
    else if (method === "item/completed" && TOOL_ITEMS.includes(itemType)) to("requesting");

    const text = (v: unknown) => str(v) ?? "";
    if (method === "item/started") {
      const item = params?.item ?? null;
      const id = typeof item?.id === "string" ? item.id : typeof item?.id === "number" ? String(item.id) : "";
      let begun: [Step, string | undefined, string | undefined] | undefined;
      if (itemType === "agentMessage") begun = ["text", undefined, undefined];
      else if (itemType === "reasoning") begun = ["thinking", undefined, undefined];
      else if (itemType === "commandExecution") begun = ["tool", "shell", text(item.command)];
      else if (itemType === "fileChange")
        begun = ["tool", "apply_patch", (Array.isArray(item.changes) ? item.changes : []).map((c: Json) => text(c?.path)).join("\n")];
      else if (itemType === "mcpToolCall") begun = ["tool", `${text(item.server)}.${text(item.tool)}`, pretty(item.arguments)];
      else if (itemType === "dynamicToolCall") begun = ["tool", text(item.tool), pretty(item.arguments)];
      else if (itemType === "webSearch") begun = ["tool", "web_search", text(item.query)];
      if (id !== "" && begun) {
        this.open.add(id);
        out.push(start(id, begun[0], begun[1], begun[2]));
      }
    } else if (
      method === "item/agentMessage/delta" ||
      method === "item/reasoning/textDelta" ||
      method === "item/reasoning/summaryTextDelta" ||
      method === "item/plan/delta" ||
      method === "item/commandExecution/outputDelta"
    ) {
      const id = text(params?.itemId);
      const delta = text(params?.delta);
      if (this.open.has(id) && delta !== "") {
        out.push({ kind: "delta", id, field: method === "item/commandExecution/outputDelta" ? "output" : "text", text: delta });
      }
    } else if (method === "item/completed") {
      const id = text(params?.item?.id);
      if (this.open.delete(id)) out.push({ kind: "end", id });
    }
    return out;
  }
}
