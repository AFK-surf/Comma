// The reads of sessions, threads and jobs (src/api/routes/sessions.ts asks them), each with the request's `lang`.
import type { ReadOp } from "./ops.ts";
import { job, jobLog, openJobs } from "./jobs.ts";
import { session, sessionFile, sessions, summary, thread, threads, timeline, widgetState } from "./sessions.ts";

export const sessionOps: Record<string, ReadOp> = {
  /// One session as lists and events have it (views.rs `summary`).
  summary: (s, a) => summary(s, a.key),
  sessions: (s, a) => sessions(s, a.connect ?? null, a.archived, a.lang),
  session: (s, a) => session(s, a.key, a.viewer, a.lang),
  timeline: (s, a) => timeline(s, a.key, a.before, a.limit, a.lang),
  sessionFile: (s, a) => sessionFile(s, a.key, a.name, a.thumb, a.lang),
  widgetState: (s, a) => widgetState(s, a.key, a.path, a.lang),
  threads: (s, a) => threads(s, a.viewer, a.session ?? null, a.lang),
  thread: (s, a) => thread(s, a.viewer, a.id, a.lang),
  openJobs: (s, a) => openJobs(s, a.viewer, a.lang),
  job: (s, a) => job(s, a.id),
  jobLog: (s, a) => jobLog(s, a.id, a.lines),
};
