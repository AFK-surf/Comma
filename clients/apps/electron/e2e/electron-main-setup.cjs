// Loaded into Main before the app's own code (`-r`, see `electron.launch` in
// electron-test.ts). It runs what a launch gave for Main (`main`), so the app
// starts with it in place instead of being changed while it runs.
"use strict";
const electron = require("electron");
const { runInThisContext } = require("node:vm");

// As Playwright's loader does with its own arguments: the app reads only the
// arguments of its launch.
const at = process.argv.indexOf(__filename);
if (at > 0 && process.argv[at - 1] === "-r") process.argv.splice(at - 1, 2);

const given = process.env.COMMA_ELECTRON_E2E_MAIN_SETUP;
// A process the app starts must not run it again.
delete process.env.COMMA_ELECTRON_E2E_MAIN_SETUP;
if (given) {
  const { beforeApp, whenReady, arg } = JSON.parse(given);
  // A function written as a method (`beforeApp(electron) {}`) prints without `function`.
  const compile = (source) => {
    try {
      return runInThisContext(`(${source})`);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      return runInThisContext(`(function ${source})`);
    }
  };
  const run = (source) => {
    try {
      compile(source)(electron, arg);
    } catch (error) {
      // Electron answers an uncaught exception here with a modal alert, which
      // would hold the launch: end Main with the stack instead.
      console.error(
        `comma-e2e: the launch's Main setup failed\n${error?.stack ?? error}`
      );
      electron.app.exit(1);
    }
  };
  if (beforeApp) run(beforeApp);
  // Registered before the app's code loads, so it runs before any `ready`
  // code of the app, whether that listens for `ready` or awaits `whenReady`.
  if (whenReady) electron.app.once("ready", () => run(whenReady));
}
