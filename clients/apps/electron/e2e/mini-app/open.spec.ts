import type { MiniAppSessionInfo } from "@comma/core/contract";
import { startChatSmokeStub, chatSmokeWorkspace } from "../../../../e2e/p0/chat-stub";
import { expect, test } from "../electron-test";

const email = "mini-app-open@comma.local";
const miniApp = {
  id: "habit-tracker",
  slug: "habits",
  workspace_id: chatSmokeWorkspace.id,
  name: "Habit Tracker",
  visibility: "link",
  status: "active",
  live_version: 1,
  latest_version: 2,
  storage: [],
  has_backend: true,
};

test(
  "desktop opens a workspace app, a preview and a shared app, and sends the preview's backend method",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const workspaceVia = `workspace/${chatSmokeWorkspace.id}`;
    const linkToken = "shared-habits";
    const runtimePath = `/v1/comma/apps/${miniApp.id}`;
    const stub = await startChatSmokeStub({
      sessionEmail: email,
      extraRoutes: (request, url, response) => {
        if (!url.pathname.startsWith(`${runtimePath}/`)) return false;
        request.resume();
        const reply = (status: number, body: unknown) => {
          response.writeHead(status, { "content-type": "application/json" });
          response.end(JSON.stringify(body));
          return true;
        };
        if (request.headers.authorization !== `Bearer smoke-token:${email}`)
          return reply(401, { error: "unauthorized" });
        const via = request.headers["x-comma-app-via"];
        if (via !== workspaceVia && via !== `link/${linkToken}`)
          return reply(404, { error: "not_found" });
        // The server serves live by default and accepts a preview from its workspace.
        const version =
          via === workspaceVia && request.headers["x-comma-app-version"] === "2"
            ? 2
            : 1;
        if (request.method === "POST" && url.pathname === `${runtimePath}/open`)
          return reply(200, {
            app: miniApp,
            version,
            digest: `habits-v${version}`,
            viewer: { id: "app-viewer", name: "Viewer" },
            guest: false,
          });
        if (
          request.method === "POST" &&
          url.pathname === `${runtimePath}/backend/habits`
        ) {
          if (version !== 2) return reply(409, { error: "wrong_version" });
          // The backend method travels inside the Comma POST request.
          if (request.headers["x-comma-app-method"] !== "PUT")
            return reply(405, { error: "method_not_allowed" });
          return reply(201, { saved: true });
        }
        return reply(404, { error: "not_found" });
      },
    });
    const call = (name: string, params: unknown) =>
      sharedElectron.app.evaluate(
        (_, input) =>
          (
            globalThis as unknown as {
              commaE2eCore: { call(name: string, params: unknown): Promise<unknown> };
            }
          ).commaE2eCore.call(input.name, input.params),
        { name, params }
      );
    const sessions: string[] = [];
    const open = async (
      via: { workspace: string } | { token: string },
      version?: number
    ) => {
      const info = (await call("miniApps.session.open", {
        app: miniApp.id,
        via,
        platform: "mac",
        ...(version === undefined ? {} : { version }),
      })) as MiniAppSessionInfo;
      sessions.push(info.session);
      return info;
    };
    try {
      sharedElectron.useApi(stub.server);
      await sharedElectron.signIn({ email, userId: stub.userId });

      // Main's channel reaches the utility core, then Main's credential proxy and the HTTP server.
      const live = await open({ workspace: chatSmokeWorkspace.id });
      expect(live).toMatchObject({ app: { id: miniApp.id }, version: 1 });
      const preview = await open({ workspace: chatSmokeWorkspace.id }, 2);
      expect(preview.version).toBe(2);
      expect(
        await call("miniApps.invoke", {
          session: preview.session,
          op: "backend.fetch",
          args: { path: "/habits", method: "PUT", body: '{"name":"Walk"}' },
        })
      ).toMatchObject({ status: "done", value: { status: 201 } });
      expect(await open({ token: linkToken })).toMatchObject({ version: 1 });
    } finally {
      try {
        for (const session of sessions)
          await call("miniApps.session.close", { session });
      } finally {
        await stub.close();
      }
    }
  }
);
