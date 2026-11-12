// The Salix tools of a Session whose Task Salix keeps (tasks/tasks.ts): salix_tools lists the Salix registry tools the
// Session's agent may call as the Task's Worker, salix_call calls one. Offered only to such a Session (listed and run);
// others neither see nor run them. Salix authorizes the call (SalixWeb.StationTasks.tool_call/2): the Task's own sandbox
// on its current generation, a tool that the Worker may call. The `comma` command line (connector/
// comma-client-cli.ts, its Salix backend) calls these two tools, so scripts reach Salix the same way.
import type { Tasks } from "../tasks/tasks.ts";
import type { Tool } from "./mcp.ts";

type Json = any;

export const SALIX_TOOLS_DESCRIPTION =
  "List the Comma (Salix) tools you can call from this sandbox with salix_call, as this Task's Worker: each with its name, what it does and its input schema. They are what the Worker can call in Comma: its files (fs.*: its own files in Comma; /drive/... is the Workspace's shared Drive), skills (/.runtime/skills), the web, env.exec with credential_env for the Group's OAuth credentials, preview.publish_html for websites, and more. Call this once, then call tools by name.";
export const SALIX_CALL_DESCRIPTION =
  "Call one Comma (Salix) tool from this sandbox, as this Task's Worker: `tool` is a name salix_tools listed, `args` its input. The tool's result comes back as text (cut at 1 MiB, then `truncated`); a tool error comes back as a tool error. Writes to fs.* paths land in the Worker's own files in Comma; writes under /drive/ land in the Workspace's shared Drive, which its members see. Arguments are at most 1 MiB: give a larger file with chat_post files instead.";

/// The tools, run through `tasks` as the session the MCP request names.
export function salixTools(tasks: Tasks): Tool[] {
  const offered = (session: string) => tasks.salixHost(session) !== null;
  return [
    {
      name: "salix_tools",
      description: SALIX_TOOLS_DESCRIPTION,
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
      offered,
      run: async (session) => JSON.stringify(await tasks.salixTools(session), null, 2),
    },
    {
      name: "salix_call",
      description: SALIX_CALL_DESCRIPTION,
      inputSchema: {
        type: "object",
        properties: {
          tool: { type: "string", description: "The tool's name, as salix_tools lists it (fs.write_file, web.search, ...)." },
          args: { type: "object", description: "The tool's input, as its input schema says.", additionalProperties: true },
        },
        required: ["tool"],
        additionalProperties: false,
      },
      offered,
      run: async (session, args) => {
        const tool = typeof args.tool === "string" ? args.tool.trim() : "";
        if (tool === "") throw new Error("tool is the name of a Salix tool; salix_tools lists them");
        const input = args.args === undefined || args.args === null ? {} : args.args;
        if (typeof input !== "object" || Array.isArray(input)) throw new Error("args is an object: the tool's input");
        return called(await tasks.salixToolCall(session, tool, input as Record<string, unknown>));
      },
    },
  ];
}

/// What the agent is told of Salix's answer: the tool's content, or (as a tool error) why there is none.
export function called(answer: Json): string {
  if (typeof answer?.error === "string") throw new Error(`The call was refused (${answer.error})${typeof answer.message === "string" ? `: ${answer.message}` : ""}`);
  const content = typeof answer?.content === "string" ? answer.content : "";
  if (answer?.error === true) throw new Error(content !== "" ? content : "The tool failed");
  return answer?.truncated === true ? `${content}\n\n[truncated: the result was longer than 1 MiB]` : content;
}
