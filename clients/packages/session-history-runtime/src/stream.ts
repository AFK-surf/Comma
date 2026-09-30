import { createParser } from "eventsource-parser";
import {
  sessionHistoryStreamFrameSchema,
  type SessionHistoryStreamFrame,
} from "@comma/native-bridge";

/** Fetch supports host-held bearer credentials in both Main and SharedWorker;
 * eventsource-parser owns SSE framing (including fragmented UTF-8/multiline data).
 * Native EventSource cannot carry the Main bearer header. */
export async function readHistoryStream(
  fetcher: typeof fetch,
  url: URL,
  init: RequestInit,
  onFrame: (frame: SessionHistoryStreamFrame) => void
) {
  const response = await fetcher(url, init);
  if (!response.ok || !response.body)
    throw new Error("Session history stream unavailable.");
  const parser = createParser({
    onEvent(event) {
      if (event.event === "history")
        onFrame(sessionHistoryStreamFrameSchema.parse(JSON.parse(event.data)));
    },
    onError(error) {
      throw error;
    },
  });
  const decoder = new TextDecoder();
  const reader = response.body.getReader();
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      parser.feed(decoder.decode(value, { stream: true }));
    }
    parser.feed(decoder.decode());
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
