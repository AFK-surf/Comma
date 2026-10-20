// The app's side of the bridge, faked for Hermes's command-line runtime (scripts/mobile-check.ts): the device's
// key-value table in memory, an empty credential store, no network. Enough for the core to start and say that nobody
// is signed in.
var checkSaid = [];
var checkKv = {};
var checkHostTimeout = setTimeout;
var checkHostClear = clearTimeout;
var checkTimers = {};
function checkAnswer(id, json) {
  checkHostTimeout(function () {
    globalThis.commaCore.complete(id, JSON.stringify(json), null, undefined);
  }, 0);
}
globalThis.commaNative = {
  call: function (id, op) {
    if (op === "abort") return;
    if (op === "session.vault")
      return checkAnswer(id, {
        status: "readable",
        active: null,
        pending: [],
        cleanup: { revocation: "idle" },
      });
    checkHostTimeout(function () {
      globalThis.commaCore.complete(id, null, "offline in the check: " + op, undefined);
    }, 0);
  },
  callSync: function (op, json) {
    var a = JSON.parse(json);
    if (op === "sql.open") return '{"value":1}';
    if (op === "sql.exec" || op === "sql.close" || op === "session.gate")
      return '{"value":null}';
    if (op === "sql.all" && /FROM kv/.test(a.sql))
      return JSON.stringify({
        value: a.params[0] in checkKv ? [[checkKv[a.params[0]]]] : [],
      });
    if (op === "sql.run" && /INTO kv/.test(a.sql)) {
      checkKv[a.params[0]] = a.params[1];
      return '{"value":1}';
    }
    if (op === "sql.run" && /DELETE FROM kv/.test(a.sql)) {
      delete checkKv[a.params[0]];
      return '{"value":1}';
    }
    return JSON.stringify({ error: "not in the check: " + op });
  },
  emit: function (json) {
    checkSaid.push(json);
  },
  fatal: function (reason) {
    print("FATAL " + reason);
  },
  monotonic: function () {
    return Date.now();
  },
  random: function (n) {
    var b = new Uint8Array(n);
    for (var i = 0; i < n; i++) b[i] = Math.floor(Math.random() * 256);
    return b.buffer;
  },
  setTimer: function (id, ms) {
    checkTimers[id] = checkHostTimeout(function () {
      globalThis.commaTimer(id);
    }, ms);
  },
  clearTimer: function (id) {
    checkHostClear(checkTimers[id]);
  },
  log: function (level, message) {
    print("LOG" + level + " " + message);
  },
};
