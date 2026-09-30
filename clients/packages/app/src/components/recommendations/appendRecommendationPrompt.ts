import type { ChatChannel } from "../../runtime-chat/channel/ChatChannel";

export function appendRecommendationPrompt(
  channel: Pick<ChatChannel, "getSnapshot" | "setDraft">,
  prompt: string
) {
  // Read the live draft so consecutive clicks preserve earlier additions.
  const draft = channel.getSnapshot().draft;
  return channel.setDraft(draft ? `${draft}\n\n${prompt}` : prompt);
}
