import type { ChatChannel } from "../../runtime-chat/channel/ChatChannel";
const noSubscription = () => {};

/** One event-driven wait for the existing chat owner; no message is sent. */
export async function prefillDeviceDraft(
  channel: ChatChannel,
  prompt: string,
  signal: AbortSignal
) {
  await new Promise<void>((resolve, reject) => {
    let release = noSubscription;
    let settled = false;
    const done = (error?: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal.removeEventListener("abort", aborted);
      release();
      if (error) reject(error);
      else resolve();
    };
    const aborted = () => done(new Error("Chat request canceled."));
    const check = () => {
      const state = channel.getSnapshot();
      if (state.status === "ready") done();
      else if (state.status === "error") done(new Error("Chat is unavailable."));
    };
    const timer = setTimeout(
      () => done(new Error("Chat did not become ready.")),
      10_000
    );
    release = channel.subscribe(check);
    if (settled) {
      release();
      return;
    }
    signal.addEventListener("abort", aborted, { once: true });
    if (signal.aborted) aborted();
    else check();
  });
  signal.throwIfAborted();
  const draft = channel.getSnapshot().draft;
  // Keep any text the user already has. Repeated clicks do not duplicate it.
  if (!draft.includes(prompt))
    await channel.setDraft(draft.trim() ? `${draft}\n\n${prompt}` : prompt);
}
