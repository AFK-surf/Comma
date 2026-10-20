// The agents' tools for background jobs (the Rust station's jobs.rs `Jobs::tools`): job_start, job_list, job_log, job_stop,
// run as the session whose token the MCP request carries. Names, descriptions and input schemas as the Rust's, word for
// word (test/jobs-tools.test.ts reads them from it).
import { type Jobs, LOG_LINES, named, tail } from "../jobs/jobs.ts";
import { joinPath } from "../ops/paths.ts";
import type { JobRow } from "../store/store.ts";
import type { Tool } from "./mcp.ts";

export const JOB_START_DESCRIPTION =
  "Start a background job: a shell command the station runs apart from your turns, with its output kept in a log. You are told when it ends, and whatever it says on the way: inside the job, `stillfail-job notify <words>` sends you a message (use it for milestones or problems in a long run). Give a port for a web service: it is kept up (started again if it ends), gets PORT in its environment, and the workspace's members can open it through the returned link (post the link where people should see it). Jobs keep running across your turns and across restarts of the station (one that did not survive, say the machine restarted, is started again). For keeping watch over something for a long while (a CI run, a deploy, a metric, a review queue), set watch: while the watch runs, its chat is a watching chat, found under the chat list's 监控中 filter and never archived for being idle; when you then end your turn waiting, you are not asked again when the wait is over, only when the watch says something (`stillfail-job notify`), ends, or someone writes. Watch with a loop that checks and notifies on changes. Name the chat for it: give your next chat_post in a still.fail chat a title that says what it watches (e.g. 「监控 · PR #482 的 CI」); a chat with a watch running may be renamed so at once.";

const text = (args: Record<string, unknown>, key: string): string => (typeof args[key] === "string" ? (args[key] as string) : "");
const pretty = (v: unknown) => JSON.stringify(v, null, 2);

/// A JSON number serde reads as a u64: a whole number, not negative.
const asU64 = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);

/// The job a tool names (`id`), when it is this session's.
function owned(jobs: Jobs, key: string, args: Record<string, unknown>): JobRow {
  const id = text(args, "id").trim();
  const job = jobs.store.getJob(id);
  if (!job) throw new Error(`no job ${id}: job_list names this session's`);
  if (job.sessionKey !== key) throw new Error(`job ${id} is another session's`);
  return job;
}


/// `workspace`: a session's workspace directory (its record's), null for a session there is not.
export function jobTools(jobs: Jobs, workspace: (session: string) => string | null): Tool[] {
  return [
    {
      name: "job_start",
      description: JOB_START_DESCRIPTION,
      inputSchema: {
        type: "object",
        properties: {
          command: { type: "string", description: "The shell command (run by sh -c)." },
          name: { type: "string", description: "A short name for it." },
          cwd: { type: "string", description: "Where it runs; default this session's workspace." },
          port: { type: "integer", minimum: 1024, maximum: 65535, description: "For a web service: the port it listens on (127.0.0.1 is enough)." },
          watch: { type: "boolean", description: "It keeps watch for a long while (see above). Not with a port." },
        },
        required: ["command"],
        additionalProperties: false,
      },
      run: async (key, args) => {
        const home = workspace(key);
        if (home === null) throw new Error("unknown session");
        const given = text(args, "cwd").trim();
        const cwd = given === "" ? home : joinPath(home, given);
        let port: number | null = null;
        if (args.port !== undefined && args.port !== null) {
          const p = asU64(args.port);
          if (p === null || p > 65535) throw new Error("port must be a number from 1024 to 65535");
          port = p;
        }
        const watch = args.watch === true;
        const job = jobs.start(key, text(args, "name"), text(args, "command"), cwd, port, watch);
        return pretty(jobs.view(job));
      },
    },
    {
      name: "job_list",
      description: "This session's background jobs, newest first: their state (running, exited, stopped, failed), exit code, port and link.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
      run: async (key) => {
        const list = jobs.store.listJobs(key).map((j) => jobs.view(j));
        return list.length === 0 ? "No jobs." : pretty(list);
      },
    },
    {
      name: "job_log",
      description: "The last lines of a background job's output.",
      inputSchema: {
        type: "object",
        properties: { id: { type: "string" }, lines: { type: "integer", minimum: 1, maximum: 1000, description: "Default 50." } },
        required: ["id"],
        additionalProperties: false,
      },
      run: async (key, args) => {
        const job = owned(jobs, key, args);
        const n = asU64(args.lines);
        const lines = n === null ? LOG_LINES : Math.min(Math.max(n, 1), 1000);
        const log = tail(job.log, lines);
        return log === "" ? `${named(job)} has written nothing yet.` : log;
      },
    },
    {
      name: "job_stop",
      description: "Stop a background job (a service is then not started again).",
      inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"], additionalProperties: false },
      run: async (key, args) => {
        const job = await jobs.stop(owned(jobs, key, args).id);
        return `${named(job)} is ${job.state}.`;
      },
    },
  ];
}
