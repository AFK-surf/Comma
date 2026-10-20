// archive_policy: the agents' way to read and change the archive policy (sessions/archive-policy.ts), as people do on
// the automatic decisions page. A change is kept with the session that made it, shown there, and the done chats are
// checked again under it.
import { currentPolicy, MAX_OPTIONS, savePolicy } from "../sessions/archive-policy.ts";
import type { Hub } from "../sessions/hub.ts";
import { reviewUndecided } from "../sessions/review.ts";
import type { Tool } from "./mcp.ts";

export const ARCHIVE_POLICY = {
  name: "archive_policy",
  description:
    "Read or change this station's archive policy: after an agent ends a turn all_done, a decision model reads the chat and picks one of the policy's options; the chat is recommended for archiving when that option counts as archive. The policy is the words the model is told (how to look at a chat); each option is a situation (name, one-line rubric) counted as archive or not. Without arguments, returns the current policy. Change it when a person says archive recommendations are wrong in a way the policy causes (an option counted the wrong way, a situation missing, a rubric unclear); when the model only picked the wrong option, say so and leave the policy. Give the whole new policy text and/or the whole list of options (keep each existing option's id; new ones may omit it); tell the person in the chat what you changed. People see who changed it, from which chat, and what.",
  inputSchema: {
    "type": "object",
    "properties": {
      "policy": {
        "type": "string",
        "description": "The new policy in words, whole (omit to keep it)."
      },
      "options": {
        "type": "array",
        "description": `The new options, whole and in order (omit to keep them); 2 to ${MAX_OPTIONS}, at least one archive and one not.`,
        "items": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "The option's id as read (lowercase letters, digits, _); omit for a new one." },
            "name": { "type": "string", "description": "A few words, in the language people use." },
            "rubric": { "type": "string", "description": "One line: when a chat is in this situation." },
            "archive": { "type": "boolean", "description": "Whether a chat in this situation is recommended for archiving." }
          },
          "required": ["name", "rubric", "archive"],
          "additionalProperties": false
        }
      }
    },
    "additionalProperties": false
  },
};

export function archiveTools(hub: Hub): Tool[] {
  return [
    {
      ...ARCHIVE_POLICY,
      run: async (key, args) => {
        const now = currentPolicy(hub.store);
        if (args.policy === undefined && args.options === undefined) return JSON.stringify(now, null, 2);
        const next = { policy: args.policy ?? now.policy, options: args.options ?? now.options };
        const changed = savePolicy(hub.store, next, { kind: "agent", session: key });
        if (changed === null) return "Nothing changed: the policy is already so.";
        void reviewUndecided(hub).catch(() => {});
        return `Saved (${changed}). The done chats are checked again under it; this chat is when your turn ends all_done. Tell the person what you changed.`;
      },
    },
  ];
}
