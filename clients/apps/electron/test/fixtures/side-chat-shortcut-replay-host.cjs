#!/usr/bin/env node
"use strict";

const { readFileSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const readline = require("node:readline");

const protocolVersion = 3;
const markerPath = join(
  tmpdir(),
  `comma-side-chat-shortcut-replay-${process.ppid}.json`
);

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

function readState() {
  try {
    return JSON.parse(readFileSync(markerPath, "utf8")).state;
  } catch {
    return "initial";
  }
}

function writeState(state) {
  writeFileSync(markerPath, JSON.stringify({ state }), "utf8");
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
      writeState("rejected");
      emitResult(
        requestId,
        false,
        "The fixture rejected shortcut replay after helper restart."
      );
      return;
    }

    writeState("reconciled");
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
  requestId: "shortcut-replay-fixture-ready",
});
