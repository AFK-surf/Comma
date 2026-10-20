// What the check asks of the core once the bundle has run (scripts/mobile-check.ts); what the core said is printed.
// The command-line runtime runs timers at once, in order: later is after so many turns.
function after(turns, fn) {
  if (turns === 0) fn();
  else
    checkHostTimeout(function () {
      after(turns - 1, fn);
    }, 0);
}
(function () {
  // As the app starts it: the core continues the app's gate authority.
  globalThis.commaCore.start(
    JSON.stringify({
      platform: checkPlatform,
      apiOrigin: "https://comma.invalid",
      resumed: {
        authorityInstanceId: "check",
        generation: 0,
        revision: 0,
        sessionId: null,
      },
    })
  );
  globalThis.commaCore.receive(
    JSON.stringify({ id: 1, subscribe: { topic: "session" } })
  );
  after(200, function () {
    checkSaid.forEach(function (json) {
      print("SAID " + json);
    });
  });
})();
