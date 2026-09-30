#!/usr/bin/env node
"use strict";

const readline = require("node:readline");

const protocolVersion = 3;
const causalReleaseLayout = { height: 555, width: 777 };
const closingFrameDelaysAfterAckMs = [0, 500, 1_000];
const postAckInteractiveInterferenceDelayMs = 250;
const postAckOpenInterferenceDelayMs = 350;
const finalCloseDelayAfterAckMs = 1_800;

let closeEpoch = 0;
let closeStartedAt;
let finalCloseTimer;
let pendingCloseRequestId;
let replacementLayoutSeen = false;
let revision = 0;

const sequenceTimers = new Set();

function emit(frame) {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}

function mark(message) {
  process.stderr.write(`[comma-side-chat-slow-close] ${message}\n`);
}

function emitResult(requestId, ok = true, error) {
  emit({
    ...(error ? { error } : {}),
    kind: "command.result",
    ok,
    protocolVersion,
    requestId,
  });
}

function emitPresentation(phase, progress) {
  const windowWidth = 523;
  const hiddenDistance = windowWidth + 16;
  emit({
    availableContentHeight: 600,
    contentFrame: { height: 286, width: 364, x: 9, y: 3 },
    displayId: 0,
    kind: "side-chat.presentation",
    offsetX: -(1 - progress) * hiddenDistance,
    phase,
    progress,
    protocolVersion,
    revision: ++revision,
    screenFrame: { height: 900, width: 1440, x: 0, y: 0 },
    windowFrame: { height: 412, width: windowWidth, x: 4, y: 12 },
  });
}

function beginSlowClose(requestId) {
  if (closeStartedAt !== undefined) return;

  closeStartedAt = Date.now();
  closeEpoch += 1;
  pendingCloseRequestId = requestId;
  replacementLayoutSeen = false;
  mark(`close-received epoch=${closeEpoch} at=${closeStartedAt}`);
}

function emitFinalClose() {
  if (closeStartedAt === undefined) return;
  const emittedAt = Date.now();
  mark(
    `closed-emitted epoch=${closeEpoch} at=${emittedAt} delayMs=${
      emittedAt - closeStartedAt
    }`
  );
  emitPresentation("closed", 0);
  closeStartedAt = undefined;
  pendingCloseRequestId = undefined;
  replacementLayoutSeen = false;
  finalCloseTimer = undefined;
}

function emitPostReplacementCausalSequence() {
  if (closeStartedAt === undefined || replacementLayoutSeen) return;
  replacementLayoutSeen = true;
  mark(`replacement-layout-received epoch=${closeEpoch} at=${Date.now()}`);

  mark(`stale-closed-before-ack epoch=${closeEpoch} at=${Date.now()}`);
  emitPresentation("closed", 0);
  mark(`stale-opening-before-ack epoch=${closeEpoch} at=${Date.now()}`);
  emitPresentation("opening", 0.62);
  mark(`stale-open-before-ack epoch=${closeEpoch} at=${Date.now()}`);
  emitPresentation("open", 1);
}

function emitMatchingCloseAckAndClosingFrames() {
  if (closeStartedAt === undefined || pendingCloseRequestId === undefined) return;
  const closeRequestId = pendingCloseRequestId;
  pendingCloseRequestId = undefined;
  const acknowledgedAt = Date.now();
  mark(`close-ack-emitted epoch=${closeEpoch} at=${acknowledgedAt}`);
  emitResult(closeRequestId);

  for (const [index, delayMs] of closingFrameDelaysAfterAckMs.entries()) {
    scheduleSequence(delayMs, () => {
      if (closeStartedAt === undefined) return;
      const progress = Math.max(0.24, 0.74 - index * 0.22);
      mark(
        `closing-positive-after-ack epoch=${closeEpoch} at=${Date.now()} progress=${progress}`
      );
      emitPresentation("closing", progress);
    });
  }
  scheduleSequence(postAckInteractiveInterferenceDelayMs, () => {
    if (closeStartedAt === undefined) return;
    mark(`post-ack-interactive-interference epoch=${closeEpoch} at=${Date.now()}`);
    emitPresentation("interactive", 0.68);
  });
  scheduleSequence(postAckOpenInterferenceDelayMs, () => {
    if (closeStartedAt === undefined) return;
    mark(`post-ack-open-interference epoch=${closeEpoch} at=${Date.now()}`);
    emitPresentation("open", 1);
  });
  finalCloseTimer = scheduleSequence(finalCloseDelayAfterAckMs, emitFinalClose);
}

function scheduleSequence(delayMs, action) {
  const timer = setTimeout(() => {
    sequenceTimers.delete(timer);
    action();
  }, delayMs);
  sequenceTimers.add(timer);
  return timer;
}

function openImmediately(requestId) {
  emitResult(requestId);
  if (closeStartedAt !== undefined) {
    mark(`premature-open-received epoch=${closeEpoch} at=${Date.now()}`);
  } else if (closeEpoch > 0) {
    mark(`reopen-received-after-final epoch=${closeEpoch} at=${Date.now()}`);
  }
  emitPresentation("open", 1);
}

function stop(requestId) {
  emitResult(requestId);
  if (finalCloseTimer) clearTimeout(finalCloseTimer);
  for (const timer of sequenceTimers) clearTimeout(timer);
  setImmediate(() => process.exit(0));
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
  switch (frame.kind) {
    case "side-chat.layout":
      emitResult(requestId);
      if (
        replacementLayoutSeen &&
        frame.height === causalReleaseLayout.height &&
        frame.width === causalReleaseLayout.width
      ) {
        mark(`causal-release-layout-received epoch=${closeEpoch} at=${Date.now()}`);
        emitMatchingCloseAckAndClosingFrames();
      } else {
        emitPostReplacementCausalSequence();
      }
      break;
    case "side-chat.shortcut":
      emitResult(requestId);
      break;
    case "side-chat.open":
      openImmediately(requestId);
      break;
    case "side-chat.close":
      beginSlowClose(requestId);
      break;
    case "side-chat.toggle":
      if (closeStartedAt === undefined) {
        openImmediately(requestId);
      } else {
        openImmediately(requestId);
      }
      break;
    case "side-chat.interactive-progress":
      emitResult(requestId);
      if (closeStartedAt !== undefined && (frame.progress ?? 0) > 0.002) {
        mark(`premature-open-received epoch=${closeEpoch} at=${Date.now()}`);
      }
      emitPresentation("interactive", frame.progress ?? 0);
      break;
    case "side-chat.interactive-complete":
      if (frame.shouldOpen) {
        openImmediately(requestId);
      } else {
        beginSlowClose(requestId);
      }
      break;
    case "side-chat.stop":
      stop(requestId);
      break;
    case "command.result":
    case "chat.snapshot":
      break;
    default:
      emitResult(requestId, false, `Unsupported fixture frame: ${String(frame.kind)}`);
  }
});
input.on("close", () => process.exit(0));

emit({
  kind: "side-chat.ready",
  protocolVersion,
  requestId: "slow-close-fixture-ready",
});
