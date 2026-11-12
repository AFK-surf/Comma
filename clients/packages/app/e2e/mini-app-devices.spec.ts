import { expect, test } from "@playwright/test";
import type { IncomingMessage, ServerResponse } from "node:http";
import { browserNetworkArgs } from "../../../../scripts/test-network-browser.mjs";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

// A Comma app's frame is sandboxed with an opaque origin and no permissions: the browser refuses its own
// getUserMedia ("Invalid security origin"). The host page uses the device for it after the viewer's grant and sends
// the app the result over its port. This runs that chain in a real browser with a fake camera. The CI Macs have no
// audio capture (a fake microphone never starts there), so the microphone's samples are covered by MiniAppFrame's
// component test; here the microphone stops at its grant.

test.use({
  launchOptions: {
    args: [
      ...browserNetworkArgs(),
      "--use-fake-ui-for-media-stream",
      "--use-fake-device-for-media-stream",
    ],
  },
  permissions: ["camera", "clipboard-read", "clipboard-write"],
});

const capabilities = ["microphone", "camera", "clipboard.read"];
const app = {
  id: "app_tuner",
  slug: "t1n3r9",
  workspace_id: chatSmokeWorkspace.id,
  name: "Guitar tuner",
  description: "",
  icon_url: null,
  repo: null,
  visibility: "workspace",
  status: "active",
  live_version: 1,
  latest_version: 1,
  author: { name: "Ada" },
  capabilities,
  egress: [],
  secrets: [],
  grants: [] as string[],
  installed: false,
  install: null,
  storage: [],
  has_backend: false,
};

// The app: a level meter on the microphone, a photo, and a paste.
const page = `<!doctype html><html><body style="font-family:sans-serif;padding:16px">
<button id="mic">Start tuner</button> <span id="level">—</span>
<p><button id="cam">Take photo</button> <span id="size"></span></p>
<img id="photo" style="max-width:100%;border-radius:8px">
<p><button id="paste">Paste</button> <span id="clip"></span></p>
<script>
let own = "";
navigator.mediaDevices.getUserMedia({ video: true }).then(
  () => { own = "allowed"; },
  (e) => { own = e.name; }
).finally(() => { document.body.dataset.own = own; });
const show = (id, text) => { document.getElementById(id).textContent = text; };
document.getElementById("mic").onclick = async () => {
  try {
    let samples = 0;
    const mic = await comma.microphone.start((chunk) => {
      samples += chunk.length;
      let sum = 0;
      for (const s of chunk) sum += s * s;
      show("level", samples + " samples, level " + Math.sqrt(sum / chunk.length).toFixed(3));
    });
    document.body.dataset.rate = String(mic.sampleRate);
  } catch (e) { show("level", e.code + ": " + e.message); }
};
document.getElementById("cam").onclick = async () => {
  const photo = await comma.camera.capture();
  if (!photo) return show("size", "closed");
  show("size", photo.mime + " " + photo.width + "x" + photo.height);
  document.getElementById("photo").src = URL.createObjectURL(new Blob([photo.data], { type: photo.mime }));
};
document.getElementById("paste").onclick = async () => {
  try { show("clip", await comma.clipboard.read()); } catch (e) { show("clip", e.code); }
};
</script></body></html>`;

/** An uncompressed ustar archive of one `index.html`: the bundle format. */
function bundle(): Buffer {
  const data = Buffer.from(page);
  const header = Buffer.alloc(512);
  header.write("index.html", 0);
  header.write("0000644\0", 100);
  header.write(`${data.length.toString(8).padStart(11, "0")}\0`, 124);
  header.write("        ", 148);
  header.write("0", 156);
  header.write("ustar\0", 257);
  header.write("00", 263);
  const sum = header.reduce((total, byte) => total + byte, 0);
  header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148);
  return Buffer.concat([
    header,
    data,
    Buffer.alloc((512 - (data.length % 512)) % 512),
    Buffer.alloc(1024),
  ]);
}

async function appRoutes(req: IncomingMessage, url: URL, res: ServerResponse) {
  if (url.pathname === `/v1/comma/apps/${app.id}/open`) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        app,
        version: 1,
        digest: "digest-1",
        viewer: { id: "usr", name: "Ada" },
      })
    );
    return true;
  }
  if (url.pathname.endsWith(`/apps/${app.id}/versions/1/bundle`)) {
    res.writeHead(200, { "content-type": "application/x-tar" });
    res.end(bundle());
    return true;
  }
  if (url.pathname.endsWith(`/apps/${app.id}/grants`) && req.method === "PUT") {
    let body = "";
    for await (const chunk of req) body += String(chunk);
    app.grants = (JSON.parse(body) as { grants: string[] }).grants;
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(app));
    return true;
  }
  return false;
}

test("a Comma app asks for the microphone, takes a photo and pastes through its host", async ({
  page: browser,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    extraRoutes: appRoutes,
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_app",
        message_id: "msg_app",
        kind: "message",
        text: "Guitar tuner — preview version 1",
        content: [
          {
            type: "mini_app",
            version: 1,
            app_id: app.id,
            app_version: 1,
            name: app.name,
            summary: "Guitar tuner — preview version 1",
          },
        ],
      },
    ],
  });
  try {
    await installBrowserTestSession(browser, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    await browser.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await browser.getByTestId("mini-app-card-open").click();
    const panel = browser.locator(
      '[data-testid="mini-app-chrome"][data-variant="flush"]'
    );
    const tuner = panel.frameLocator('[data-testid="mini-app-frame"]');
    const shot = (name: string) =>
      browser.screenshot({
        path: testInfo.outputPath(`${name}.png`),
        animations: "disabled",
      });

    // The frame itself gets no device.
    await expect(tuner.locator("body")).toHaveAttribute("data-own", /Error$/);

    // The microphone: the grant sheet names it; a refusal answers the app.
    await tuner.getByRole("button", { name: "Start tuner" }).click();
    const grant = browser.getByTestId("mini-app-grant-sheet");
    await expect(grant).toContainText("your microphone");
    await shot("1-microphone-grant");
    await browser.getByRole("button", { name: /Don't allow/ }).click();
    await expect(tuner.locator("#level")).toHaveText(/^denied: /);
    expect(app.grants).toEqual([]);

    // The camera: the host's sheet shows the camera; the app gets the photo the viewer takes.
    await tuner.getByRole("button", { name: "Take photo" }).click();
    const camera = browser.getByTestId("mini-app-camera-sheet");
    await expect(camera.locator("video")).toHaveJSProperty("paused", false);
    await shot("3-camera-sheet");
    await browser.getByRole("button", { name: "Take photo" }).click();
    await expect(tuner.locator("#size")).toContainText(/^image\/jpeg \d+x\d+$/);
    await shot("4-photo-in-app");

    // The clipboard: each read is confirmed.
    await browser.evaluate(() => navigator.clipboard.writeText("E A D G B E"));
    await tuner.getByRole("button", { name: "Paste" }).click();
    await expect(
      browser.getByText("Let “Guitar tuner” read your clipboard?")
    ).toBeVisible();
    await shot("5-clipboard-confirm");
    await browser.getByRole("button", { name: "Paste" }).click();
    await expect(tuner.locator("#clip")).toHaveText("E A D G B E");
  } finally {
    await stub.close();
  }
});
