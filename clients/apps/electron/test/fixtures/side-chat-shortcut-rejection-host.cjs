#!/usr/bin/env node
"use strict";

const readline = require("node:readline");

const protocolVersion = 3;

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
    if (
      (frame.keyCode === 6 && frame.modifiers === 4096) ||
      (frame.keyCode === undefined && frame.modifiers === 0)
    ) {
      emitResult(requestId, true);
    } else {
      emitResult(requestId, false, "The fixture rejected this global shortcut.");
    }
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
  requestId: "shortcut-rejection-fixture-ready",
});
