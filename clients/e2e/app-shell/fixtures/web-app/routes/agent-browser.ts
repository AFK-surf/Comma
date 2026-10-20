// The browsers API an agent's remote browser needs, for
// e2e/app-shell/agent-browser.chromium.test.ts: one browser of one session,
// which the test opens and closes, and whose commands it reads back.
import type { IncomingMessage, ServerResponse } from "node:http";
import { chatSmokeTaskConversation } from "../../../../p0/chat-stub";

const participantId = "ptc_browser_worker";

const json = (response: ServerResponse, body: unknown) => {
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
};
const read = (request: IncomingMessage) =>
  new Promise<string>((resolve) => {
    let body = "";
    request.on("data", (chunk: Buffer) => {
      body += chunk.toString("utf8");
    });
    request.on("end", () => resolve(body));
  });
export function agentBrowserRoutes() {
  let active = false;
  let scopedReads = 0;
  const inputs: Record<string, unknown>[] = [];
  let control = "agent";
  let revision = 0;
  let streams = 0;
  let cleared = false;
  let storageError: string | null = null;
  // One frame of the remote page, as a JPEG in base64: the test draws it.
  let frame = "";
  const binding = () => ({
    agent_id: "agent-browser-e2e",
    session_id: "browser-e2e",
    status: "ready",
    control,
    busy: false,
    storage_error: storageError,
    updated_at: new Date(1780000000000 + revision).toISOString(),
  });
  return {
    async handle(request: IncomingMessage, url: URL, response: ServerResponse) {
      if (!/^\/v1\/comma\/workspaces\/[^/]+\/browsers/.test(url.pathname)) return false;
      if (url.pathname.endsWith("/events")) {
        streams += 1;
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.end(
          `data: ${JSON.stringify({ browser: binding(), can_control: control === "human", frame: { data: frame, tab_id: "tab", metadata: { deviceWidth: 1280, deviceHeight: 720 } } })}\n\n`
        );
        return true;
      }
      const matchesSession =
        url.searchParams.get("conversation_id") === chatSmokeTaskConversation.id &&
        url.searchParams.get("participant_id") === participantId;
      if (request.method === "GET" && matchesSession) scopedReads += 1;
      if (request.method === "POST" && url.pathname.endsWith("/clear-storage")) {
        cleared = true;
        json(response, { cleared: true });
        return true;
      }
      if (request.method !== "POST") {
        const others = [
          { ...binding(), agent_id: "another-agent", session_id: "another-session" },
        ];
        const own = active ? [binding()] : [];
        json(response, { browsers: matchesSession ? own : others });
        return true;
      }
      const command = JSON.parse(await read(request)) as {
        operation: string;
        args: { input: Record<string, unknown> };
      };
      if (command.operation === "take_control") {
        control = "human";
        revision += 1;
      }
      if (command.operation === "return_control") {
        storageError = "browser_storage_partially_saved";
        control = "agent";
        revision += 1;
      }
      if (command.operation === "input") inputs.push(command.args.input);
      if (command.operation === "close" || command.operation === "clear_storage")
        active = false;
      if (command.operation === "clear_storage") cleared = true;
      json(response, {
        ...binding(),
        status: active ? "ready" : "closed",
        tabs: [
          { tab_id: "tab", title: "Remote test page", url: "https://example.com" },
        ],
      });
      return true;
    },
    calls: {
      browserParticipant: () => participantId,
      setBrowserFrame: (data: string) => {
        frame = data;
      },
      setBrowserActive: (next: boolean) => {
        active = next;
      },
      browserState: () => ({ scopedReads, inputs: [...inputs], streams, cleared }),
    },
  };
}
