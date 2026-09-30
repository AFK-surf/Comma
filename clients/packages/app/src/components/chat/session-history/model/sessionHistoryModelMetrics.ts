import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { sessionDataObject } from "./sessionHistoryPresentation";

const tokens = (value: unknown) =>
  typeof value === "number" && value >= 0 ? value : undefined;

/** Input is the provider-normalized total, including cache reads/writes
 * (SalixLlm.Usage). Missing counters are unavailable, not zero cache hits. */
export function sessionModelMetrics(record: SessionHistoryRecord) {
  const content = sessionDataObject(record.content);
  const input = tokens(content.input_tokens);
  const output = tokens(content.output_tokens);
  const cacheRead = tokens(content.cache_read_input_tokens);
  const cacheWrite = tokens(content.cache_write_input_tokens);
  const timing = record.execution;
  return {
    model: typeof content.model === "string" ? content.model : undefined,
    ttft:
      timing?.first_token_at_ms != null
        ? timing.first_token_at_ms - timing.started_at_ms
        : undefined,
    input,
    output,
    cacheRead,
    cacheWrite,
    cacheRate:
      input !== undefined && input > 0 && cacheRead !== undefined
        ? cacheRead / input
        : undefined,
  };
}
