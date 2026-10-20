// What an agent is doing, said in the Slack thread it works for while it works (chat/status.rs): Slack's own status
// line under the thread (assistant.threads.setStatus), changed at most every couple of seconds and cleared when the turn
// ends. Where Slack will not show one (the app lacks the scope, the conversation does not take it), an 👀 on the
// message that started the work says the same, and goes when it is done. The words are sessions/chat.ts `toolStatus`.
import { Clock, Effect } from "effect";
import { log } from "../ops/log.ts";
import type { Params } from "./web.ts";

/// How often the status line may change: Slack's limit on the call, and enough to follow along.
export const MIN_INTERVAL_MS = 2_000;
const FALLBACK_REACTION = "eyes";

/// What Slack answers when it will not show a status here: the reaction says it instead.
const noStatus = (error: string) =>
  ["missing_scope", "unknown_method", "not_allowed_token_type", "feature_not_enabled", "method_not_supported_for_channel_type", "not_in_channel"].some((code) =>
    error.includes(code),
  );

/// A Web API call as the bot; fails with Slack's error.
export type Call = (method: string, params: Params) => Promise<void>;
/// Runs an effect as a fiber of whoever owns the line (its timers end with it).
export type Run = (effect: Effect.Effect<void>) => Promise<void>;

/// One thread's status line. `say("")` clears it.
export class ThreadStatus {
  private call: Call;
  private run: Run;
  readonly channel: string;
  readonly threadTs: string;
  private messageTs: string | null = null;
  private shown = "";
  private wanted = "";
  /// When it last changed (never, at first: the first change goes at once, whatever the clock says).
  private lastAt = Number.NEGATIVE_INFINITY;
  private timer = false;
  /// Slack will not show a status line here: the reaction stands in.
  private reactionOnly = false;
  private reacted: string | null = null;
  /// One send at a time, in order.
  private sending: Promise<void> = Promise.resolve();

  constructor(call: Call, run: Run, channel: string, threadTs: string) {
    this.call = call;
    this.run = run;
    this.channel = channel;
    this.threadTs = threadTs;
  }

  say(status: string, messageTs: string | null) {
    if (messageTs !== null) this.messageTs = messageTs;
    this.wanted = status;
    if (this.timer) return;
    this.timer = true;
    // On the clock of whoever runs it (a TestClock in tests).
    const due = Clock.currentTimeMillis.pipe(
      Effect.flatMap((now) => Effect.sleep(status === "" ? 0 : Math.max(0, this.lastAt + MIN_INTERVAL_MS - now))),
      Effect.andThen(Clock.currentTimeMillis),
      Effect.flatMap((now) => Effect.promise(() => this.due(now))),
    );
    void this.run(due).catch(() => {});
  }

  private async due(now: number) {
    this.timer = false;
    if (this.wanted === this.shown) return;
    this.lastAt = now;
    const next = this.wanted;
    const sent = this.sending.then(() => this.send(next));
    this.sending = sent.catch(() => {});
    await sent;
  }

  private async send(status: string) {
    if (!this.reactionOnly) {
      const params: Params = [
        ["channel_id", this.channel],
        ["thread_ts", this.threadTs],
        ["status", status],
      ];
      if (status !== "") params.push(["loading_messages", status]);
      try {
        await this.call("assistant.threads.setStatus", params);
        this.shown = status;
        return;
      } catch (error) {
        const said = (error as Error).message;
        if (!noStatus(said)) {
          log.warn("slack", "could not say the agent's status in Slack", { channel: this.channel, thread: this.threadTs, error: said });
          return;
        }
        this.reactionOnly = true;
      }
    }
    this.shown = status;
    const [target, reacted] = [this.messageTs, this.reacted];
    try {
      if (status !== "") {
        if (target !== null && reacted !== target) {
          await this.call("reactions.add", this.reaction(target));
          this.reacted = target;
        }
      } else if (reacted !== null) {
        this.reacted = null;
        await this.call("reactions.remove", this.reaction(reacted));
      }
    } catch (error) {
      const said = (error as Error).message;
      if (!said.includes("already_reacted") && !said.includes("no_reaction")) log.warn("slack", "could not mark the agent's work in Slack", { channel: this.channel, error: said });
    }
  }

  private reaction(timestamp: string): Params {
    return [
      ["channel", this.channel],
      ["timestamp", timestamp],
      ["name", FALLBACK_REACTION],
    ];
  }
}
