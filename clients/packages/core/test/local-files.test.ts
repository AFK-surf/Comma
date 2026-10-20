import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const ws = "workspace-1";
const PATH = `/v1/comma/workspaces/${ws}/local-file-refs`;
const ref = `lfi1_${"A".repeat(43)}`;
const registered = { local_file_ref: ref, state: "registered" };
const ownerMissing = json(409, {
  action: "reissue_connector_token",
  connector_token_endpoint: `/v1/comma/workspaces/${ws}/connector-token`,
  error: "connector_reconfiguration_required",
  reason: "connector_owner_missing",
});
const input = {
  workspace: ws,
  localFileRef: ref,
  connectorRunId: "run_exact_v2_reader",
  deviceId: "dev_exact",
};

function setup() {
  const host = new FakeHost();
  // A window's channel, as Main hands the picker's over (chat intakes are per surface).
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  const register = async (params: unknown = input) => {
    const asked = client.call("localFiles.register", params).then(
      (value) => ({ value }),
      (error: { code: string; message: string; detail?: unknown }) => ({ error })
    );
    await host.time!.pass(100);
    return asked;
  };
  return { host, core, client, time: host.time!, api: host.api, register };
}

describe("a local file's route", () => {
  it("is registered with only the ref and the exact V2 Connector target", async () => {
    const t = setup();
    t.api.on("POST", PATH, json(201, registered));
    expect(await t.register()).toEqual({ value: null });
    const sent = t.api.seen("POST", PATH);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.body).toEqual({
      connector_run_id: "run_exact_v2_reader",
      local_file_index_version: 2,
      local_file_ref: ref,
      stable_device_id: "dev_exact",
    });
  });

  it("asks once more with the same request when an answer was lost or unclear", async () => {
    const t = setup();
    let n = 0;
    t.api.on("POST", PATH, () =>
      ++n === 1 ? offline("connection reset after request") : json(201, registered)
    );
    expect(await t.register()).toEqual({ value: null });
    const sent = t.api.seen("POST", PATH);
    expect(sent).toHaveLength(2);
    expect(sent[1]!.body).toEqual(sent[0]!.body);
  });

  it("calls the outcome ambiguous once a request may have made the route", async () => {
    const t = setup();
    t.api.on("POST", PATH, () => offline("response lost after commit"));
    expect(await t.register()).toMatchObject({
      error: {
        code: "local_file_unavailable",
        detail: { outcome: "ambiguous", retryable: true },
      },
    });
    expect(t.api.seen("POST", PATH)).toHaveLength(2);

    // A server failure, then an owner remediation: still ambiguous (the first may have committed).
    let n = 0;
    t.api.on("POST", PATH, () => (++n === 1 ? json(500, {}) : ownerMissing));
    expect(await t.register()).toMatchObject({
      error: {
        detail: {
          outcome: "ambiguous",
          retryable: true,
          remediation: "reissue_connector_token",
        },
      },
    });
  });

  it("calls a definite refusal rejected, retryable only when the server may take it later", async () => {
    const t = setup();
    t.api.on("POST", PATH, ownerMissing);
    expect(await t.register()).toMatchObject({
      error: {
        message: expect.stringContaining("Reconnect this workspace's Comma Connector"),
        detail: {
          outcome: "rejected",
          retryable: true,
          remediation: "reissue_connector_token",
        },
      },
    });
    t.api.on("POST", PATH, json(403, { error: "forbidden" }));
    expect(await t.register()).toMatchObject({
      error: { detail: { outcome: "rejected", retryable: false } },
    });
    t.api.on("POST", PATH, json(429, { error: "rate_limited" }));
    expect(await t.register()).toMatchObject({
      error: { detail: { outcome: "rejected", retryable: true } },
    });
    expect(t.api.seen("POST", PATH)).toHaveLength(3);
  });

  it("sends nothing for a chat intake that is not open", async () => {
    const t = setup();
    t.api.on("POST", PATH, json(201, registered));
    expect(await t.register({ ...input, intakeId: "intake-gone" })).toMatchObject({
      error: { detail: { outcome: "rejected" } },
    });
    expect(t.api.seen("POST", PATH)).toEqual([]);
  });

  it("asks no more once its chat intake closed during an unclear request, and keeps the outcome ambiguous", async () => {
    const t = setup();
    const chat = "/v1/comma/groups/grp_1/conversations/cnv_1";
    t.api
      .onStream(`${chat}/events`)
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    t.api.on("GET", chat, {
      group_id: "grp_1",
      id: "cnv_1",
      kind: "user_chat",
      title: "Thread",
      status: "completed",
      messages: [],
    });
    const lease = {
      workspaceId: ws,
      groupId: "grp_1",
      conversationId: "cnv_1",
      subscriberId: "win_main:grp_1/cnv_1",
      leaseId: crypto.randomUUID(),
    };
    await t.client.call("chat.retain", lease);
    await t.time.pass(100);
    const { intakeId } = (await t.client.call("chat.intake.claim", {
      ...lease,
      surfaceId: "win_main",
    })) as { intakeId: string };
    const answer = t.api.hold("POST", PATH);
    t.api.on("POST", PATH, json(500, {}));
    const registering = t.register({ ...input, intakeId });
    await t.time.pass(100);
    await t.client.call("chat.intake.release", { intakeId });
    answer();
    expect(await registering).toMatchObject({
      error: { detail: { outcome: "ambiguous" } },
    });
    expect(t.api.seen("POST", PATH)).toHaveLength(1);
  });

  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    let n = 0;
    t.api.on("POST", PATH, () => (++n === 1 ? json(502, {}) : json(201, registered)));
    await t.register();
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
