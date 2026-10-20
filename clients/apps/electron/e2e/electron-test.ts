import { execFileSync, type ChildProcess } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises";
import type { Server } from "node:http";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  _electron,
  test as base,
  type ElectronApplication,
  type Page,
} from "@playwright/test";
import { closeElectronTestApp, trackElectronTestApp } from "./close-electron-test-app";
import { describeElectronMain } from "./electron-main-diagnostics";
import { startElectronTestServer } from "./electron-test-server";
import type { ElectronE2eStartHookEnv } from "../src/main/e2e-start-hooks";

export { expect } from "@playwright/test";

/**
 * Every e2e Electron shares the `com.github.Electron` identity, and its close
 * kills the process. After such exits macOS can answer the next launch with a
 * modal "reopen windows?" alert on Main's thread, which blocks `ready`. Test
 * apps never restore windows (an argument-domain default).
 */
export const electronMacLaunchArgs =
  process.platform === "darwin" ? ["-ApplePersistenceIgnoreState", "YES"] : [];

/**
 * What a launch gives Main before the app's own code runs. Each function runs in Main, as an `app.evaluate` function
 * does: it sees only its arguments. A spec gives here what it would otherwise change in a running app (a path, a
 * protocol handler, a stub of a native dialog), so no code of the app runs without it.
 */
export interface ElectronMainSetup<Arg = undefined> {
  /** Runs before the app's code is loaded. Electron is not ready. */
  beforeApp?: (electron: typeof import("electron"), arg: Arg) => void;
  /** Runs when Electron is ready, before any `ready` code of the app (sessions and protocols exist). */
  whenReady?: (electron: typeof import("electron"), arg: Arg) => void;
  /** Given to both; JSON. */
  arg?: Arg;
}

/** Playwright's launch options, and what the launch gives Main. */
export type ElectronLaunchOptions<Arg = undefined> = NonNullable<
  Parameters<typeof _electron.launch>[0]
> & {
  main?: ElectronMainSetup<Arg> | undefined;
  /**
   * `reduce` (the default): every window of the app prefers reduced motion, so the app's animations and transitions
   * take no time and an action does not wait for one to end. `full` for a test of the motion itself.
   */
  motion?: "reduce" | "full";
};

// The Playwright projects run from `clients`, as the specs' own paths assume.
const mainSetupPreload = resolve(
  process.cwd(),
  "apps/electron/e2e/electron-main-setup.cjs"
);

/**
 * The appearance Main reads from the OS, pinned to the color scheme Playwright gives the renderers (`colorScheme`,
 * light unless the launch says dark). Without it Main follows the machine: on a dark desktop `nativeTheme` reported
 * dark to Main while every renderer saw light. An argument-domain default, as the restore default above.
 */
function electronMacAppearanceArgs(colorScheme: ElectronLaunchOptions["colorScheme"]) {
  if (process.platform !== "darwin") return [];
  if (colorScheme === "dark") return ["-AppleInterfaceStyle", "Dark"];
  if (colorScheme === undefined || colorScheme === "light")
    return ["-NSRequiresAquaSystemAppearance", "YES"];
  return [];
}

interface TestCertificate {
  key: Buffer;
  cert: Buffer;
  /** The SHA-256 of its public key, base64: what Chromium's SPKI trust list names. */
  spki: string;
}

let testCertificate: TestCertificate | undefined;

/**
 * The certificate of the HTTPS test servers (127.0.0.1 and localhost): every app launched here trusts it from its
 * start, so no request of the app meets it untrusted. A test does not give an app trust itself: trust given while
 * the app runs (`setCertificateVerifyProc`) reaches its network service later than a request may.
 */
export function electronTestCertificate(): TestCertificate {
  if (testCertificate) return testCertificate;
  const directory = mkdtempSync(join(tmpdir(), "comma-electron-test-cert-"));
  try {
    const config = join(directory, "openssl.cnf");
    writeFileSync(
      config,
      [
        "[req]",
        "prompt = no",
        "distinguished_name = distinguished_name",
        "x509_extensions = extensions",
        "[distinguished_name]",
        "CN = 127.0.0.1",
        "[extensions]",
        "subjectAltName = IP:127.0.0.1,DNS:localhost",
        "keyUsage = critical,digitalSignature",
        "extendedKeyUsage = serverAuth",
      ].join("\n")
    );
    // prettier-ignore
    execFileSync("openssl", [
      "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
      "-keyout", join(directory, "key.pem"), "-out", join(directory, "cert.pem"),
      "-days", "2", "-config", config, "-extensions", "extensions",
    ], { stdio: "ignore" });
    const cert = readFileSync(join(directory, "cert.pem"));
    const spki = createHash("sha256")
      .update(
        new X509Certificate(cert).publicKey.export({ type: "spki", format: "der" })
      )
      .digest("base64");
    testCertificate = { key: readFileSync(join(directory, "key.pem")), cert, spki };
    return testCertificate;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

interface LaunchedApp {
  app: ElectronApplication;
  /** Read once at launch: Playwright's `app.process()` throws after the app closes. */
  child: ChildProcess;
  /** The test that launched it; undefined for a beforeAll or worker launch. */
  testId: string | undefined;
  /** What it was launched with, to name it when a test leaves it running. */
  args: readonly string[];
  /** What operations on it are waiting for now (`electronWait`). */
  waits: Set<ElectronWait>;
  output: string;
}

interface ElectronWait {
  what: string;
  observe: () => Promise<unknown>;
}

/**
 * Runs `work`, an operation that returns only once something outside its call has happened in `app`. A wait has no
 * deadline of its own, so one that never ends stops at the test's limit: the failed test's report then names what
 * it waited for (`what`) and what `observe` reads from the app at that moment, the state the wait last saw.
 */
export async function electronWait<Result>(
  app: ElectronApplication,
  what: string,
  observe: () => Promise<unknown>,
  work: () => Promise<Result>
): Promise<Result> {
  const waits = [...launched].find((entry) => entry.app === app)?.waits;
  const wait = { what, observe };
  waits?.add(wait);
  try {
    return await work();
  } finally {
    waits?.delete(wait);
  }
}

/**
 * The machine's time of day (UTC, to the millisecond), for the report of a failed test only: it puts what the test
 * process saw (a request to its server, a step it made) in one order with what Main recorded, which reads the same
 * clock. Nothing waits on it and nothing compares it.
 */
export function electronReportTime(): string {
  // ast-grep-ignore: ts-test-clock -- a time of day in a failed test's report: nothing waits on it or compares it.
  return new Date().toISOString().slice(11, 23);
}

/** Bounds each read of a wait's state: Main may be the thing that is stuck. */
const observeBoundMs = 5_000;

async function describeWaits({ waits }: LaunchedApp): Promise<string> {
  const lines: string[] = [];
  for (const { what, observe } of waits) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const observed = await Promise.race([
      observe().catch((error: unknown) => `(could not be read: ${String(error)})`),
      new Promise<string>((giveUp) => {
        // ast-grep-ignore: ts-test-timer -- bounds a failed test's diagnostics, as the diagnostic tools' own bound.
        timer = setTimeout(
          () => giveUp(`(Main did not answer within ${observeBoundMs}ms)`),
          observeBoundMs
        );
      }),
    ]);
    clearTimeout(timer);
    lines.push(
      `Waiting for: ${what}\nLast observed: ${JSON.stringify(observed, null, 2)}`
    );
  }
  return lines.join("\n\n");
}

/** Something a test made through the framework: a test server, a temporary directory. */
interface TestResource {
  /** The test that made it; undefined when a beforeAll or a worker fixture did. */
  testId: string | undefined;
  /** Names it in the error of the test that left it. */
  name: string;
  /** The test must end it itself (a server); otherwise the framework ends it for the test (a directory). */
  testEnds: boolean;
  open(): boolean;
  dispose(): Promise<void> | void;
}

const outputLimit = 64 * 1024;
const launched = new Set<LaunchedApp>();
const resources = new Set<TestResource>();
let runningTestId: string | undefined;

/**
 * Records a resource made for the running test, which must end it: if the test passes and the resource is still
 * open at its end, the test fails and names it (see `test` below); it is then disposed. One made in a beforeAll or
 * by a worker fixture belongs to no test. Returns a function that forgets it, for the resource's own close.
 */
export function trackElectronTestResource(
  resource: Omit<TestResource, "testId" | "testEnds">,
  /** One a worker fixture makes while a test sets it up belongs to no test. */
  { worker = false }: { worker?: boolean } = {}
): () => void {
  const entry = {
    ...resource,
    testEnds: true,
    testId: worker ? undefined : runningTestId,
  };
  resources.add(entry);
  return () => resources.delete(entry);
}

/**
 * A temporary directory for the running test (a profile, a downloads folder). The framework removes it when the
 * test ends, after the test's apps: a test does not remove it. One made in a beforeAll belongs to no test and is
 * the caller's to remove.
 */
export async function electronTestDirectory(prefix: string): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  resources.add({
    testId: runningTestId,
    name: `directory ${directory}`,
    testEnds: false,
    open: () => true,
    dispose: () => rm(directory, { recursive: true, force: true }),
  });
  return directory;
}

/**
 * Playwright's Electron launcher. Every app starts with the environment a test relies on, given at launch and not
 * to a running app: the macOS launch defaults, trust in the HTTPS test servers' certificate
 * (`electronTestCertificate`), one color scheme for Main and the renderers, reduced motion (`motion`), and what the
 * launch gives for Main (`main`). It records the app for failure diagnostics and for the test's end (see `test`).
 */
/** The window prefers reduced motion (`ElectronLaunchOptions.motion`). */
function reduceMotion(page: Page) {
  void page.emulateMedia({ reducedMotion: "reduce" }).catch(() => undefined);
}

export const electron = {
  async launch<Arg = undefined>(
    options: ElectronLaunchOptions<Arg> = {},
    /** A worker's shared app (`sharedElectron`): no test owns it, so a test's end does not end it. */
    { shared = false }: { shared?: boolean } = {}
  ): Promise<ElectronApplication> {
    // Two apps on one desktop take CPU and focus from each other: a test's own app runs alone.
    if (!shared) await parkSharedApp?.();
    const { main, motion = "reduce", ...playwrightOptions } = options;
    const args = [
      // Before the app's script, where Electron reads it.
      ...(main ? ["-r", mainSetupPreload] : []),
      ...(options.args ?? []),
      `--ignore-certificate-errors-spki-list=${electronTestCertificate().spki}`,
      ...electronMacAppearanceArgs(options.colorScheme),
      ...electronMacLaunchArgs,
    ];
    const app = await _electron.launch({
      // The launch has no deadline of its own: the test's limit stops a hang.
      timeout: 0,
      ...playwrightOptions,
      args,
      ...(main
        ? {
            env: {
              ...(options.env ?? (process.env as Record<string, string>)),
              COMMA_ELECTRON_E2E_MAIN_SETUP: JSON.stringify({
                beforeApp: main.beforeApp && String(main.beforeApp),
                whenReady: main.whenReady && String(main.whenReady),
                arg: main.arg,
              }),
            },
          }
        : {}),
    });
    if (motion === "reduce") {
      // Each window as it opens; an emulation lasts across the window's reloads.
      app.on("window", reduceMotion);
      for (const page of app.windows()) reduceMotion(page);
    }
    const { child } = trackElectronTestApp(app);
    const entry: LaunchedApp = {
      app,
      child,
      testId: shared ? undefined : runningTestId,
      args: options.args ?? [],
      waits: new Set(),
      output: "",
    };
    const record = (stream: string) => (chunk: Buffer | string) => {
      entry.output = `${entry.output}[${stream}] ${chunk.toString()}`.slice(
        -outputLimit
      );
    };
    child.stdout?.on("data", record("out"));
    child.stderr?.on("data", record("err"));
    // An app that exits while its test runs stays listed until the test ends:
    // a failed test reports why it exited (an uncaught exception in Main
    // prints its stack).
    child.once("exit", () => {
      if (entry.testId === undefined || entry.testId !== runningTestId)
        launched.delete(entry);
    });
    launched.add(entry);
    return app;
  },
};

/** What an app launched here wrote to stdout and stderr (the tail a failed test attaches). */
export function electronMainOutput(app: ElectronApplication): string {
  return [...launched].find((entry) => entry.app === app)?.output ?? "";
}

const running = ({ child }: LaunchedApp) => {
  return child.exitCode === null && child.signalCode === null;
};

/**
 * The worker's product app (`sharedElectron`), at a new install's state for each test that takes it: Main and its
 * client core as launched, signed out, with no data on the device.
 */
export interface SharedElectronApp {
  readonly app: ElectronApplication;
  /** The main window it opened (signed out). */
  readonly mainWindow: Page;
  /** Its `--user-data-dir`, the same for every test until the app is launched again (after a failed test). */
  readonly userDataDir: string;
  /** Its Downloads folder, given at launch, the same for every test until the app is launched again. A test that downloads removes what it saved. */
  readonly downloadsDir: string;
  /** Hands the app's Comma API requests to `stub` (the test's stub server) until the test ends. */
  useApi(stub: Server): void;
  /**
   * Signs in as `account` with the product's own email sign-in calls to the core, the account's first-run onboarding
   * recorded as done first, as the app records it; done once the main window is signed in. The test's stub answers
   * the sign-in (`startSessionProjectionStub` does).
   */
  signIn(account: { email: string; userId: string }): Promise<void>;
}

/** The worker's app: launched for its first test, reset for each test after, launched again after a failed one. */
interface WorkerElectron {
  /** The app for the next test, with the start hooks of `env` (`electronE2eStartHookEnv`). */
  forTest(env: ElectronE2eStartHookEnv): Promise<SharedElectronApp>;
  /**
   * The test that had it ended; a failed one leaves it to be replaced, not reset. A passed one that left Main changed
   * (`changedInMain`) fails, and the app is replaced too.
   */
  ended(passed: boolean): Promise<void>;
  close(): Promise<void>;
}

/** Closes the worker's shared app, if it runs; its next test launches it again (`startWorkerElectron`). */
let parkSharedApp: (() => Promise<void>) | undefined;

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMainEntry = resolve(electronAppDir, ".vite/build/main.js");

/**
 * Playwright's test with one automatic fixture: when a test fails or times out
 * while an app it launched is still running, it attaches Main's thread stacks,
 * any visible native alert text and Main's recent output to the report. An app
 * the test launched that already exited attaches its exit and recent output. A
 * timed-out test never reaches its own close, so this runs before any
 * `closeElectronTestApp`. That app is then killed; its Main may be blocked and
 * would otherwise hold the worker's teardown. If an operation on the app was
 * still waiting (`electronWait`), the report first says for what, and the
 * state it last saw.
 *
 * A test that passed must have ended what it started: an app it launched that
 * still runs, or a resource it made that is still open (a test server), fails
 * the test with the names of what it left, and is then ended here. Left alone
 * it would run into the next test, which then fails for no reason of its own.
 * What a beforeAll or a worker fixture started belongs to no test.
 */
export const test = base.extend<
  {
    electronFailureDiagnostics: void;
    sharedElectron: SharedElectronApp;
    /**
     * The start hooks the test's shared app has (`electronE2eStartHookEnv`, as `test.use`): a reset gives them, so
     * they do not take a launch of their own.
     */
    sharedElectronEnv: ElectronE2eStartHookEnv;
  },
  { workerElectron: WorkerElectron }
>({
  workerElectron: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const worker = await startWorkerElectron();
      try {
        await use(worker);
      } finally {
        await worker.close();
      }
    },
    { scope: "worker" },
  ],
  sharedElectronEnv: [{}, { option: true }],
  sharedElectron: async (
    { workerElectron, sharedElectronEnv, electronFailureDiagnostics: _diagnostics },
    use,
    testInfo
  ) => {
    // The shared app's tests run as one project (`electron-shell-shared`): one in another launches it again.
    if (!testInfo.tags.includes("@shared-app"))
      throw new Error('A test that takes sharedElectron is tagged "@shared-app".');
    const shared = await workerElectron.forTest(sharedElectronEnv);
    await use(shared);
    await workerElectron.ended(testInfo.status === testInfo.expectedStatus);
  },
  electronFailureDiagnostics: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use, testInfo) => {
      runningTestId = testInfo.testId;
      try {
        await use();
      } finally {
        runningTestId = undefined;
      }
      const own = [...launched].filter((entry) => entry.testId === testInfo.testId);
      const exited = own.filter((entry) => !running(entry));
      for (const entry of exited) launched.delete(entry);
      const ownResources = [...resources].filter(
        (resource) => resource.testId === testInfo.testId
      );
      for (const resource of ownResources) resources.delete(resource);
      const stillOpen = ownResources.filter((resource) => resource.open());
      if (testInfo.status === testInfo.expectedStatus) {
        const stillRunning = own.filter(running);
        for (const entry of stillRunning) {
          launched.delete(entry);
          if (entry.child.pid !== undefined) killProcessGroup(entry.child.pid);
        }
        for (const resource of stillOpen) await resource.dispose();
        const left = [
          ...stillRunning.map(
            ({ child, args }) => `Electron app ${child.pid} (${args.join(" ")})`
          ),
          ...stillOpen
            .filter((resource) => resource.testEnds)
            .map((resource) => resource.name),
        ];
        if (left.length > 0) {
          const names = left.map((name) => `  ${name}`).join("\n");
          throw new Error(
            `The test passed but left running what it started:\n${names}\nEnd each in the test (closeElectronTestApp, the server's close).`
          );
        }
        return;
      }
      for (const { child, output } of exited) {
        await testInfo.attach(`electron-main-${child.pid}-exited`, {
          body: `Electron main process ${child.pid} exited (code ${child.exitCode}, signal ${child.signalCode}).\n\nRecent Main output:\n${output}`,
          contentType: "text/plain",
        });
      }
      for (const entry of [...launched].filter(running)) {
        const pid = entry.child.pid;
        if (pid === undefined) continue;
        // First: what the test was waiting for is the reason it stopped.
        if (entry.waits.size > 0)
          await testInfo.attach(`electron-waiting-${pid}`, {
            body: await describeWaits(entry),
            contentType: "text/plain",
          });
        await testInfo.attach(`electron-main-${pid}`, {
          body: `${await describeElectronMain(pid)}\n\nRecent Main output:\n${entry.output}`,
          contentType: "text/plain",
        });
        // What each window showed (the projects take no screenshot of their own: see the config).
        for (const [index, window] of entry.app.windows().entries()) {
          const body = await window
            // ast-grep-ignore: ts-test-deadline -- bounds a failed test's diagnostics: a hidden window draws no frame.
            .screenshot({ timeout: observeBoundMs })
            .catch(() => undefined);
          if (body)
            await testInfo.attach(`electron-window-${pid}-${index}`, {
              body,
              contentType: "image/png",
            });
        }
        if (entry.testId === testInfo.testId) killProcessGroup(pid);
      }
      // After the test's apps: a directory may be one's profile.
      for (const resource of stillOpen)
        await Promise.resolve(resource.dispose()).catch(() => undefined);
    },
    { auto: true },
  ],
});

function killProcessGroup(pid: number) {
  try {
    // Playwright starts Electron as the leader of its own process group.
    process.kill(process.platform === "win32" ? pid : -pid, "SIGKILL");
  } catch {
    // It exited after the check.
  }
}

/**
 * One app per worker on one data directory. Its API base URL is a route on this worker (`useApi`): each test points it
 * at its own stub. Between tests the app resets through its client core (`app.reset`) and the next test starts once
 * Main started again and the new main window shows no one signed in.
 */
async function startWorkerElectron(): Promise<WorkerElectron> {
  const api = await startApiRoute();
  const root = await mkdtemp(join(await realpath(tmpdir()), "comma-electron-shared-"));
  let launches = 0;
  let userDataDir = "";
  let downloadsDir = "";
  let current: { app: ElectronApplication; mainWindow: Page } | undefined;
  let used = false;
  let broken = false;

  /** Ends an app that failed a test (or exited), once its Main has exited. Playwright lets go of it then. */
  const discard = async (app: ElectronApplication) => {
    const { child } = trackElectronTestApp(app);
    const exited = childRunning(child)
      ? new Promise<void>((done) => child.once("exit", () => done()))
      : Promise.resolve();
    killProcessGroup(child.pid!);
    await exited;
  };

  const launch = async (hooks: ElectronE2eStartHookEnv) => {
    const {
      ELECTRON_RUN_AS_NODE: _electronRunAsNode,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: _startupEmail,
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: _startupToken,
      ...env
    } = process.env;
    // A data directory of its own: one a discarded app left is not reused.
    userDataDir = join(root, `user-data-${++launches}`);
    // Downloads go to the worker's folder, never the machine's.
    downloadsDir = join(root, `downloads-${launches}`);
    await mkdir(downloadsDir);
    const app = await electron.launch(
      {
        args: [electronMainEntry, "--lang=en-US", `--user-data-dir=${userDataDir}`],
        cwd: electronAppDir,
        env: { ...env, ...hooks, COMMA_API_BASE_URL: api.baseUrl, NODE_ENV: "test" },
        main: {
          arg: downloadsDir,
          beforeApp: ({ app: nativeApp }, path) => nativeApp.setPath("downloads", path),
        },
      },
      { shared: true }
    );
    const mainWindow = await startedMainWindow(app, { reset: false });
    await recordMainAsLaunched(app);
    return { app, mainWindow };
  };

  const reset = async (app: ElectronApplication, hooks: ElectronE2eStartHookEnv) => {
    // Runs in Main: the test surface `exposeElectronE2eCore` installs.
    await app.evaluate(
      (_main, env) =>
        (
          globalThis as unknown as {
            commaE2eCore: { reset(env: Record<string, string>): Promise<void> };
          }
        ).commaE2eCore.reset(env),
      hooks as Record<string, string>
    );
    return { app, mainWindow: await startedMainWindow(app, { reset: true }) };
  };

  parkSharedApp = async () => {
    if (!current) return;
    const { app } = current;
    current = undefined;
    used = false;
    if (broken || !childRunning(trackElectronTestApp(app).child)) await discard(app);
    else await closeElectronTestApp(app);
    broken = false;
  };

  return {
    async forTest(hooks) {
      if (
        current &&
        (broken || !childRunning(trackElectronTestApp(current.app).child))
      ) {
        await discard(current.app);
        current = undefined;
      }
      broken = false;
      current =
        current && used
          ? await reset(current.app, hooks)
          : (current ?? (await launch(hooks)));
      used = true;
      const { app, mainWindow } = current;
      return {
        app,
        mainWindow,
        userDataDir,
        downloadsDir,
        useApi: (stub) => api.route(stub),
        signIn: (account) => signIn(app, mainWindow, account),
      };
    },
    async ended(passed) {
      broken ||= !passed;
      api.route(undefined);
      if (broken || !current || !childRunning(trackElectronTestApp(current.app).child))
        return;
      const changed = await changedInMain(current.app);
      if (changed.length === 0) return;
      broken = true;
      throw new Error(
        `The test passed but left the shared app's Main changed:\n${changed.map((name) => `  ${name}`).join("\n")}\nA reset does not run Main's code again: put each back in the test (a finally).`
      );
    },
    async close() {
      api.route(undefined);
      await parkSharedApp?.();
      parkSharedApp = undefined;
      await api.close();
      await rm(root, { force: true, recursive: true });
    },
  };
}

/** Where Main keeps what `recordMainAsLaunched` read. */
const mainAsLaunchedKey = "comma.e2e.mainAsLaunched";

/**
 * Records in Main what a test may change there from `app.evaluate` and a reset does not undo, since it does not run
 * Main's code again: the functions of Electron's `app`, `clipboard`, `dialog` and `shell` (a stub of a native dialog,
 * of the clipboard, of opening a URL), the app's paths (`app.setPath`) and the globals. `changedInMain` compares.
 */
async function recordMainAsLaunched(app: ElectronApplication) {
  await app.evaluate((nativeModules, key) => {
    // This function runs in Main: what it calls is declared inside it.
    // oxlint-disable-next-line unicorn/consistent-function-scoping
    const functionsOf = (module: object) => {
      const functions = new Map<string, unknown>();
      for (
        let level: object | null = module;
        level && level !== Object.prototype;
        level = Object.getPrototypeOf(level) as object | null
      )
        for (const name of Object.getOwnPropertyNames(level)) {
          const value = Reflect.get(module, name) as unknown;
          if (
            name !== "constructor" &&
            typeof value === "function" &&
            !functions.has(name)
          )
            functions.set(name, value);
        }
      return { own: Object.getOwnPropertyNames(module), functions };
    };
    const paths = [
      "home",
      "appData",
      "userData",
      "sessionData",
      "temp",
      "downloads",
      "documents",
      "desktop",
      "logs",
    ] as const;
    Reflect.set(globalThis, Symbol.for(key), {
      modules: {
        app: functionsOf(nativeModules.app),
        clipboard: functionsOf(nativeModules.clipboard),
        dialog: functionsOf(nativeModules.dialog),
        shell: functionsOf(nativeModules.shell),
      },
      paths: Object.fromEntries(
        paths.map((name) => [name, nativeModules.app.getPath(name)])
      ),
      globals: Object.getOwnPropertyNames(globalThis),
    });
  }, mainAsLaunchedKey);
}

/**
 * What differs in Main from what `recordMainAsLaunched` read: a replaced or added function of a module, a path, a
 * global a test added. Main's own test surface (`commaE2e*`) comes with its starts and is not a test's.
 */
function changedInMain(app: ElectronApplication): Promise<string[]> {
  return app.evaluate((nativeModules, key) => {
    const asLaunched = Reflect.get(globalThis, Symbol.for(key)) as {
      modules: Record<string, { own: string[]; functions: Map<string, unknown> }>;
      paths: Record<string, string>;
      globals: string[];
    };
    const modules: Record<string, object> = {
      app: nativeModules.app,
      clipboard: nativeModules.clipboard,
      dialog: nativeModules.dialog,
      shell: nativeModules.shell,
    };
    const changed: string[] = [];
    for (const [name, module] of Object.entries(modules)) {
      const { own, functions } = asLaunched.modules[name]!;
      for (const [property, value] of functions)
        if (Reflect.get(module, property) !== value)
          changed.push(`${name}.${property}`);
      for (const property of Object.getOwnPropertyNames(module))
        if (!own.includes(property)) changed.push(`${name}.${property}`);
    }
    for (const [name, path] of Object.entries(asLaunched.paths))
      if (
        nativeModules.app.getPath(
          name as Parameters<typeof nativeModules.app.getPath>[0]
        ) !== path
      )
        changed.push(`app.getPath("${name}")`);
    for (const name of Object.getOwnPropertyNames(globalThis))
      if (!asLaunched.globals.includes(name) && !name.startsWith("commaE2e"))
        changed.push(`globalThis.${name}`);
    return [...new Set(changed)];
  }, mainAsLaunchedKey);
}

const childRunning = (child: ChildProcess) =>
  child.exitCode === null && child.signalCode === null;

/**
 * The app's main window once Main's start finished (every window it opens is open and a main window a reset kept has
 * loaded the app again), its document loaded and it shows no one signed in. Main exposes its test surface while it
 * starts, so a launched app's window comes first.
 */
async function startedMainWindow(
  app: ElectronApplication,
  { reset }: { reset: boolean }
) {
  const started = () =>
    app.evaluate(() =>
      (
        globalThis as unknown as { commaE2eCore: { started(): Promise<void> } }
      ).commaE2eCore.started()
    );
  if (reset) await started();
  const mainWindow = await signedOutMainWindow(app);
  if (!reset) await started();
  return mainWindow;
}

/** The app's open main window, once its document loaded and it shows no one signed in. */
async function signedOutMainWindow(app: ElectronApplication): Promise<Page> {
  const page = await loadedMainWindow(app);
  await sessionPhase(page, "signed_out");
  return page;
}

/**
 * The app's open main window, once its document loaded. Windows are taken as Playwright hears of them: none is missed
 * between a look and the wait for the next. Main says which window is its main one and when its page has loaded: a
 * page asked itself can be replaced by its own load while it answers.
 */
export async function loadedMainWindow(app: ElectronApplication): Promise<Page> {
  const seen = new Set<Page>();
  for (;;) {
    const next = app.waitForEvent("window", { timeout: 0 });
    for (const page of app.windows()) {
      if (seen.has(page) || page.isClosed()) continue;
      seen.add(page);
      const window = await app.browserWindow(page);
      const main = await window.evaluate((browserWindow) =>
        (
          globalThis as unknown as {
            commaE2eCore: { isMainWindow(window: unknown): boolean };
          }
        ).commaE2eCore.isMainWindow(browserWindow)
      );
      if (!main) continue;
      await pageLoaded(app, page);
      next.catch(() => undefined);
      return page;
    }
    await next;
  }
}

/**
 * The window that `open` opens, once its document loaded. Playwright reports the window with its first, blank
 * document: an evaluate there can run in a page its own load then replaces, taking what it set up with it.
 */
export async function openedWindow(
  app: ElectronApplication,
  open: () => Promise<unknown>
): Promise<Page> {
  const [page] = await Promise.all([app.waitForEvent("window"), open()]);
  await pageLoaded(app, page);
  return page;
}

/** Resolves once Main says the page's window has loaded its document. */
async function pageLoaded(app: ElectronApplication, page: Page) {
  const window = await app.browserWindow(page);
  await window.evaluate(
    (browserWindow) =>
      new Promise<void>((done) => {
        const contents = browserWindow.webContents;
        const loaded = () =>
          !contents.isLoadingMainFrame() &&
          contents.getURL() !== "" &&
          contents.getURL() !== "about:blank";
        if (loaded()) return done();
        const stopped = () => {
          if (!loaded()) return;
          contents.off("did-stop-loading", stopped);
          done();
        };
        contents.on("did-stop-loading", stopped);
      })
  );
}

/** Resolves once the window's session (Main's, as the bridge replays it) is in `phase`. */
async function sessionPhase(page: Page, phase: string) {
  await page.evaluate(
    (wanted) =>
      new Promise<void>((done) => {
        const { session } = (
          window as unknown as {
            commaNative: {
              session: {
                state: {
                  subscribe(listener: (state: { phase: string }) => void): () => void;
                };
              };
            };
          }
        ).commaNative;
        let stop: (() => void) | undefined;
        let reached = false;
        stop = session.state.subscribe((state) => {
          if (state.phase !== wanted || reached) return;
          reached = true;
          stop?.();
          done();
        });
        if (reached) stop();
      }),
    phase
  );
}

async function signIn(
  app: ElectronApplication,
  mainWindow: Page,
  account: { email: string; userId: string }
) {
  // The authority and generation the sign-in is made against, as the window has them; and the sign-in it leads to
  // noted from now on (a refused request can sign out again right after).
  const expected = await mainWindow.evaluate(async (userId) => {
    const scope = window as unknown as {
      commaNative: {
        appPreferences: {
          update(patch: {
            clientSettings: { onboardingCompletedUserIds: string[] };
          }): Promise<unknown>;
        };
        session: {
          state: {
            get(): Promise<{
              authority: { authorityInstanceId: string };
              generation: number;
            }>;
            subscribe(listener: (state: { phase: string }) => void): () => void;
          };
        };
      };
      commaE2eSignedIn?: Promise<void>;
    };
    await scope.commaNative.appPreferences.update({
      clientSettings: { onboardingCompletedUserIds: [userId] },
    });
    scope.commaE2eSignedIn = new Promise<void>((done) => {
      let reached = false;
      let stop: (() => void) | undefined;
      stop = scope.commaNative.session.state.subscribe((state) => {
        if (state.phase !== "signed_in" || reached) return;
        reached = true;
        stop?.();
        done();
      });
      if (reached) stop();
    });
    const state = await scope.commaNative.session.state.get();
    return {
      authorityInstanceId: state.authority.authorityInstanceId,
      generation: state.generation,
      expectedSessionId: null,
    };
  }, account.userId);
  // The product's own email sign-in calls, on Main's channel to the core.
  await app.evaluate(
    async (_main, { email, absence }) => {
      const core = (
        globalThis as unknown as {
          commaE2eCore: { call(name: string, params: unknown): Promise<unknown> };
        }
      ).commaE2eCore;
      const requested = (await core.call("session.email.request", {
        email,
        expected: absence,
      })) as
        | { ok: true; value: { attempt: unknown; challengeId: string } }
        | { ok: false; error: unknown };
      if (!requested.ok)
        throw new Error(`email sign-in: ${JSON.stringify(requested.error)}`);
      const verified = (await core.call("session.email.verify", {
        attempt: requested.value.attempt,
        challengeId: requested.value.challengeId,
        code: "654321",
      })) as { ok: boolean; error?: unknown };
      if (!verified.ok)
        throw new Error(`email sign-in: ${JSON.stringify(verified.error)}`);
    },
    { email: account.email, absence: expected }
  );
  await mainWindow.evaluate(
    () => (window as unknown as { commaE2eSignedIn: Promise<void> }).commaE2eSignedIn
  );
}

/**
 * The worker's Comma API address. Each request it takes is handed to the server of the stub the running test routed it
 * to, which answers it on the app's own connection; it answers 503 while no stub is routed. A new route closes the
 * connections the last one had open (an event stream of the app before its reset).
 */
async function startApiRoute() {
  let target: Server | undefined;
  const sockets = new Set<Socket>();
  const api = await startElectronTestServer(
    (request, response) => {
      if (target) {
        target.emit("request", request, response);
        return;
      }
      response.writeHead(503, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "no stub is routed for this test" }));
    },
    { worker: true }
  );
  api.server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  return {
    baseUrl: api.origin,
    route(stub: Server | undefined) {
      target = stub;
      for (const socket of sockets) socket.destroy();
    },
    close: api.close,
  };
}
