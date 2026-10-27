// The Mini App tools of a coding Session whose Task builds one (`start.mini_app`, tasks/tasks.ts): app_deploy makes a
// preview Version of the app from what the agent built, app_logs reads the app's recent backend log lines. Offered only
// to such a Session (listed and run); others neither see nor run them. The Router publishes through internal.apps.publish after
// the build Task is ready for review.
import type { Tasks } from "../tasks/tasks.ts";
import type { Tool } from "./mcp.ts";

type Json = any;

export const APP_DEPLOY_DESCRIPTION =
  "Deploy the Mini App this Task builds as a new preview Version. Build it first, as the repository's AGENTS.md says (dist/ with index.html; dist-worker/index.js when comma-app.json names a backend). This commits what is not committed, pushes the session branch, packs dist/, the backend, comma-app.json and the source, and sends them to Comma, which checks them and shows the preview in the Task. Returns the Version, or what to fix. Report app_id and version to the Router, which can publish with internal.apps.publish after this Task is ready for review.";
export const APP_LOGS_DESCRIPTION =
  "Read the recent backend log lines of the Mini App this Task builds (the last 200 lines of the last 15 minutes): errors its backend threw or logged. Of the latest Version, or of `version`.";

/// The tools, run through `tasks` as the session the MCP request names.
export function appTools(tasks: Tasks): Tool[] {
  const offered = (session: string) => tasks.miniApp(session) !== null;
  return [
    {
      name: "app_deploy",
      description: APP_DEPLOY_DESCRIPTION,
      inputSchema: {
        type: "object",
        properties: { notes: { type: "string", description: "What changed in this Version, in a sentence or two, for the person who reviews it." } },
        additionalProperties: false,
      },
      offered,
      run: async (session, args) => deployed(await tasks.appDeploy(session, typeof args.notes === "string" ? args.notes.trim() : "")),
    },
    {
      name: "app_logs",
      description: APP_LOGS_DESCRIPTION,
      inputSchema: {
        type: "object",
        properties: { version: { type: "integer", minimum: 1, description: "The Version whose backend to read; default the latest." } },
        additionalProperties: false,
      },
      offered,
      run: async (session, args) => {
        const version = args.version === undefined || args.version === null ? null : args.version;
        if (version !== null && !(typeof version === "number" && Number.isSafeInteger(version) && version >= 1)) throw new Error("version is a Version number (1 or more)");
        const lines = await tasks.appLogs(session, version as number | null);
        return lines.length > 0 ? lines.join("\n") : "No backend log lines in the last 15 minutes.";
      },
    },
  ];
}

/// What the agent is told of Salix's answer to a deploy: the Version, or (as a tool error) why there is none.
function deployed(answer: Json): string {
  if (answer?.error === "invalid") {
    const errors: string[] = Array.isArray(answer.errors) ? answer.errors.filter((e: unknown) => typeof e === "string") : [];
    throw new Error(`The deploy was refused; fix these and deploy again:\n${errors.map((e) => `- ${e}`).join("\n")}`);
  }
  if (typeof answer?.error === "string") throw new Error(`The deploy failed (${answer.error})${typeof answer.message === "string" ? `: ${answer.message}` : ""}`);
  if (typeof answer?.version !== "number") throw new Error("Comma answered the deploy without a Version");
  return JSON.stringify({ app_id: answer.app_id, version: answer.version, state: answer.state, name: answer.name, summary: answer.summary }, null, 2);
}
