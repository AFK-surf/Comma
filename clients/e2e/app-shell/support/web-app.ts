import { beforeEach } from "vitest";
import { commands } from "vitest/browser";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import type { WebAppStubOptions } from "../fixtures/web-app/stub";
import { useFixture, type Page } from "./page";
import { onTestPageClose, pageWindow, testPage } from "./virtual-time";
import type { Exchanged } from "../../ui-runtime/scripted-peer";
import {
  exchanged,
  inWorld,
  pageWorld,
  played,
  recordedStep,
  useNodeRealm,
  viewAlone,
  type NodeRealm,
} from "./world";

declare module "vitest/browser" {
  interface BrowserCommands {
    /** The module script, the stylesheets, the body and the root's attributes of the shipped web build's index.html (vitest.config.ts). */
    webAppDocument: () => Promise<{
      script: string;
      styles: string[];
      body: string;
      root: Record<string, string>;
      coreWorker: string;
    }>;
  }
}

const session = { email: "smoke@comma.local", token: "web-app-session" };

// The entries of `options` that have a value.
const defined = <T extends object>(options: T) =>
  Object.fromEntries(
    Object.entries(options).filter(([, value]) => value !== undefined)
  ) as { [K in keyof T]?: Exclude<T[K], undefined> };

/**
 * What a test's page and its core exchanged in a run of the whole world
 * (e2e/app-shell/records): the contract between the view and the core for
 * that scenario. The server's origin, a port of its own on every run, is
 * written as `recordedOrigin`.
 */
type WorldRecord = {
  userId: string;
  /** The seed of the page that made the record: its worker's randomness follows from it. */
  seed: number;
  /** What the server was started with. */
  start: WebAppStubOptions;
  entries: Exchanged[];
};
const recordedOrigin = "http://comma-stub.test";
type StubInfo = { origin: string; userId: string };

/**
 * The spec's pages run the web app itself, from its shipped build
 * (apps/web/dist, `pnpm build:web`): the app, its client core in a worker of
 * its own, and the chat stub server its Playwright specs use
 * (e2e/p0/chat-stub.ts), started with `stubOptions`, or with what it gives
 * for the test's name (data only: the stub runs in a process of its own).
 * `routes` names an API of the spec's own beside the stub's
 * (../fixtures/web-app/stub.ts).
 * The three are realms of one world
 * (`./world`): a test's steps and assertions move its time.
 *
 * With `records`, a test whose scenario has a record runs the view alone:
 * no core worker and no server, the core's part played from the record, and
 * the view must send the core what the record has. `COMMA_WORLD_RECORDS=record`
 * runs the whole world and writes the records; `=check` runs the whole world
 * and fails where it parts from them.
 */
export function useWebApp(
  stubOptions:
    | WebAppStubOptions["stub"]
    | ((test: string) => WebAppStubOptions["stub"]) = {},
  {
    routes,
    records = false,
    api,
    hold,
    responses,
    evaluationsStep = false,
  }: Pick<WebAppStubOptions, "routes"> & {
    records?: boolean;
    /** The product API for the test's name, if not the stub's (`WebAppStubOptions.api`). */
    api?: (test: string) => WebAppStubOptions["api"];
    /** The requests the stub holds for the test's name (`WebAppStubOptions.hold`). */
    hold?: (test: string) => WebAppStubOptions["hold"];
    /** Fixed JSON answers for the test's name (`WebAppStubOptions.responses`). */
    responses?: (test: string) => WebAppStubOptions["responses"];
    /** Page time moves while an evaluation waits for frames (`useFixture`). */
    evaluationsStep?: boolean;
  } = {}
) {
  let mode: "whole" | "alone" | "record" | "check" = "whole";
  let file = "";
  let record: WorldRecord | undefined;
  let started: WebAppStubOptions | undefined;
  // Before the server would start: a view alone has none.
  beforeEach(async (context) => {
    mode = "whole";
    record = undefined;
    if (!records) return;
    const spec = context.task.file.name
      .replace(/^.*\//, "")
      .replace(/\.chromium\.test\.tsx?$/, "");
    file = `${spec}/${context.task.name.replaceAll(/[^A-Za-z0-9]+/g, "-")}.json`;
    const run = await commands.worldRecordMode();
    record =
      ((await commands.worldRecordRead(file)) as WorldRecord | null) ?? undefined;
    if (run === "record") mode = "record";
    else if (!record)
      throw new Error(
        `No record ${file}: run the spec once with COMMA_WORLD_RECORDS=record.`
      );
    else mode = run === "check" ? "check" : "alone";
  });
  const stubFor = (test: string) => {
    const stub = typeof stubOptions === "function" ? stubOptions(test) : stubOptions;
    return stub ? { stub } : {};
  };
  const server = useNodeRealm<StubInfo>(
    "stub",
    "e2e/app-shell/fixtures/web-app/stub.ts",
    (test: string): WebAppStubOptions =>
      (started = {
        session,
        ...stubFor(test),
        ...(routes ? { routes } : {}),
        ...defined({
          api: api?.(test),
          hold: hold?.(test),
          responses: responses?.(test),
        }),
      }),
    () => mode === "alone"
  );
  // A view alone has no server: a call of it is the record's step.
  const recorded = (): NodeRealm<StubInfo> => ({
    name: "stub",
    info: { origin: recordedOrigin, userId: record!.userId },
    origin: recordedOrigin,
    delayMs: 0,
    settle: () => Promise.resolve({ nextDue: null, sent: [] }),
    deliver: () => Promise.resolve(),
    forget: () => Promise.resolve(),
    // Before the page opens there is no record to step: the record begins
    // with the page.
    call: async (call) => (inWorld() ? recordedStep(`stub.${call}`) : undefined),
  });
  const stub = () => (mode === "alone" ? recorded() : server());
  // The app as it ships: the page loads apps/web/dist as its index.html does.
  useFixture(
    async (url) => {
      const app = await commands.webAppDocument();
      // The app's routes are in the URL's fragment.
      if (url.hash) pageWindow().location.hash = url.hash;
      // The document's root as the app's index.html has it.
      for (const [name, value] of Object.entries(app.root))
        pageWindow().document.documentElement.setAttribute(name, value);
      await testPage().mount(
        new URL(app.script, location.href).href,
        url.search,
        app.body,
        app.styles
      );
    },
    {
      world: { servers: () => (mode === "alone" ? [] : [server()]) },
      ownsUrl: true,
      evaluationsStep,
    }
  );
  return {
    /** The running test's stub server. */
    stub,
    /** Opens the app at `path`, signed in, on a device that has seen the first-launch introduction. */
    async open(
      page: Page,
      path = "/",
      { onboardingCompleted = true }: { onboardingCompleted?: boolean } = {}
    ) {
      if (mode === "alone") {
        await this.openAlone(page, record!.entries, path);
        return;
      }
      if (mode !== "whole")
        onTestPageClose(async () => {
          // The server's origin is this run's: the record names it once.
          const entries = JSON.parse(
            JSON.stringify(exchanged()).replaceAll(server().origin, recordedOrigin)
          ) as Exchanged[];
          const made: WorldRecord = {
            userId: server().info.userId,
            seed: (pageWindow() as { commaRandomSeed?: number }).commaRandomSeed ?? 0,
            start: started!,
            entries,
          };
          if (mode === "record") {
            await commands.worldRecordWrite(file, made);
            return;
          }
          const parted = entries.findIndex(
            (entry, index) =>
              JSON.stringify(entry) !== JSON.stringify(record!.entries[index])
          );
          if (parted >= 0 || entries.length !== record!.entries.length)
            throw new Error(
              `The whole world parted from the record ${file} at entry ${(parted >= 0 ? parted : entries.length) + 1}:\n  now:    ${JSON.stringify(entries[parted]).slice(0, 300)}\n  record: ${JSON.stringify(record!.entries[parted]).slice(0, 300)}`
            );
        });
      // The device's storage outlives a page: each test starts from none.
      // The page before this one is gone once its worker's locks are.
      for (;;) {
        const { held, pending } = await navigator.locks.query();
        if ((held?.length ?? 0) + (pending?.length ?? 0) === 0) break;
      }
      await commands.cdpSend("Storage.clearDataForOrigin", {
        origin: location.origin,
        storageTypes: "file_systems,indexeddb,local_storage",
      });
      // The session is an HttpOnly cookie of the server: the app never reads it.
      await commands.cdpSend("Network.setCookie", {
        name: "comma_session",
        value: session.token,
        url: stub().origin,
        httpOnly: true,
        sameSite: "Lax",
      });
      // Each page load, as Playwright's init script (e2e/helpers/browser-auth.ts):
      // the settings a page saved stay, with the introduction seen.
      await page.addInitScript(
        ({ origin, userId, defaults, seen }) => {
          localStorage.setItem("comma.apiBaseUrl", origin);
          if (!seen) return;
          const key = "comma.client-settings";
          const stored = localStorage.getItem(key);
          const settings = stored ? JSON.parse(stored) : defaults;
          const completed: string[] = settings.onboardingCompletedUserIds ?? [];
          if (completed.includes(userId)) return;
          localStorage.setItem(
            key,
            JSON.stringify({
              ...settings,
              onboardingCompletedUserIds: [...completed, userId],
            })
          );
        },
        {
          origin: stub().origin,
          userId: stub().info.userId,
          defaults: defaultCommaClientSettings,
          seen: onboardingCompleted,
        }
      );
      await page.goto(path);
    },
    /**
     * Runs `scenario` twice. First on the whole world: the app, its core
     * worker and the server. Then with the view alone: what the core told the
     * page the first time is played again, the test's calls of the server
     * are the record's steps, and the page must send the core what it sent
     * before, to the record's end. `scenario` opens the app with the `open`
     * it is given.
     */
    async bothWays(
      page: Page,
      scenario: (open: (page: Page, path?: string) => Promise<void>) => Promise<void>
    ) {
      await scenario((opened, path) => this.open(opened, path));
      const entries = exchanged();
      await scenario((opened, path) => this.openAlone(opened, entries, path));
    },
    /**
     * Opens the app again at `path` as a view alone: with no core worker and
     * no server, the core's part played from `record`, which a page of this
     * test exchanged with its worker (`exchanged()`). The device starts from
     * the same storage as that page did.
     */
    async openAlone(page: Page, entries: readonly Exchanged[], path = "/") {
      viewAlone(entries);
      await commands.cdpSend("Storage.clearDataForOrigin", {
        origin: location.origin,
        storageTypes: "local_storage",
      });
      // A test that never ran the whole world sets the device up itself.
      if (mode === "alone")
        await page.addInitScript(
          ({ origin, userId, defaults }) => {
            localStorage.setItem("comma.apiBaseUrl", origin);
            localStorage.setItem(
              "comma.client-settings",
              JSON.stringify({ ...defaults, onboardingCompletedUserIds: [userId] })
            );
          },
          {
            origin: recordedOrigin,
            userId: record!.userId,
            defaults: defaultCommaClientSettings,
          }
        );
      await page.goto(path);
      onTestPageClose(() => {
        const at = played() ?? 0;
        if (at !== entries.length) {
          const next = entries[at];
          throw new Error(
            [
              `The view alone played ${at} of the record's ${entries.length} entries.`,
              `The record's next: ${next?.dir} ${JSON.stringify(next?.data).slice(0, 200)} at ${next?.at} ms.`,
              ...(testPage().violations?.() ?? []),
              ...(testPage().pendingWork?.() ?? []).map(
                (work) => `still loading: ${work}`
              ),
              "the world's last steps:",
              ...pageWorld().log().slice(-14),
            ].join("\n")
          );
        }
      });
    },
  };
}
