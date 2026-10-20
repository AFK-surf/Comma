import type { ChatChannel } from "../chat/channel/ChatChannel";

/**
 * Puts the Router prompt in the chat's draft once the core has the chat ready
 * (it waits at most 10 s); no message is sent. Any draft text already there is
 * kept, and asking again adds nothing. An abort stops the wait here at once.
 */
export async function prefillDeviceDraft(
  channel: Pick<ChatChannel, "prefillDraft">,
  prompt: string,
  signal: AbortSignal
) {
  signal.throwIfAborted();
  const stop = new AbortController();
  const aborted = new Promise<never>((_, reject) => {
    signal.addEventListener(
      "abort",
      () => reject(new Error("Chat request canceled.")),
      { once: true, signal: stop.signal }
    );
  });
  try {
    await Promise.race([channel.prefillDraft(prompt), aborted]);
  } finally {
    stop.abort();
  }
  signal.throwIfAborted();
}
