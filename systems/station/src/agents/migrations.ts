// What changed in how agents work, told to sessions that began before it: each turn, the notes newer than the last one
// the session was told come before its messages, once. A change to the instructions (instructions.ts), the tools'
// parameters or rules adds one at the end (the next number, a sentence or two saying what changed; the details are in
// the instructions file the session's workspace has).

/// The notes, oldest first, each with its number (counting up from 1, never reused).
export const NOTES: [number, string][] = [
  [1, "How a turn ends: all_done now needs done (the evidence nothing is left), a turn waiting on a person is need_human (with need), and waiting is only for your own work that brings you back (with for). A message can carry a card (options, or a field to type in)."],
  [2, "In still.fail chats, chat_post automatically attaches local files named by inline Markdown links or images. Invalid local paths and conflicting attachment names are rejected before posting; correct them or write paths as code when they are only examples."],
  [3, "After giving advice, a recommendation or proposed options, ask for the user’s decision and end with need_human, not all_done; include an answer card in still.fail chats. Do not reopen decisions already made or ask again before doing authorized work."],
  [4, "Station instructions and built-in skill wording are shorter; the same routing, decision, completion and safety rules still apply. Use the current instructions file and skill files when you need details."],
  [5, "Options may specify action=close to end need_human without a reply or waking you; default is reply. Offer this only when that choice needs no further work; there is no fixed close button."],
  [6, "Set card.assignee to the decision maker’s email. Only that person sees the card in 奏; anyone may still answer in the chat. Legacy unassigned cards remain in the chat, labelled unassigned."],
  [7, "chat_post now accepts only to + withdraw (your question’s message ts) to remove your own resolved or obsolete answer card. It preserves the post and does not mark work complete; continue and record the appropriate ending state."],
  [8, "Users always have a chat input box; answer cards are optional shortcuts for useful concrete choices, not required for every question. Do not add filler options or invent a follow-up decision after an answer or advice; use need_human only for a real outstanding need."],
  [9, "need_human must refer to a visible outstanding question: chat_state requires about or a pending card; alternatively ask with chat_post kind=need_human. After answering a clarification, explicitly say if an earlier decision is still needed; do not invent new questions, and cards remain optional."],
  [10, "Each answer option must be complete on its own; anything the user would word themselves (what to change, a name, a value, a different approach) is never an option, they type it. A card may have a single option, e.g. 合并 when asking to merge shown work."],
  [11, "New runtime processes expose MCP tools under stillfail (mcp__stillfail__…). A handed-over process may still expose ember: use its available tools until that process restarts. Historical transcripts and old tools remain readable."],
  [12, "New tool adb_devices: Android phones people shared with this station from the still.fail app, each reachable with `adb -s 127.0.0.1:<port>`; it also gives the link that opens this station's 共享调试 in a person's app, to ask for one."],
  [13, "Job tool instructions now use `stillfail-job notify`. The old `ember-job` command remains an alias for jobs and transcripts created before the rename."],
  [14, "A card without card.assignee now goes to the chat starter’s 奏 list, and need_human without a card goes there too, with its about message as the question: keep that message self-contained."],
  [15, "station_task: all tasks of a session now share one directory on the target station, removed when the chat is archived or deleted (or after 14 days unused). Keep checkouts and build output there instead of opening directories elsewhere on that machine."],
  [16, "When configured, station reviews all_done (including legacy final) before posting or recording it. A rejected completion returns evidence to reconcile; continue authorized work or ask only a real outstanding question. Review uncertainty is not a request for invented approval."],
  [17, "When an existing profile has a verified decision model, station automatically reviews all_done (including legacy final) before posting or recording it. A rejected completion returns evidence to reconcile; continue authorized work or ask only a real outstanding question. Review uncertainty is not a request for invented approval."],
  [18, "When completion checking is enabled in Automatic Decisions, station reviews all_done with the configured model (including legacy final) before posting or recording it. A rejected completion returns evidence to reconcile; continue authorized work or ask only a real outstanding question. Review uncertainty is not a request for invented approval."],
  [19, "New tool session_send: write to another session's agent (its chat link or session key), on this station or another of the workspace; it shows in that chat. A message headed 来自/From <a chat's link> is from one: answer with session_send to that link."],
  [20, "In still.fail chats, write lists in Markdown (- or 1., an item per line): • is Slack's, and there it runs into one paragraph."],
  [21, "all_done is no longer reviewed before it is posted or recorded (the earlier notes about a review that could reject it are void): a chat marked all done may be assessed afterwards, in the background, and recommended for the archive when nothing is left in it. It never holds an agent back."],
  [22, "A skill may now be shared between the workspace's stations: one from another station shows in skills/ like the others, and what you write to it reaches that station (an edit made on an older copy is kept beside it as SKILL.conflict-<station>.md: merge it into SKILL.md when you see one)."],
  [23, "Archive recommendations now follow an editable archive policy (words plus options, each counted as archive or not); new tool archive_policy reads and changes it. When someone says a recommendation is wrong, fix the policy if it causes it."],
  [24, "Before ending a turn waiting, make sure something watches the work and brings you back when it ends or fails (background command or agent, job, a loop polling CI that exits on the first failure); never wait on a guessed duration alone. Only when the work truly cannot be watched, give seconds as the shortest it could take. While it runs, do whatever does not depend on it; wait only when nothing else is left."],
  [25, "station_task is now station_job (same actions and arguments): shell commands on another station are remote jobs. Jobs started with station_task are followed as before."],
  [26, "A Task kept on another station can bring you in: its messages come with via=\"task\" and thread=\"TASK/…\"; answer them with chat_post there, in Markdown (no files or cards yet)."],
  [27, "Coding session Git instructions are defaults that explicit user instructions override, including leaving changes uncommitted, using another branch, or force-pushing. Prefer --force-with-lease for requested force pushes. Report push failures and any uncommitted or unpushed work that may be lost when the sandbox stops."],
  [28, "Salix Tasks, including Coding tasks, accept chat_post files and automatically attach local files referenced by Markdown links or images. Correct missing paths or duplicate file names before posting. Other station hosts still reject files, and Task posts do not accept cards."],
];

/// The latest note's number: what a session that knows everything has been told.
export const latest = () => NOTES.at(-1)?.[0] ?? 0;

/// The notes a session told up to `told` has yet to hear, as one block before its messages, and where today's whole
/// instructions are (`full`); empty when there are none.
export function untold(told: number, full: string): string {
  const notes = NOTES.filter(([n]) => n > told).map(([, note]) => `- ${note}`);
  if (notes.length === 0) return "";
  return `[still.fail changed how you work since this session began]\n${notes.join("\n")}\nToday's whole instructions, tool parameters included, are in ${full}: read them when you need the details (your tool list may not show the new parameters; pass them anyway).`;
}
