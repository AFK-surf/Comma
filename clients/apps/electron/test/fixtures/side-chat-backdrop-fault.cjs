let attached = false;
let available = true;
let asyncHealthFailureScheduled = false;
let rebuildCount = 0;

const fault = process.env.COMMA_SIDE_CHAT_BACKDROP_FAULT ?? "geometry";

function fail(method) {
  if (attached && fault === method) {
    process.stderr.write(
      `[comma-side-chat-backdrop-fault] injected ${method} failure\n`
    );
    throw new Error(`injected ${method} failure`);
  }
}

module.exports = {
  // This fixture models native failures; it does not own an AppKit window.
  disableWindowAnimations() {},
  attach() {
    attached = true;
    available = true;
    if (fault === "async-health" && !asyncHealthFailureScheduled) {
      asyncHealthFailureScheduled = true;
      setTimeout(() => {
        if (!attached) return;
        available = false;
        process.stderr.write(
          "[comma-side-chat-backdrop-fault] injected async health failure\n"
        );
      }, 150).unref?.();
    }
    return true;
  },
  detach() {
    attached = false;
  },
  rebuild() {
    if (fault === "async-health") {
      available = true;
      rebuildCount += 1;
      process.stderr.write(
        `[comma-side-chat-backdrop-fault] explicit rebuild recovered count=${rebuildCount}\n`
      );
      return true;
    }
    return fault !== "rebuild";
  },
  isAvailable() {
    return available;
  },
  setRevealOffset() {
    fail("reveal");
    return true;
  },
  updateGeometry(geometry) {
    fail("geometry");
    if (process.env.COMMA_SIDE_CHAT_BACKDROP_TRACE_GEOMETRY === "1") {
      process.stderr.write(`[side-chat-geometry] ${JSON.stringify(geometry)}\n`);
    }
    return true;
  },
  updateSettings() {
    fail("settings");
    return true;
  },
};
