#!/usr/bin/env node
"use strict";

const { readFileSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const readline = require("node:readline");

const protocolVersion = 3;
const markerPath = join(
  tmpdir(),
  `comma-side-chat-shortcut-overlap-${process.ppid}.json`
);
let delayedReplayRequestId;
let delayedReplayTimer;

function emit(frame) {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}

function emitResult(requestId, ok, error) {
  emit({
    ...(error ? { error } : {}),
    kind: "command.result",
    ok,
    protocolVersion,
    requestId,
  });
}

function readMarker() {
  try {
    return JSON.parse(readFileSync(markerPath, "utf8"));
  } catch {
    return {};
  }
}

function readState() {
  return readMarker().state ?? "initial";
}

function writeState(state, extra = {}) {
  writeFileSync(
    markerPath,
    JSON.stringify({
      ...readMarker(),
      helperPid: process.pid,
      state,
      ...extra,
    }),
    "utf8"
  );
}

function rejectDelayedReplay() {
  if (!delayedReplayRequestId) return;
  const requestId = delayedReplayRequestId;
  delayedReplayRequestId = undefined;
  delayedReplayTimer = undefined;
  writeState("replay-rejected");
  emitResult(
    requestId,
    false,
    "The fixture rejected committed replay before the queued update."
  );
}

const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  let frame;
  try {
    frame = JSON.parse(line);
  } catch {
    return;
  }

  const requestId = typeof frame.requestId === "string" ? frame.requestId : "fixture";
  if (frame.kind === "side-chat.shortcut") {
    const isDefault = frame.keyCode === 6 && frame.modifiers === 4096;
    if (isDefault) {
      emitResult(requestId, true);
      return;
    }

    const state = readState();
    if (state === "initial") {
      writeState("confirmed");
      emitResult(requestId, true);
      setTimeout(() => process.exit(1), 50);
      return;
    }

    if (state === "confirmed") {
      delayedReplayRequestId = requestId;
      writeState("replay-pending", { overlapObserved: false });
      delayedReplayTimer = setTimeout(rejectDelayedReplay, 1_500);
      return;
    }

    if (state === "replay-pending") {
      if (delayedReplayTimer) clearTimeout(delayedReplayTimer);
      const replayRequestId = delayedReplayRequestId;
      delayedReplayRequestId = undefined;
      delayedReplayTimer = undefined;
      writeState("overlap-nacked", { overlapObserved: true });
      if (replayRequestId) {
        emitResult(
          replayRequestId,
          false,
          "The fixture rejected the untracked replay."
        );
      }
      emitResult(requestId, false, "The fixture rejected the overlapping user update.");
      return;
    }

    if (state === "replay-rejected") {
      writeState("serialized-both-nacked");
      emitResult(
        requestId,
        false,
        "The fixture rejected the serialized recovery update."
      );
      return;
    }

    if (state === "serialized-both-nacked") {
      if (frame.keyCode === 40 && frame.modifiers === 4096) {
        writeState("reconciled");
        emitResult(requestId, true);
      } else {
        writeState("reconciliation-mismatch", {
          actualKeyCode: frame.keyCode,
          actualModifiers: frame.modifiers,
        });
        emitResult(
          requestId,
          false,
          "The fixture expected the replacement helper to replay Control-K."
        );
      }
      return;
    }

    if (state === "reconciled") {
      writeState("unexpected-restart");
      emitResult(requestId, true);
      return;
    }

    emitResult(requestId, true);
    return;
  }

  if (frame.kind === "side-chat.stop") {
    emitResult(requestId, true);
    setImmediate(() => process.exit(0));
    return;
  }

  if (frame.kind !== "command.result" && frame.kind !== "chat.snapshot") {
    emitResult(requestId, true);
  }
});
input.on("close", () => process.exit(0));

emit({
  kind: "side-chat.ready",
  protocolVersion,
  requestId: "shortcut-overlap-fixture-ready",
});
