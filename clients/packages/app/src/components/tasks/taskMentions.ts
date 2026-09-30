import { taskMentionPlainText } from "../chat/model/mentionSerialization";

/**
 * The composer text that names these Tasks for the Comma assistant: one
 * `[title](comma:task/<id>)` mention per Task, space-separated, with a trailing
 * space so the reader's own words follow straight on.
 */
export function taskMentionsDraft(
  tasks: readonly { conversationId: string; title: string }[],
  currentDraft = ""
): string {
  if (tasks.length === 0) return currentDraft;
  const separator = currentDraft && !/\s$/u.test(currentDraft) ? " " : "";
  return `${currentDraft}${separator}${tasks.map((task) => taskMentionPlainText(task.title, task.conversationId)).join(" ")} `;
}
