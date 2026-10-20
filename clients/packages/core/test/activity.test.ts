import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import { ACTIVITY_REPORT_MS } from "../src/activity.ts";
import { FakeDesktop } from "../src/testing/fake-desktop.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const PATH = "/v1/comma/auth/session/activity";

function setup(
  desktop: FakeDesktop | null = new FakeDesktop(),
  before: (host: FakeHost, core: ReturnType<typeof startTestCore>) => void = () => {}
) {
  const host = new FakeHost();
  if (desktop) host.desktop = desktop;
  host.api.on("POST", PATH, { ok: true });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  before(host, core);
  core.observeSession(signedIn());
  const reports = () => host.api.seen("POST", PATH).length;
  return { host, core, client, desktop, time: host.time!, reports };
}

describe("the person's presence at the desktop", () => {
  it("is reported each minute only while the computer has recent input and Home replies show", async () => {
    const t = setup();
    // At once on signing in, then each minute.
    await t.time.pass(100);
    expect(t.reports()).toBe(1);
    await t.time.pass(ACTIVITY_REPORT_MS, 1_000);
    expect(t.reports()).toBe(2);

    // Five minutes without input: the person is away.
    t.desktop!.person = { idleSeconds: 300, homeRepliesShown: true };
    await t.time.pass(ACTIVITY_REPORT_MS, 1_000);
    expect(t.reports()).toBe(2);

    // Back, but a Home reply would not reach them (window closed, notifications off).
    t.desktop!.person = { idleSeconds: 3, homeRepliesShown: false };
    await t.time.pass(ACTIVITY_REPORT_MS, 1_000);
    expect(t.reports()).toBe(2);

    t.desktop!.person = { idleSeconds: 3, homeRepliesShown: true };
    await t.time.pass(ACTIVITY_REPORT_MS, 1_000);
    expect(t.reports()).toBe(3);
    // The report carries the session it is for, never a credential of its own.
    expect(t.host.api.seen("POST", PATH)[2]!.lease.sessionId).toBe("session-user-1");
  });

  it("asks nothing while signed out, and tells the session of a refused report", async () => {
    const refused: number[] = [];
    const t = setup(new FakeDesktop(), (host, core) => {
      core.session.onRejected((_lease, status) => refused.push(status));
      host.api.on("POST", PATH, json(401, { error: "unauthorized" }));
    });
    await t.time.pass(100);
    expect(t.reports()).toBe(1);
    expect(refused).toEqual([401]);

    t.core.observeSession(signedOut());
    const asked = t.desktop!.presenceAsked;
    await t.time.pass(ACTIVITY_REPORT_MS * 3, 1_000);
    expect(t.reports()).toBe(1);
    expect(t.desktop!.presenceAsked).toBe(asked);
  });

  it("is never reported where there is no desktop (the web)", async () => {
    const t = setup(null);
    await t.time.pass(ACTIVITY_REPORT_MS * 3, 1_000);
    expect(t.reports()).toBe(0);
  });

  it("plays again to the same reports, at the same times", async () => {
    const t = setup();
    await t.time.pass(ACTIVITY_REPORT_MS, 1_000);
    t.desktop!.person = { idleSeconds: 600, homeRepliesShown: true };
    await t.time.pass(ACTIVITY_REPORT_MS, 1_000);
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
