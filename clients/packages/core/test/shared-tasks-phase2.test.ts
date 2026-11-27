import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type {
  MiniAppBundle,
  MiniAppImageValue,
  MiniAppSessionInfo,
  ProductInboxListResult,
  TaskSummariesValue,
} from "../src/contract.ts";
import { decodeInlineMessagePart } from "../src/chat/model/inlineElementContract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const workspace = { group_id: "g_home", id: "wsp_1", name: "Work", status: "ready" };

function tar(files: Record<string, string>): Uint8Array {
  const blocks: Uint8Array[] = [];
  const enc = new TextEncoder();
  for (const [name, text] of Object.entries(files)) {
    const data = enc.encode(text);
    const header = new Uint8Array(512);
    header.set(enc.encode(name), 0);
    header.set(enc.encode(data.length.toString(8).padStart(11, "0")), 124);
    header[156] = 0x30;
    header.set(enc.encode("ustar"), 257);
    blocks.push(header);
    const body = new Uint8Array(Math.ceil(data.length / 512) * 512);
    body.set(data);
    blocks.push(body);
  }
  blocks.push(new Uint8Array(1024));
  const out = new Uint8Array(blocks.reduce((n, b) => n + b.length, 0));
  let offset = 0;
  for (const b of blocks) {
    out.set(b, offset);
    offset += b.length;
  }
  return out;
}

const viaHeader = (r: SeenRequest) =>
  r.headers?.find(([name]) => name.toLowerCase() === "x-comma-app-via")?.[1];

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return () => values.get(key) as T | undefined;
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch };
}

describe("Shared Tasks Phase 2 core support", () => {
  it("accepts hosted collaborative tasks in isolated groups in tasks list and taskSummaries", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/g_home/conversations", {
      data: [
        {
          id: "t_local",
          group_id: "g_home",
          kind: "agent_task",
          status: "running",
          title: "Local task",
          updated_at: 1_700_000_000,
        },
        {
          id: "t_collab",
          group_id: "g_collab_iso",
          kind: "agent_task",
          status: "running",
          title: "Shared launch plan",
          updated_at: 1_700_000_100,
          together: ["u2"],
        },
      ],
      has_more: false,
    });
    t.api.on("GET", "/v1/comma/groups/g_home/task-summaries", {
      data: [
        {
          id: "t_collab_2",
          group_id: "g_collab_iso_2",
          kind: "agent_task",
          status: "running",
          title: "Partner review",
          updated_at: 1_700_000_200,
          together: ["u3"],
        },
      ],
    });

    try {
      const readList = t.watch<ProductInboxListResult>({
        topic: "tasks",
        workspace: "wsp_1",
      });
      const readSummaries = t.watch<TaskSummariesValue>({
        topic: "taskSummaries",
        group: "g_home",
        ids: "t_collab_2",
      });
      await t.time.pass(100);

      const list = readList();
      expect(list?.errorCode).toBeUndefined();
      expect(list?.items.map((i) => [i.conversationId, i.groupId])).toEqual([
        ["t_local", "g_home"],
        ["t_collab", "g_collab_iso"],
      ]);

      const summaries = readSummaries();
      expect(summaries?.pending).toBeUndefined();
      expect(summaries?.summaries[0]?.id).toBe("t_collab_2");
      expect(summaries?.summaries[0]?.group_id).toBe("g_collab_iso_2");
    } finally {
      t.client.close();
      await t.core.close();
    }
  });

  it("still rejects non-collaborative conversations from another group", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/g_home/conversations", {
      data: [
        {
          id: "t_foreign",
          group_id: "g_other",
          kind: "agent_task",
          status: "running",
          title: "Should be rejected",
          updated_at: 1_700_000_000,
        },
      ],
      has_more: false,
    });

    try {
      const readList = t.watch<ProductInboxListResult>({
        topic: "tasks",
        workspace: "wsp_1",
      });
      await t.time.pass(100);
      expect(readList()?.errorCode).toBe("protocol_mismatch");
    } finally {
      t.client.close();
      await t.core.close();
    }
  });

  it("preserves conversation_ref.group_id when decoding inline task blocks", () => {
    const decoded = decodeInlineMessagePart({
      type: "conversation_ref",
      presentation: "inline",
      kind: "agent_task",
      conversation_id: "cnv_collab_1",
      group_id: "g_collab_iso",
      title: "Q4 Pricing Review",
      status: "running",
    });
    expect(decoded).toMatchObject({
      kind: "inline-task",
      task: {
        conversationId: "cnv_collab_1",
        groupId: "g_collab_iso",
        title: "Q4 Pricing Review",
        unavailable: false,
      },
    });
  });

  it("supports MiniAppVia collaboration headers, bundle endpoint, and miniAppImage topic", async () => {
    const t = setup();
    const openRequests: SeenRequest[] = [];
    const bundleRequests: SeenRequest[] = [];
    const imageRequests: SeenRequest[] = [];

    t.api.on("POST", "/v1/comma/apps/app_9/open", (req) => {
      openRequests.push(req);
      return json(200, {
        app: {
          id: "app_9",
          slug: "budget-tracker",
          workspace_id: "wsp_host",
          name: "Budget Tracker",
          description: "Shared tracker",
          icon_url: null,
          screenshot_urls: [],
          repo: { owner: "me", name: "comma-app-budget" },
          visibility: "private",
          status: "active",
          live_version: 4,
          latest_version: 4,
          author: { name: "Ada" },
          capabilities: ["identity.basic"],
          egress: [],
          storage: ["app"],
          has_backend: false,
          secrets: [],
          grants: [],
          installed: false,
          install: null,
          created_at: "2026-10-01T00:00:00Z",
          updated_at: "2026-10-01T00:00:00Z",
        },
        version: 4,
        digest: "digest-collab-app-9",
        viewer: { id: "u_member", name: "Member", avatar_url: null },
        guest: false,
      });
    });

    t.api.on(
      "GET",
      "/v1/comma/collaborations/g_collab/t_collab/apps/app_9/versions/4/bundle",
      (req) => {
        bundleRequests.push(req);
        return {
          status: 200,
          headers: [["content-type", "application/x-tar"]],
          body: tar({ "index.html": "<!doctype html><h1>Budget</h1>" }),
        };
      }
    );

    t.api.on("GET", "/v1/comma/apps/app_9/cover", (req) => {
      imageRequests.push(req);
      return {
        status: 200,
        headers: [["content-type", "image/png"]],
        body: new Uint8Array([137, 80, 78, 71]),
      };
    });

    try {
      const opened = (await t.client.call("miniApps.session.open", {
        app: "app_9",
        via: { collaboration: { group: "g_collab", task: "t_collab" } },
        platform: "web",
        version: 4,
      })) as MiniAppSessionInfo;
      expect(opened.app.id).toBe("app_9");
      expect(viaHeader(openRequests[0]!)).toBe("collaboration/g_collab/t_collab");

      const bundle = (await t.client.call("miniApps.bundle", {
        session: opened.session,
      })) as MiniAppBundle;
      expect(bundleRequests).toHaveLength(1);
      expect(bundle.files.some((f) => f.path === "index.html")).toBe(true);

      const readCover = t.watch<MiniAppImageValue>({
        topic: "miniAppImage",
        url: "/v1/comma/apps/app_9/cover?v=4",
        collaborationGroup: "g_collab",
        collaborationTask: "t_collab",
      });
      await t.time.pass(100);

      const cover = readCover();
      expect(cover?.status).toBe("ready");
      expect(cover?.src).toMatch(/^data:image\/png;base64,/);
      expect(viaHeader(imageRequests[0]!)).toBe("collaboration/g_collab/t_collab");
    } finally {
      t.client.close();
      await t.core.close();
    }
  });
});
