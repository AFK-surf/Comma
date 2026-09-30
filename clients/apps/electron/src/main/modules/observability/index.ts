import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { NativeObservabilitySink, NativeObservationEvent } from "../ipc";

export class JsonlNativeObservabilitySink implements NativeObservabilitySink {
  readonly #filePath: string;

  constructor({ filePath }: { filePath: string }) {
    this.#filePath = filePath;
  }

  record(event: NativeObservationEvent) {
    mkdirSync(dirname(this.#filePath), { recursive: true });
    appendFileSync(
      this.#filePath,
      `${JSON.stringify(redactNativeObservation(event))}\n`,
      "utf8"
    );
  }
}

export function redactNativeObservation(value: unknown): unknown {
  if (value instanceof Error) {
    return {
      message: redactString(value.message),
      name: value.name,
    };
  }

  if (typeof value === "string") {
    return redactString(value);
  }

  if (value instanceof ArrayBuffer) {
    return `[redacted-binary:${value.byteLength}]`;
  }

  if (ArrayBuffer.isView(value)) {
    return `[redacted-binary:${value.byteLength}]`;
  }

  if (Array.isArray(value)) {
    return value.map((item) => redactNativeObservation(item));
  }

  if (!isRecord(value)) {
    return value;
  }

  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      isSecretKey(key) ? "[redacted:secret]" : redactNativeObservation(item),
    ])
  );
}

function redactString(value: string) {
  return value
    .replace(
      /\bAuthorization\s*[:=]?\s*Bearer\s+\S+/gi,
      "Authorization [redacted:secret]"
    )
    .replace(/\bBearer\s+\S+/gi, "Bearer [redacted]")
    .replace(/\/Users\/[^/\s"]+(?:\/[^\s"]*)?/g, "[redacted-path]")
    .replace(/\/var\/folders\/[^\s"]+/g, "[redacted-path]");
}

function isSecretKey(key: string) {
  return /authorization|credential|password|secret|session|token/i.test(key);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
